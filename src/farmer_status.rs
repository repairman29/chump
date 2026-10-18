//! RESILIENT-069: `chump farmer status` — the readiness gate, "lights-on
//! check" for `scripts/coord/farmer.sh` (RESILIENT-068).
//!
//! One command, exit 0/1:
//!   GREEN (exit 0) = sentinel absent + zero exit-78 supervisors +
//!                     oauth fresh + farmer heartbeat <120s
//!   RED   (exit 1) = at least one of the above is concretely unhealthy
//!
//! Reads ONLY local state (files + `launchctl list`) — no network, no
//! `gh`, no sqlite writes. Target <100ms so it's cheap enough to call from
//! every work entry-point (session-start, `chump claim`, the gap-reserve
//! admission guard, `worker.sh` tick) without adding perceptible latency.
//!
//! Fail-open by design for checks whose signal is simply ABSENT (farmer
//! never installed on this host, `launchctl` unavailable on Linux, no
//! oauth/api-key signal at all) — RED only fires on POSITIVE evidence of
//! trouble (a sentinel file present, a daemon that actually exited 78, a
//! heartbeat file that exists but has gone stale, an auth cache that
//! actually recorded BROKEN). This mirrors the vacuous-until-real-state
//! pattern used by the MISSION-045 outcome gate — a gate that blocks work
//! on hosts where the thing it's checking was never wired up would be
//! worse than no gate at all.

use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Control-plane launchd labels the farmer monitors (mirrors
/// `CONTROL_PLANE_LABELS` in scripts/coord/farmer.sh).
const CONTROL_PLANE_LABELS: &[&str] = &[
    "com.chump.bot-merge-watchdog",
    "com.chump.main-health-watchdog",
    "com.chump.reap-stale-leases",
    "com.chump.stale-process-watchdog",
    "com.chump.heartbeat-watcher",
    "com.chump.ci-health-gate",
    "com.chump.queue-health-monitor",
    "dev.chump.premature-closure-watch",
    "dev.chump.system-invariants-monitor",
];

const HEARTBEAT_MAX_AGE_S: u64 = 120;
const OAUTH_CACHE_TTL_S: u64 = 600;

#[derive(Debug, Clone, Serialize)]
pub struct FarmerStatus {
    pub green: bool,
    pub sentinel_absent: bool,
    pub exit78_free: bool,
    pub oauth_fresh: bool,
    pub heartbeat_fresh: bool,
    pub heartbeat_age_s: Option<u64>,
    /// RESILIENT-1636: the node was deliberately paused (`chump node pause` /
    /// `CHUMP_NODE_MODE=paused`). A paused farmer is NOT lights-on (`green`
    /// stays false, so NEW claims are still refused), but its stale heartbeat
    /// is EXPECTED, not a malfunction — so it is reported as PAUSED, not stale.
    pub paused: bool,
    pub reasons: Vec<String>,
}

fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn mtime_age_s(path: &Path) -> Option<u64> {
    let meta = std::fs::metadata(path).ok()?;
    let mtime = meta.modified().ok()?;
    let age = SystemTime::now().duration_since(mtime).ok()?;
    Some(age.as_secs())
}

/// Sentinel check: `.chump/fleet-paused` present means the fleet is
/// deliberately paused — not lights-on.
fn check_sentinel(chump_dir: &Path, reasons: &mut Vec<String>) -> bool {
    let sentinel = chump_dir.join("fleet-paused");
    if sentinel.exists() {
        reasons.push("sentinel present: .chump/fleet-paused".to_string());
        false
    } else {
        true
    }
}

/// exit-78 supervisor check: none of the control-plane launchd labels may
/// have last-exited with EX_CONFIG (78). Fail-open if `launchctl` is
/// unavailable (Linux dev/CI hosts) — absence of the tool is not evidence
/// of a crashed supervisor.
fn check_exit78_free(reasons: &mut Vec<String>) -> bool {
    let output = match std::process::Command::new("launchctl").arg("list").output() {
        Ok(o) if o.status.success() => o,
        _ => return true, // launchctl absent/failed — vacuous pass (fail-open)
    };
    let text = String::from_utf8_lossy(&output.stdout);
    let mut ok = true;
    for line in text.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        // launchctl list columns: PID  LastExitStatus  Label
        if cols.len() < 3 {
            continue;
        }
        let label = cols[2];
        if !CONTROL_PLANE_LABELS.contains(&label) {
            continue;
        }
        if cols[1] == "78" {
            reasons.push(format!("supervisor exit-78: {label}"));
            ok = false;
        }
    }
    ok
}

