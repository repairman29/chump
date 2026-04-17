//! Path-lease system for multi-agent coordination.
//!
//! When multiple agents (Chump sessions, Cursor, roadmap bots, autonomy loops)
//! write to the same repo in parallel, they can silently stomp each other's
//! work. This module provides optimistic file-level leases stored under
//! `.chump-locks/` so agents can check "is someone else editing this path?"
//! before writing.
//!
//! # Design
//!
//! - One JSON file per session under `<repo>/.chump-locks/<session_id>.json`.
//! - Each lease declares the paths it covers, plus a TTL.
//! - Before writing any file, an agent calls
//!   [`is_path_claimed_by_other`] and aborts if another session holds it.
//! - Expired leases are reaped automatically on every claim/check.
//!
//! # Path matching
//!
//! A claim can hold:
//! - an exact path: `src/foo.rs` — matches only that path
//! - a directory prefix: `src/bar/` (trailing slash) — matches anything under it
//! - a `**` glob: `ChumpMenu/**` — same as prefix `ChumpMenu/`
//!
//! Queries normalise candidate paths (strip leading `./`) and check against
//! every lock file's patterns with this simple scheme. No regex, no fnmatch.
//! If you need full globs, graduate to a proper YAML queue (see
//! `docs/AGENT_LEASE.md`).
//!
//! # Session IDs
//!
//! Precedence:
//! 1. `CHUMP_SESSION_ID` env var (external agents set this explicitly)
//! 2. `$HOME/.chump/session_id` (stable across runs for the same user+machine)
//! 3. Random UUID (ephemeral fallback)
//!
//! # Threading
//!
//! Lock file writes are atomic (tempfile + rename). Reads are best-effort —
//! a corrupted or mid-write lease file is ignored, not fatal.

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Default lease TTL: 30 minutes.
pub const DEFAULT_TTL_SECS: u64 = 30 * 60;
/// Hard cap on lease TTL: 4 hours. Longer leases become stale before they expire.
pub const MAX_TTL_SECS: u64 = 4 * 60 * 60;
/// Minimum lease TTL (prevents zero-duration leases).
pub const MIN_TTL_SECS: u64 = 60;
/// Grace period after `expires_at` before reaping (tolerates clock skew).
pub const REAP_GRACE_SECS: u64 = 30;
/// Reap a lease whose heartbeat hasn't refreshed in this long, even if
/// expires_at hasn't fired yet (handles crashed agents with long leases).
pub const HEARTBEAT_STALE_SECS: u64 = 15 * 60;

/// Resolve the locks directory under the repo root.
/// Honours `CHUMP_REPO` / `CHUMP_HOME` so tests and out-of-tree callers agree.
pub fn locks_dir() -> PathBuf {
    let root = if let Ok(v) = std::env::var("CHUMP_REPO") {
        PathBuf::from(v)
    } else if let Ok(v) = std::env::var("CHUMP_HOME") {
        PathBuf::from(v)
    } else {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    };
    root.join(".chump-locks")
}

fn ensure_dir() -> Result<PathBuf> {
    let d = locks_dir();
    fs::create_dir_all(&d).with_context(|| format!("mkdir {}", d.display()))?;
    Ok(d)
}

/// Current UTC timestamp in RFC3339 seconds-precision (e.g. "2026-04-17T01:57:48Z").
pub fn now_rfc3339() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

/// A path-lease held by one session over one or more paths.
///
/// Timestamps are RFC3339 UTC strings (matches `docs/AGENT_COORDINATION.md` spec)
/// so external agents (Cursor, scripts) can write lease files by hand without a
/// custom serializer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Lease {
    pub session_id: String,
    pub paths: Vec<String>,
    pub taken_at: String,
    pub expires_at: String,
    pub heartbeat_at: String,
    #[serde(default)]
    pub purpose: String,
    #[serde(default)]
    pub worktree: String,
}