/// oauth-fresh check. RESILIENT-1636: this gate must validate the credential
/// path `claude -p` ACTUALLY uses on the host, NOT the macOS-only
/// `~/.chump/oauth-token.json` Keychain mirror's mtime. On a Linux node the
/// mirror refresher never runs (`oauth-token-refresh.sh` is macOS-Keychain
/// only → `kind=oauth_refresh_unsupported_platform`), so a stale mirror is a
/// FALSE death signal while `claude -p` authenticates fine from its own
/// credentials all day. Presence/mtime is not validity (RESILIENT-086); the
/// authority for a BROKEN verdict is `auth-status.sh`'s probed cache
/// (CREDIBLE-147, the six-day June outage).
///
/// Priority:
///   1. ANTHROPIC_API_KEY present (env or .env) -> fresh, no oauth needed.
///   2. auth-status.sh VALIDITY cache (`~/.chump/auth-status-cache`) says rc=0
///      within TTL -> fresh; rc!=0 within TTL -> RED (probed BROKEN).
///   3. free-tier cascade active (RESILIENT-409) -> Anthropic oauth unused -> fresh.
///   4. the credential path `claude -p` uses is present AND valid:
///      `CLAUDE_CODE_OAUTH_TOKEN` env, or `$HOME/.claude/.credentials.json` with
///      a non-expired (or refreshable) oauth token -> fresh. The
///      `~/.chump/oauth-token.json` mirror MTIME is never consulted.
///   5. No positive signal of trouble -> fresh (fail-open).
fn check_oauth_fresh(repo_root: &Path, reasons: &mut Vec<String>) -> bool {
    let api_key = std::env::var("ANTHROPIC_API_KEY")
        .ok()
        .filter(|s| !s.is_empty());
    if api_key.is_some() {
        return true;
    }
    if let Ok(env_text) = std::fs::read_to_string(repo_root.join(".env")) {
        for line in env_text.lines() {
            if let Some(v) = line.strip_prefix("ANTHROPIC_API_KEY=") {
                if !v.trim().trim_matches('"').trim_matches('\'').is_empty() {
                    return true;
                }
            }
        }
    }

    let home = chump_state_home().unwrap_or_default();
    let cache_path = PathBuf::from(&home).join(".chump/auth-status-cache");
    if let Ok(text) = std::fs::read_to_string(&cache_path) {
        let mut lines = text.lines();
        let ts: Option<u64> = lines.next().and_then(|s| s.trim().parse().ok());
        let rc: Option<i32> = lines.next().and_then(|s| s.trim().parse().ok());
        if let (Some(ts), Some(rc)) = (ts, rc) {
            let age = now_s().saturating_sub(ts);
            if age < OAUTH_CACHE_TTL_S {
                if rc == 0 {
                    return true;
                }
                reasons.push(format!(
                    "auth-status cache reports BROKEN (rc={rc}, age={age}s)"
                ));
                return false;
            }
        }
    }

    // RESILIENT-409: DeepSeek floor never touches the Anthropic oauth token.
    if free_tier_cascade_active() {
        return true;
    }

    // RESILIENT-1636: validate the credential path `claude -p` actually uses.
    if std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .is_some()
    {
        return true;
    }
    let creds_path = PathBuf::from(&home).join(".claude/.credentials.json");
    if let Ok(body) = std::fs::read_to_string(&creds_path) {
        if matches!(claude_creds_verdict(&body, now_ms()), Some(true)) {
            return true;
        }
    }

    // No positive signal of trouble — fail-open (RED only on probed BROKEN above).
    true
}

/// RESILIENT-1636: pure validity verdict for Claude Code's credential store
/// (`~/.claude/.credentials.json`), the path `claude -p` actually reads. This
/// is a VALIDITY check (token present + expiry in the future, or expired but
/// refreshable), NOT a presence/mtime check (RESILIENT-086). Pure (no fs/env)
/// so it is deterministically unit-testable.
///
/// Returns `Some(true)` when a usable token is present and not-expired (or
/// expired-but-refreshable); `Some(false)` when the access token is expired
/// with no refresh token; `None` when there is no token at all / unparseable
/// (caller falls through to the fail-open branch).
fn claude_creds_verdict(content: &str, now_ms: i64) -> Option<bool> {
    let v: serde_json::Value = serde_json::from_str(content).ok()?;
    // Claude Code nests under `claudeAiOauth`; tolerate a flat shape too.
    let oauth = v.get("claudeAiOauth").unwrap_or(&v);
    // A usable access token must be present under one of the known key names.
    let _token = ["accessToken", "access_token", "token"]
        .iter()
        .find_map(|k| {
            oauth
                .get(*k)
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
        })?;
    // expiresAt is epoch millis (a JSON number or a numeric string).
    let expires = oauth.get("expiresAt").and_then(|x| {
        x.as_i64()
            .or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))
    });
    match expires {
        Some(exp) if exp > now_ms => Some(true), // valid, not yet expired
        Some(_) => {
            // Access token expired — usable iff a refresh token exists, which
            // Claude Code uses to mint a fresh token on the next call.
            let refreshable = oauth
                .get("refreshToken")
                .and_then(|x| x.as_str())
                .map(|s| !s.is_empty())
                .unwrap_or(false);
            Some(refreshable)
        }
        None => Some(true), // token present, no expiry field — treat as usable
    }
}

/// RESILIENT-1636: milliseconds since the Unix epoch (for the ms-precision
/// `expiresAt` in `~/.claude/.credentials.json`).
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// CREDIBLE-1519: resolve the chump state home directory the oauth-freshness
/// check reads (`<home>/.chump/{auth-status-cache,oauth-token.json}`). Honors
/// `CHUMP_HOME` before falling back to `HOME`, mirroring
/// `auth::chump_config_path`. Without this, a caller that redirected all other
/// state via a temp `CHUMP_HOME` (hermetic `scripts/ci/test-*.sh` seeds, a
/// `CHUMP_HOME`-scoped invocation) still had this gate read the host's real
/// `~/.chump/oauth-token.json` — a 69-day-stale host token then RED-blocked
/// `chump gap reserve` inside the temp home, failing preflight on every
/// Rust-touching push from a paused/observer host.
fn chump_state_home() -> Option<String> {
    resolve_state_home(std::env::var("CHUMP_HOME").ok(), std::env::var("HOME").ok())
}

/// Pure precedence rule for [`chump_state_home`]: a non-empty `CHUMP_HOME`
/// wins, else `HOME`. Split out so the precedence is unit-testable without
/// mutating process-global env (which would race the auth.rs env tests in the
/// same test binary).
fn resolve_state_home(chump_home: Option<String>, home: Option<String>) -> Option<String> {
    chump_home.filter(|s| !s.is_empty()).or(home)
}

/// RESILIENT-409: true when a free-tier / execute-gap provider cascade (the
/// DeepSeek floor) is configured. In this mode the Anthropic oauth token is
/// never used, so its staleness must not gate claims. Reads one env var only
/// -- no network, keeps `farmer status` local-only and <100ms.
fn free_tier_cascade_active() -> bool {
    std::env::var("CHUMP_FREE_TIER_PROVIDERS")
        .ok()
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
}

/// heartbeat-fresh check: `.chump/farmer-heartbeat` — vacuous pass if the
/// farmer has never run on this host (file absent). RED only when the
/// file exists but is stale, i.e. the farmer was alive and stopped
/// ticking.
///
/// RESILIENT-1636: the reason text is pushed by [`compute`] (not here), so a
/// node paused by owner decision reports the staleness as PAUSED rather than
/// as a malfunction. This helper returns the pure (fresh, age) verdict.
fn heartbeat_verdict(chump_dir: &Path) -> (bool, Option<u64>) {
    let path = chump_dir.join("farmer-heartbeat");
    match mtime_age_s(&path) {
        None => (true, None), // never installed on this host — vacuous pass
        Some(age) => (age <= HEARTBEAT_MAX_AGE_S, Some(age)),
    }
}