impl Lease {
    /// Returns true if the lease is still in effect: not expired and heartbeat fresh.
    /// Unparseable timestamps are treated as "not live" (safer to drop than hold).
    pub fn is_live(&self, now: DateTime<Utc>) -> bool {
        let Some(expires) = parse_rfc3339(&self.expires_at) else {
            return false;
        };
        let Some(heartbeat) = parse_rfc3339(&self.heartbeat_at) else {
            return false;
        };
        let expired = now > expires + ChronoDuration::seconds(REAP_GRACE_SECS as i64);
        let stale = (now - heartbeat).num_seconds() > HEARTBEAT_STALE_SECS as i64;
        !expired && !stale
    }

    /// Returns true if `candidate` (repo-relative) is covered by any of this lease's paths.
    pub fn covers(&self, candidate: &str) -> bool {
        let c = normalise_path(candidate);
        self.paths.iter().any(|p| path_matches(p, &c))
    }
}

/// Normalise a repo-relative path FOR CANDIDATE-MATCHING use only:
/// - strip leading `./`
/// - collapse multiple `/`
/// - **drop** trailing `/` so a candidate file path is canonical
///
/// This is for the LHS of a match — the file you're about to write. For the
/// pattern side (RHS), use [`normalise_pattern`] which preserves the trailing
/// slash because that's the "directory prefix" marker.
fn normalise_path(p: &str) -> String {
    let mut s = p.trim().trim_start_matches("./").to_string();
    while s.contains("//") {
        s = s.replace("//", "/");
    }
    if s.ends_with('/') && s.len() > 1 {
        s.pop();
    }
    s
}

/// Normalise a path used as a LEASE PATTERN — same as [`normalise_path`] but
/// preserves the trailing `/`. Without this, `claim_paths(&["src/"])` would
/// store `"src"` and lose its directory-prefix semantics, so a later
/// `is_path_claimed_by_other("src/foo.rs")` would not find a conflict.
/// Bug surfaced by `prefix_claim_blocks_nested_path`.
fn normalise_pattern(p: &str) -> String {
    let trailing = p.trim_end().ends_with('/');
    let mut s = normalise_path(p);
    if trailing && s != "/" && !s.ends_with('/') {
        s.push('/');
    }
    s
}

/// Check whether a lease pattern covers a candidate path.
///
/// Pattern grammar:
///   - `src/foo.rs` (no trailing slash, no `**`) → exact match only
///   - `src/` (trailing slash) → directory prefix; matches `src/foo.rs`,
///     `src/deep/nested.rs`, etc. Does NOT match `src_v2/...`.
///   - `ChumpMenu/**` → same as `ChumpMenu/`; both forms supported.
///   - `**` → matches any path.
fn path_matches(pattern: &str, candidate: &str) -> bool {
    let cand = normalise_path(candidate);

    // ** glob (any path).
    if pattern.trim() == "**" {
        return true;
    }

    // path/** glob — treat as directory prefix.
    if let Some(prefix) = pattern.trim().strip_suffix("/**") {
        let prefix = normalise_path(prefix);
        let prefix_slash = format!("{}/", prefix);
        return cand == prefix || cand.starts_with(&prefix_slash);
    }

    // Directory prefix: pattern with trailing `/` (e.g. "src/").
    // Detect from the ORIGINAL pattern so the trailing-slash signal isn't
    // lost to over-eager normalisation.
    if pattern.trim_end().ends_with('/') {
        let prefix = normalise_path(pattern);
        // After normalise_path the trailing slash is gone — that's fine, we
        // just remembered it from the original above.
        let prefix_slash = format!("{}/", prefix);
        return cand == prefix || cand.starts_with(&prefix_slash);
    }

    // Otherwise: exact match.
    let pat = normalise_path(pattern);
    pat == cand
}