/// Node-mode pause detection (RESILIENT-1636 / RESILIENT-1614). A node paused
/// via `chump node pause` writes `CHUMP_NODE_MODE=paused` to `node.env`; the
/// env var may also be exported directly. A paused node's stale heartbeat is
/// EXPECTED (the farmer is deliberately idle), so it is reported as PAUSED.
fn node_is_paused() -> bool {
    if let Ok(m) = std::env::var("CHUMP_NODE_MODE") {
        let m = m.trim();
        if m == "paused" {
            return true;
        }
        if !m.is_empty() {
            return false; // explicit non-paused mode wins over the file
        }
    }
    // node.env lives at CHUMP_STATE_DIR (if set) else <state-home>/.chump, the
    // same resolution `chump node pause` uses in node_mode.rs.
    let state_dir = std::env::var("CHUMP_STATE_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| chump_state_home().map(|h| PathBuf::from(h).join(".chump")));
    if let Some(dir) = state_dir {
        if let Ok(body) = std::fs::read_to_string(dir.join("node.env")) {
            return node_env_is_paused(&body);
        }
    }
    false
}

/// Pure parse of a `node.env` body for `CHUMP_NODE_MODE=paused` (with or
/// without the `export ` prefix node_mode.rs writes). Split out for unit tests.
fn node_env_is_paused(content: &str) -> bool {
    content.lines().any(|l| {
        let t = l.trim().trim_start_matches("export ").trim();
        t == "CHUMP_NODE_MODE=paused"
    })
}

pub fn compute(repo_root: &Path) -> FarmerStatus {
    let chump_dir = repo_root.join(".chump");
    let mut reasons = Vec::new();

    let sentinel_absent = check_sentinel(&chump_dir, &mut reasons);
    let exit78_free = check_exit78_free(&mut reasons);
    let oauth_fresh = check_oauth_fresh(repo_root, &mut reasons);
    let (heartbeat_fresh, heartbeat_age_s) = heartbeat_verdict(&chump_dir);
    let paused = node_is_paused();

    // RESILIENT-1636: a paused node's stale heartbeat is expected — report it
    // as PAUSED, not as a stale-farmer malfunction. A truly-stale heartbeat on
    // an UN-paused node keeps the original RED reason.
    if paused {
        let agenote = heartbeat_age_s
            .map(|a| format!(" (heartbeat age={a}s, staleness expected while paused)"))
            .unwrap_or_default();
        reasons.push(format!(
            "farmer paused by node mode (CHUMP_NODE_MODE=paused){agenote}"
        ));
    } else if !heartbeat_fresh {
        reasons.push(format!(
            "farmer heartbeat stale: age={}s > {HEARTBEAT_MAX_AGE_S}s",
            heartbeat_age_s.unwrap_or(0)
        ));
    }

    // A paused node is NOT lights-on: green stays false so NEW claims are still
    // refused (the gate must not be weakened). The re-entry admission for
    // already-claimed work lives in `claim_admission`, not here.
    let green = sentinel_absent && exit78_free && oauth_fresh && heartbeat_fresh && !paused;

    FarmerStatus {
        green,
        sentinel_absent,
        exit78_free,
        oauth_fresh,
        heartbeat_fresh,
        heartbeat_age_s,
        paused,
        reasons,
    }
}

/// RESILIENT-1636: the farmer gate's admission verdict for `chump claim`.
///
/// The gate must refuse NEW worker claims when the farmer is not lights-on,
/// but must NOT refuse the ship step of work a dispatch/chain lane ALREADY
/// claimed (bot-merge re-invokes `chump claim` to re-enter the worktree whose
/// lease the dispatch already holds — on a paused node that re-claim was dying
/// at the gate, so every dispatch shipped only through salvage).
#[derive(Debug)]
pub enum ClaimAdmission {
    /// Farmer lights-on — admit normally.
    Green,
    /// Farmer not lights-on, but the current session already holds a live lease
    /// for this gap: re-entry of already-admitted work. Carries a note printed
    /// to stdout so bot-merge / `chump dispatch` can surface the reason.
    ReentryAdmit { note: String },
    /// Farmer not lights-on and this is a NEW claim (no live lease held by the
    /// current session for this gap) — refused. Carries the status for reasons.
    Refuse { status: FarmerStatus },
}

/// Decide whether `chump claim <gap>` may proceed under the current farmer
/// state. `session_id` is the dispatch/worker session (from `CHUMP_SESSION_ID`);
/// when it already holds a live lease for `gap_id` the claim is a re-entry and
/// is admitted even on a RED/paused farmer. A new claim (no such lease) is
/// still refused — the gate is not weakened.
pub fn claim_admission(repo_root: &Path, gap_id: &str, session_id: Option<&str>) -> ClaimAdmission {
    let status = compute(repo_root);
    let reentry_session = session_id.map(str::trim).filter(|s| !s.is_empty());
    let has_reentry_lease = reentry_session
        .map(|sess| session_holds_live_lease_for_gap(&repo_root.join(".chump-locks"), gap_id, sess))
        .unwrap_or(false);
    build_admission(status, gap_id, reentry_session, has_reentry_lease)
}

/// Pure admission decision (no fs/env), split out so the invariant is
/// deterministically unit-testable: GREEN → admit; not-green + a live re-entry
/// lease → admit (ship step of already-claimed work); otherwise → refuse.
fn build_admission(
    status: FarmerStatus,
    gap_id: &str,
    session_id: Option<&str>,
    has_reentry_lease: bool,
) -> ClaimAdmission {
    if status.green {
        return ClaimAdmission::Green;
    }
    if has_reentry_lease {
        if let Some(sess) = session_id {
            let state = if status.paused { "paused" } else { "RED" };
            return ClaimAdmission::ReentryAdmit {
                note: format!(
                    "farmer {state} but session {sess} already holds a live lease for {gap_id} \
                     — admitting re-entry (ship step of already-claimed work; RESILIENT-1636). \
                     NEW claims remain refused."
                ),
            };
        }
    }
    ClaimAdmission::Refuse { status }
}

/// RESILIENT-1636: does `session_id` hold a LIVE (non-expired) lease for
/// `gap_id` in `lock_dir`? The dispatch lane's lease-only claim writes
/// `<lock_dir>/<session>.json` with `{gap_id, session_id, expires_at}` (RFC3339);
/// scan every lease file so filename sanitisation can't cause a miss.
fn session_holds_live_lease_for_gap(lock_dir: &Path, gap_id: &str, session_id: &str) -> bool {
    let now = now_s();
    let Ok(entries) = std::fs::read_dir(lock_dir) else {
        return false;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };
        if val.get("gap_id").and_then(|v| v.as_str()) != Some(gap_id) {
            continue;
        }
        if val.get("session_id").and_then(|v| v.as_str()) != Some(session_id) {
            continue;
        }
        // Liveness: an expired lease is not a re-entry anchor.
        if let Some(exp) = val.get("expires_at").and_then(|v| v.as_str()) {
            if let Some(exp_secs) = parse_rfc3339_secs(exp) {
                if exp_secs <= now {
                    continue;
                }
            }
        }
        return true;
    }
    false
}