/// Returns the stable session ID for this process.
pub fn current_session_id() -> String {
    if let Ok(v) = std::env::var("CHUMP_SESSION_ID") {
        let v = v.trim();
        if !v.is_empty() {
            return v.to_string();
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let p = PathBuf::from(home).join(".chump").join("session_id");
        if let Ok(s) = fs::read_to_string(&p) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
        let id = format!("chump-{}", uuid::Uuid::new_v4());
        if let Some(dir) = p.parent() {
            if fs::create_dir_all(dir).is_ok() {
                let _ = fs::write(&p, &id);
            }
        }
        return id;
    }
    format!("chump-{}", uuid::Uuid::new_v4())
}

fn lease_path_for(session_id: &str) -> Result<PathBuf> {
    // Sanitise session_id to a safe filename (alphanumeric + - _ only).
    let safe: String = session_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if safe.is_empty() || safe.len() > 128 {
        return Err(anyhow!("invalid session id"));
    }
    Ok(ensure_dir()?.join(format!("{}.json", safe)))
}

fn atomic_write(target: &Path, bytes: &[u8]) -> Result<()> {
    let dir = target
        .parent()
        .ok_or_else(|| anyhow!("lease file has no parent"))?;
    fs::create_dir_all(dir).ok();
    let tmp = dir.join(format!(
        ".tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    {
        let mut f =
            fs::File::create(&tmp).with_context(|| format!("create tempfile {}", tmp.display()))?;
        f.write_all(bytes)?;
        f.sync_all().ok();
    }
    fs::rename(&tmp, target)
        .with_context(|| format!("rename {} -> {}", tmp.display(), target.display()))?;
    Ok(())
}

/// Read a lease file, returning None on any parse error (corrupt/mid-write/etc).
fn read_lease(path: &Path) -> Option<Lease> {
    let s = fs::read_to_string(path).ok()?;
    serde_json::from_str::<Lease>(&s).ok()
}

/// List every active lease in the locks dir, reaping expired ones as a
/// side effect. Never fails — unreadable files are silently skipped.
pub fn list_active() -> Vec<Lease> {
    let dir = match ensure_dir() {
        Ok(d) => d,
        Err(_) => return Vec::new(),
    };
    let now = Utc::now();
    let mut out = Vec::new();
    let entries = match fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.extension().map(|e| e == "json").unwrap_or(false) {
            continue;
        }
        match read_lease(&p) {
            Some(lease) if lease.is_live(now) => out.push(lease),
            Some(_stale) => {
                // Reap expired/stale — best-effort; ignore failures.
                let _ = fs::remove_file(&p);
            }
            None => {} // unreadable, leave it
        }
    }
    out
}

/// Returns `Some(holder_session_id)` if `path` is covered by a live lease
/// held by a *different* session. Returns `None` if unclaimed or held by
/// `my_session_id` itself.
pub fn is_path_claimed_by_other(path: &str, my_session_id: &str) -> Option<String> {
    let candidate = normalise_path(path);
    for lease in list_active() {
        if lease.session_id == my_session_id {
            continue;
        }
        if lease.covers(&candidate) {
            return Some(lease.session_id.clone());
        }
    }
    None
}

/// Return Some(holder) for the first path in `paths` that is claimed by
/// another session, or None if every path is free.
pub fn first_conflict<'a>(paths: &'a [&'a str], my_session_id: &str) -> Option<(&'a str, String)> {
    for p in paths {
        if let Some(holder) = is_path_claimed_by_other(p, my_session_id) {
            return Some((*p, holder));
        }
    }
    None
}

/// Claim a set of paths for this session.
///
/// Fails if any path is already claimed by another live session. The caller
/// is expected to propagate the error message (it names the conflicting
/// session) and retry or back off.
///
/// The caller should release the lease via [`release`] when done; otherwise
/// it expires after `ttl_secs`.
pub fn claim_paths(paths: &[&str], ttl_secs: u64, purpose: &str) -> Result<Lease> {
    let session_id = current_session_id();
    let ttl = ttl_secs.clamp(MIN_TTL_SECS, MAX_TTL_SECS);

    // First, snapshot live leases and check for conflicts.
    if let Some((path, holder)) = first_conflict(paths, &session_id) {
        return Err(anyhow!(
            "path `{}` is claimed by another session `{}`; retry after they release or wait for expiry",
            path,
            holder
        ));
    }

    let now = Utc::now();
    let expires = now + ChronoDuration::seconds(ttl as i64);
    let lease = Lease {
        session_id: session_id.clone(),
        // Use normalise_pattern (not normalise_path) so trailing-slash
        // directory markers survive the round-trip. Otherwise a claim of
        // "src/" gets stored as "src" and stops matching nested files.
        paths: paths.iter().map(|p| normalise_pattern(p)).collect(),
        taken_at: now.to_rfc3339_opts(SecondsFormat::Secs, true),
        expires_at: expires.to_rfc3339_opts(SecondsFormat::Secs, true),
        heartbeat_at: now.to_rfc3339_opts(SecondsFormat::Secs, true),
        purpose: purpose.to_string(),
        worktree: std::env::var("CHUMP_WORKTREE_NAME").unwrap_or_default(),
    };

    let target = lease_path_for(&session_id)?;
    let bytes = serde_json::to_vec_pretty(&lease)?;
    atomic_write(&target, &bytes)?;
    Ok(lease)
}

/// Refresh a lease's heartbeat (and optionally extend its expiry).
/// Call every ~60s from long-running sessions.
pub fn heartbeat(lease: &mut Lease, extend_by_secs: Option<u64>) -> Result<()> {
    let now = Utc::now();
    lease.heartbeat_at = now.to_rfc3339_opts(SecondsFormat::Secs, true);
    if let Some(extra) = extend_by_secs {
        let clamped = extra.clamp(MIN_TTL_SECS, MAX_TTL_SECS);
        let new_expires = now + ChronoDuration::seconds(clamped as i64);
        lease.expires_at = new_expires.to_rfc3339_opts(SecondsFormat::Secs, true);
    }
    let target = lease_path_for(&lease.session_id)?;
    let bytes = serde_json::to_vec_pretty(lease)?;
    atomic_write(&target, &bytes)?;
    Ok(())
}

/// Release a lease immediately. Idempotent — missing file is not an error.
pub fn release(lease: &Lease) -> Result<()> {
    let target = lease_path_for(&lease.session_id)?;
    match fs::remove_file(&target) {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).context("release lease"),
    }
}

/// Remove any expired or stale lease files. Returns the count reaped.
/// Safe to call from a periodic watchdog.
pub fn reap_expired() -> u64 {
    let dir = match ensure_dir() {
        Ok(d) => d,
        Err(_) => return 0,
    };
    let now = Utc::now();
    let mut reaped = 0u64;
    let entries = match fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return 0,
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.extension().map(|e| e == "json").unwrap_or(false) {
            continue;
        }
        match read_lease(&p) {
            Some(lease) if !lease.is_live(now) => {
                if fs::remove_file(&p).is_ok() {
                    reaped += 1;
                }
            }
            None => {
                if fs::remove_file(&p).is_ok() {
                    reaped += 1;
                }
            }
            _ => {}
        }
    }
    reaped
}

/// Spawn a background tokio task that refreshes `lease`'s heartbeat every
/// `interval_secs` (clamped to 10..=300). The task exits cleanly when the
/// returned handle is dropped or `cancel_tx` fires.
///
/// Why automate: the happy-path for a long-running agent is to claim at
/// start and release at end, but real sessions spend 2–10 minutes inside
/// the LLM's tool loop or a slow build. Without heartbeats the lease
/// reaps at HEARTBEAT_STALE_SECS (15 min) and another agent steals its
/// files mid-work. With this helper the pattern is:
///
/// ```ignore
/// let lease = claim_paths(&["src/foo.rs"], 1800, "edit foo")?;
/// let _heartbeat = start_background_heartbeat(lease.clone(), 60, None);
/// // ... long work ...
/// release(&lease)?;  // _heartbeat drops here, cancelling the task
/// ```
///
/// The returned handle is `abort`-safe — dropping it sends the cancel
/// signal, the task wakes, notices, and exits without another heartbeat.
pub fn start_background_heartbeat(
    mut lease: Lease,
    interval_secs: u64,
    extend_by_secs: Option<u64>,
) -> tokio::task::JoinHandle<()> {
    let interval = interval_secs.clamp(10, 300);
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(interval));
        // Skip the initial immediate tick — caller just claimed.
        ticker.tick().await;
        loop {
            ticker.tick().await;
            if let Err(e) = heartbeat(&mut lease, extend_by_secs) {
                tracing::warn!(
                    target: "chump::agent_lease",
                    session_id = %lease.session_id,
                    error = %e,
                    "background heartbeat failed; will retry next tick"
                );
            }
        }
    })
}