/// RFC3339 (`2026-04-17T02:27:48Z`) → Unix seconds, for lease-expiry liveness.
fn parse_rfc3339_secs(s: &str) -> Option<u64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.timestamp().max(0) as u64)
}

/// Returns `true` when lights-on (GREEN). Cheap enough to call inline from
/// any gate without a subprocess spawn.
pub fn is_green(repo_root: &Path) -> bool {
    compute(repo_root).green
}

/// CLI handler for `chump farmer status [--json] [--quiet]`.
pub fn run_cli(args: &[String]) -> i32 {
    let want_json = args.iter().any(|a| a == "--json");
    let quiet = args.iter().any(|a| a == "--quiet");
    let repo_root = crate::repo_path::repo_root();
    let status = compute(&repo_root);

    if want_json {
        match serde_json::to_string_pretty(&status) {
            Ok(s) => println!("{s}"),
            Err(e) => eprintln!("error serializing farmer status to JSON: {e}"),
        }
    } else if !quiet {
        let verdict = if status.green {
            "GREEN"
        } else if status.paused {
            "PAUSED"
        } else {
            "RED"
        };
        println!("chump farmer status: {verdict}");
        println!(
            "  sentinel_absent:  {}",
            if status.sentinel_absent { "ok" } else { "FAIL" }
        );
        println!(
            "  exit78_free:      {}",
            if status.exit78_free { "ok" } else { "FAIL" }
        );
        println!(
            "  oauth_fresh:      {}",
            if status.oauth_fresh { "ok" } else { "FAIL" }
        );
        println!(
            "  heartbeat_fresh:  {}{}",
            if status.heartbeat_fresh { "ok" } else { "FAIL" },
            status
                .heartbeat_age_s
                .map(|a| format!(" (age={a}s)"))
                .unwrap_or_default()
        );
        for r in &status.reasons {
            println!("  - {r}");
        }
    }

    if status.green {
        0
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentinel_absent_by_default() {
        let dir = tempfile::tempdir().unwrap();
        let mut reasons = Vec::new();
        assert!(check_sentinel(dir.path(), &mut reasons));
        assert!(reasons.is_empty());
    }

    #[test]
    fn sentinel_present_fails_the_check() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("fleet-paused"), "waste spike").unwrap();
        let mut reasons = Vec::new();
        assert!(!check_sentinel(dir.path(), &mut reasons));
        assert_eq!(reasons.len(), 1);
    }

    #[test]
    fn heartbeat_absent_is_vacuous_pass() {
        // A host where the farmer daemon was never installed must not be
        // treated as RED — only a stale (once-present) heartbeat is signal.
        let dir = tempfile::tempdir().unwrap();
        let (fresh, age) = heartbeat_verdict(dir.path());
        assert!(fresh);
        assert!(age.is_none());
    }

    #[test]
    fn heartbeat_fresh_within_window() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("farmer-heartbeat"), "2026-08-13T00:00:00Z").unwrap();
        let (fresh, age) = heartbeat_verdict(dir.path());
        assert!(fresh);
        assert!(age.unwrap() < HEARTBEAT_MAX_AGE_S);
    }

    #[test]
    fn heartbeat_stale_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("farmer-heartbeat");
        let file = std::fs::File::create(&path).unwrap();
        // Back-date the mtime past the freshness window.
        let old = SystemTime::now() - std::time::Duration::from_secs(HEARTBEAT_MAX_AGE_S + 1);
        file.set_modified(old).unwrap();
        let (fresh, age) = heartbeat_verdict(dir.path());
        assert!(!fresh);
        assert!(age.unwrap() > HEARTBEAT_MAX_AGE_S);
    }

    #[test]
    fn green_requires_all_checks_and_not_paused() {
        let base = FarmerStatus {
            green: true,
            sentinel_absent: true,
            exit78_free: true,
            oauth_fresh: true,
            heartbeat_fresh: true,
            heartbeat_age_s: None,
            paused: false,
            reasons: vec![],
        };
        let is_green = |s: &FarmerStatus| {
            s.sentinel_absent && s.exit78_free && s.oauth_fresh && s.heartbeat_fresh && !s.paused
        };
        assert!(is_green(&base));

        let mut red = base.clone();
        red.oauth_fresh = false;
        assert!(!is_green(&red));

        // RESILIENT-1636: a paused node is not lights-on even with every other
        // check green — so NEW claims are still refused.
        let mut paused = base.clone();
        paused.paused = true;
        assert!(!is_green(&paused));
    }

    #[test]
    fn resolve_state_home_prefers_chump_home() {
        // CREDIBLE-1519 AC2: the oauth-freshness check must resolve its state
        // dir from CHUMP_HOME before HOME, so a hermetic temp CHUMP_HOME
        // redirects the token path and the host's stale ~/.chump token can't
        // RED-block a scoped `chump gap reserve`. Pure test — no env mutation.
        assert_eq!(
            resolve_state_home(Some("/tmp/chome".into()), Some("/home/host".into())),
            Some("/tmp/chome".into())
        );
        // Empty CHUMP_HOME is treated as unset -> fall back to HOME.
        assert_eq!(
            resolve_state_home(Some(String::new()), Some("/home/host".into())),
            Some("/home/host".into())
        );
        // No CHUMP_HOME -> HOME.
        assert_eq!(
            resolve_state_home(None, Some("/home/host".into())),
            Some("/home/host".into())
        );
        // Neither set -> None (callers default to empty, hitting the fail-open
        // "no signal" branch rather than reading an attacker-controlled root).
        assert_eq!(resolve_state_home(None, None), None);
    }

    // ── RESILIENT-1636: credential-path validity (not the mirror mtime) ──────

    #[test]
    fn creds_future_expiry_is_valid() {
        // AC3: valid ~/.claude credentials read as fresh. expiresAt in the
        // future (epoch MILLIS) → usable.
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":9999999999999}}"#;
        assert_eq!(claude_creds_verdict(body, 1_000), Some(true));
    }

    #[test]
    fn creds_expired_but_refreshable_is_valid() {
        // An expired access token is still usable when a refresh token exists —
        // Claude Code mints a fresh token on the next call.
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":1}}"#;
        assert_eq!(claude_creds_verdict(body, 1_000_000), Some(true));
    }

    #[test]
    fn creds_expired_no_refresh_is_invalid() {
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x","expiresAt":1}}"#;
        assert_eq!(claude_creds_verdict(body, 1_000_000), Some(false));
    }

    #[test]
    fn creds_no_token_is_none() {
        // No usable token → None (caller falls through to fail-open, not RED).
        assert_eq!(claude_creds_verdict(r#"{"claudeAiOauth":{}}"#, 1), None);
        assert_eq!(claude_creds_verdict("not json", 1), None);
    }

    #[test]
    fn creds_present_without_expiry_is_valid() {
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x"}}"#;
        assert_eq!(claude_creds_verdict(body, 1), Some(true));
    }

    // ── RESILIENT-1636: paused-node reporting ────────────────────────────────

    #[test]
    fn node_env_paused_parse() {
        assert!(node_env_is_paused("export CHUMP_NODE_MODE=paused\n"));
        assert!(node_env_is_paused("CHUMP_NODE_MODE=paused"));
        assert!(!node_env_is_paused("export CHUMP_NODE_MODE=work-ready\n"));
        assert!(!node_env_is_paused("# comment\nexport FOO=bar\n"));
    }

    // ── RESILIENT-1636: re-entry admission vs new-claim refusal ──────────────

    fn write_lease(lock_dir: &Path, session: &str, gap: &str, expires: &str) {
        std::fs::create_dir_all(lock_dir).unwrap();
        std::fs::write(
            lock_dir.join(format!("{session}.json")),
            format!(r#"{{"session_id":"{session}","gap_id":"{gap}","expires_at":"{expires}"}}"#),
        )
        .unwrap();
    }

    #[test]
    fn session_live_lease_detects_self_reentry() {
        let dir = tempfile::tempdir().unwrap();
        let lock = dir.path().join(".chump-locks");
        write_lease(&lock, "sess-A", "GAP-1", "2999-01-01T00:00:00Z");
        assert!(session_holds_live_lease_for_gap(&lock, "GAP-1", "sess-A"));
        // Wrong gap / wrong session / expired → not a re-entry anchor.
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-2", "sess-A"));
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-1", "sess-B"));
        write_lease(&lock, "sess-C", "GAP-9", "2000-01-01T00:00:00Z");
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-9", "sess-C"));
    }

    fn paused_status() -> FarmerStatus {
        // The cuphead ship-wall condition: paused node, stale heartbeat.
        FarmerStatus {
            green: false,
            sentinel_absent: true,
            exit78_free: true,
            oauth_fresh: true,
            heartbeat_fresh: false,
            heartbeat_age_s: Some(80_000),
            paused: true,
            reasons: vec!["farmer paused by node mode (CHUMP_NODE_MODE=paused)".into()],
        }
    }

    #[test]
    fn admission_reentry_admitted_under_paused() {
        // Re-entry of already-claimed work: the dispatch holds the lease, so the
        // ship step (bot-merge re-claim) must reach push even on a paused farmer.
        match build_admission(paused_status(), "GAP-1", Some("sess-A"), true) {
            ClaimAdmission::ReentryAdmit { note } => {
                assert!(note.contains("re-entry"));
                assert!(note.contains("paused"));
                assert!(note.contains("GAP-1"));
            }
            other => panic!("expected ReentryAdmit, got {other:?}"),
        }
    }

    #[test]
    fn admission_new_claim_refused_under_paused() {
        // The gate is not weakened: no live lease for this session → refused.
        match build_admission(paused_status(), "GAP-2", Some("sess-A"), false) {
            ClaimAdmission::Refuse { status } => assert!(status.paused),
            other => panic!("expected Refuse, got {other:?}"),
        }
        // No session at all → refused regardless.
        assert!(matches!(
            build_admission(paused_status(), "GAP-1", None, false),
            ClaimAdmission::Refuse { .. }
        ));
    }

    #[test]
    fn admission_green_admits_without_lease() {
        let mut green = paused_status();
        green.green = true;
        green.paused = false;
        green.heartbeat_fresh = true;
        assert!(matches!(
            build_admission(green, "GAP-1", None, false),
            ClaimAdmission::Green
        ));
    }
}