/// Convenience: claim paths AND start a background heartbeat in one call.
///
/// Returns `(lease, heartbeat_handle)`. Drop the handle (or let the caller
/// return) to stop refreshing. Call `release(&lease)` and then drop the
/// handle to shut down cleanly.
pub fn claim_with_heartbeat(
    paths: &[&str],
    ttl_secs: u64,
    purpose: &str,
    heartbeat_interval_secs: u64,
) -> Result<(Lease, tokio::task::JoinHandle<()>)> {
    let lease = claim_paths(paths, ttl_secs, purpose)?;
    // Extend by ttl on each heartbeat so long-running work stays claimed
    // without the caller having to compute intervals.
    let handle = start_background_heartbeat(lease.clone(), heartbeat_interval_secs, Some(ttl_secs));
    Ok((lease, handle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    fn setup_tmp() -> PathBuf {
        let dir =
            PathBuf::from("target").join(format!("agent_lease_test_{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        dir
    }

    fn teardown(dir: &Path) {
        std::env::remove_var("CHUMP_REPO");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    #[serial]
    fn path_matches_exact() {
        assert!(path_matches("src/foo.rs", "src/foo.rs"));
        assert!(!path_matches("src/foo.rs", "src/bar.rs"));
    }

    #[test]
    #[serial]
    fn path_matches_prefix_slash() {
        assert!(path_matches("src/", "src/foo.rs"));
        assert!(path_matches("src/", "src/bar/baz.rs"));
        assert!(!path_matches("src/", "docs/foo.rs"));
        // `src` without slash must NOT swallow `src_v2`
        assert!(!path_matches("src", "src_v2/foo.rs"));
    }

    #[test]
    #[serial]
    fn path_matches_glob() {
        assert!(path_matches("ChumpMenu/**", "ChumpMenu/foo.rs"));
        assert!(path_matches("ChumpMenu/**", "ChumpMenu/a/b/c.rs"));
        assert!(!path_matches("ChumpMenu/**", "Other/foo.rs"));
        assert!(path_matches("**", "anything/at/all"));
    }

    #[test]
    #[serial]
    fn normalise_strips_leading_dot_and_trailing_slash() {
        assert_eq!(normalise_path("./src/foo.rs"), "src/foo.rs");
        assert_eq!(normalise_path("src//foo.rs"), "src/foo.rs");
        assert_eq!(normalise_path("src/"), "src");
    }

    #[test]
    #[serial]
    fn claim_release_roundtrip() {
        let dir = setup_tmp();
        std::env::set_var("CHUMP_SESSION_ID", "test-claim-release");
        let lease = claim_paths(&["src/foo.rs"], 300, "test").unwrap();
        assert_eq!(lease.session_id, "test-claim-release");
        assert_eq!(lease.paths, vec!["src/foo.rs".to_string()]);
        let active = list_active();
        assert_eq!(active.len(), 1);
        release(&lease).unwrap();
        assert_eq!(list_active().len(), 0);
        std::env::remove_var("CHUMP_SESSION_ID");
        teardown(&dir);
    }

    #[test]
    #[serial]
    fn second_session_blocked_on_overlapping_path() {
        let dir = setup_tmp();
        std::env::set_var("CHUMP_SESSION_ID", "sess-A");
        let _a = claim_paths(&["src/foo.rs"], 300, "A").unwrap();

        std::env::set_var("CHUMP_SESSION_ID", "sess-B");
        let err = claim_paths(&["src/foo.rs"], 300, "B").unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("sess-A"), "error should name holder: {}", msg);

        // Different path — should succeed
        let _b = claim_paths(&["src/bar.rs"], 300, "B").unwrap();

        std::env::remove_var("CHUMP_SESSION_ID");
        teardown(&dir);
    }

    #[test]
    #[serial]
    fn prefix_claim_blocks_nested_path() {
        let dir = setup_tmp();
        std::env::set_var("CHUMP_SESSION_ID", "sess-X");
        let _ = claim_paths(&["src/"], 300, "X").unwrap();

        std::env::set_var("CHUMP_SESSION_ID", "sess-Y");
        let err = claim_paths(&["src/deep/nested.rs"], 300, "Y").unwrap_err();
        assert!(err.to_string().contains("sess-X"));

        std::env::remove_var("CHUMP_SESSION_ID");
        teardown(&dir);
    }

    #[test]
    #[serial]
    fn expired_lease_is_reaped_and_reclaimable() {
        let dir = setup_tmp();
        std::env::set_var("CHUMP_SESSION_ID", "sess-old");
        let mut lease = claim_paths(&["src/zzz.rs"], 60, "old").unwrap();
        // Backdate the lease so it is expired + stale.
        lease.expires_at = "2000-01-01T00:00:00Z".to_string();
        lease.heartbeat_at = "2000-01-01T00:00:00Z".to_string();
        let path = lease_path_for(&lease.session_id).unwrap();
        fs::write(&path, serde_json::to_vec_pretty(&lease).unwrap()).unwrap();

        let reaped = reap_expired();
        assert!(reaped >= 1, "should reap at least the backdated lease");
        assert_eq!(list_active().len(), 0);

        // New session can now claim
        std::env::set_var("CHUMP_SESSION_ID", "sess-new");
        let _ = claim_paths(&["src/zzz.rs"], 300, "new").unwrap();

        std::env::remove_var("CHUMP_SESSION_ID");
        teardown(&dir);
    }

    #[test]
    #[serial]
    fn same_session_can_reclaim_own_path() {
        let dir = setup_tmp();
        std::env::set_var("CHUMP_SESSION_ID", "sess-reclaim");
        let _ = claim_paths(&["src/q.rs"], 300, "first").unwrap();
        // Re-claiming the SAME path from the SAME session overwrites (not conflict).
        let lease2 = claim_paths(&["src/q.rs", "src/r.rs"], 300, "second").unwrap();
        assert_eq!(lease2.paths.len(), 2);
        assert_eq!(list_active().len(), 1); // still one file — overwritten
        std::env::remove_var("CHUMP_SESSION_ID");
        teardown(&dir);
    }

    #[test]
    #[serial]
    fn is_path_claimed_by_other_identifies_holder() {
        let dir = setup_tmp();
        std::env::set_var("CHUMP_SESSION_ID", "sess-holder");
        let _ = claim_paths(&["docs/gaps.yaml"], 300, "holder").unwrap();

        // From another session
        assert_eq!(
            is_path_claimed_by_other("docs/gaps.yaml", "sess-other").as_deref(),
            Some("sess-holder")
        );
        // From the holder itself — None (no conflict with self)
        assert_eq!(
            is_path_claimed_by_other("docs/gaps.yaml", "sess-holder"),
            None
        );
        // Unclaimed path — None
        assert_eq!(
            is_path_claimed_by_other("src/unrelated.rs", "sess-other"),
            None
        );

        std::env::remove_var("CHUMP_SESSION_ID");
        teardown(&dir);
    }
}
