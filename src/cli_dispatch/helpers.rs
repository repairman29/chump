//! Shared CLI dispatch helpers, alias expansion, help text, and argument parsers.

use crate::*;
use anyhow::Result;
use std::env;

/// INFRA-3448: the recovery discipline the OS should apply to a STUCK gap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GapDiscipline {
    Retry,
    EscalateModel,
    Decompose,
    FlagHuman,
}

impl GapDiscipline {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            GapDiscipline::Retry => "retry",
            GapDiscipline::EscalateModel => "escalate-model",
            GapDiscipline::Decompose => "decompose",
            GapDiscipline::FlagHuman => "flag-human",
        }
    }
    pub(crate) fn guidance(self) -> &'static str {
        match self {
            GapDiscipline::Retry => "Not stuck yet — retry as-is.",
            GapDiscipline::EscalateModel => {
                "Too HARD (small, conceptual): retry on a stronger model rung \
                 (CHUMP_MODEL_ESCALATION_LADDER). Decomposing a small conceptual \
                 fix does not help."
            }
            GapDiscipline::Decompose => {
                "Too BIG: run `chump gap decompose <ID>` and work the sub-gaps."
            }
            GapDiscipline::FlagHuman => {
                "Automated remedies exhausted (ladder climbed / decompose tried) — needs a human."
            }
        }
    }
}

/// INFRA-3448: route a stuck gap to the right recovery discipline from its SIZE
/// (effort) and failure count (strikes). A small gap that keeps failing is too
/// HARD — escalate the model up [`CHUMP_MODEL_ESCALATION_LADDER`]; a large one
/// is too BIG — decompose it; once the ladder (small) or decomposition (large)
/// is exhausted, it needs a human. This replaces EFFECTIVE-310's blanket
/// "any strike → decompose", which wrongly tried to decompose small conceptual
/// gaps (e.g. CREDIBLE-169: a one-line parser fix two model sizes both missed).
/// Pure — unit-tested across the size × strikes matrix.
pub(crate) fn route_stuck_gap(effort: &str, strikes: u32, model_ladder_len: u32) -> GapDiscipline {
    const RETRY_BELOW: u32 = 2;
    if strikes < RETRY_BELOW {
        return GapDiscipline::Retry;
    }
    let ladder = model_ladder_len.max(1);
    let is_large = matches!(
        effort.trim().to_lowercase().as_str(),
        "l" | "xl" | "large" | "xlarge"
    );
    if is_large {
        // A big gap: break it down. If it keeps failing well past where
        // decomposition should have helped, it's beyond automated help.
        if strikes > ladder + 2 {
            GapDiscipline::FlagHuman
        } else {
            GapDiscipline::Decompose
        }
    } else {
        // Small/medium: conceptually hard, not big. Climb the model ladder;
        // once every rung has been tried and failed, hand to a human.
        if strikes > ladder {
            GapDiscipline::FlagHuman
        } else {
            GapDiscipline::EscalateModel
        }
    }
}

#[cfg(test)]
mod route_stuck_gap_tests {
    use super::{route_stuck_gap, GapDiscipline};

    #[test]
    fn below_threshold_retries_regardless_of_size() {
        assert_eq!(route_stuck_gap("s", 0, 2), GapDiscipline::Retry);
        assert_eq!(route_stuck_gap("s", 1, 2), GapDiscipline::Retry);
        assert_eq!(route_stuck_gap("xl", 1, 2), GapDiscipline::Retry);
    }

    #[test]
    fn small_hard_gap_escalates_then_flags_human() {
        // ladder_len 2: strike 2 → escalate to top rung; strike 3 (>2) → human.
        assert_eq!(route_stuck_gap("xs", 2, 2), GapDiscipline::EscalateModel);
        assert_eq!(route_stuck_gap("s", 2, 2), GapDiscipline::EscalateModel);
        assert_eq!(route_stuck_gap("m", 2, 2), GapDiscipline::EscalateModel);
        assert_eq!(route_stuck_gap("s", 3, 2), GapDiscipline::FlagHuman);
    }

    #[test]
    fn large_gap_decomposes_then_flags_human() {
        assert_eq!(route_stuck_gap("l", 2, 2), GapDiscipline::Decompose);
        assert_eq!(route_stuck_gap("xl", 4, 2), GapDiscipline::Decompose); // ladder+2 == 4
        assert_eq!(route_stuck_gap("l", 5, 2), GapDiscipline::FlagHuman); // > ladder+2
    }

    #[test]
    fn credible_169_class_small_escalates_never_decomposes() {
        // The motivating case: a small/subtle gap must ESCALATE, not decompose
        // — decomposing a one-line conceptual fix is the wrong discipline.
        let d = route_stuck_gap("s", 2, 2);
        assert_eq!(d, GapDiscipline::EscalateModel);
        assert_ne!(d, GapDiscipline::Decompose);
    }

    #[test]
    fn effort_labels_are_case_and_whitespace_tolerant() {
        assert_eq!(route_stuck_gap(" L ", 2, 2), GapDiscipline::Decompose);
        assert_eq!(route_stuck_gap("Large", 2, 2), GapDiscipline::Decompose);
        assert_eq!(route_stuck_gap("XL", 2, 2), GapDiscipline::Decompose);
    }
}

/// INFRA-3446: does a live gap claim belong to the current session? Pure so the
/// preflight self-recognition (a session may ship its OWN claimed work) is
/// unit-testable without the surrounding `std::process::exit` control flow.
/// A missing `CHUMP_SESSION_ID` (None) never matches — anonymous callers are
/// treated as foreign, preserving the "don't stomp another worker's claim" rule.
pub(crate) fn preflight_claim_is_self(current_session: Option<&str>, claim_session: &str) -> bool {
    matches!(current_session, Some(cur) if cur == claim_session)
}

#[cfg(test)]
mod preflight_self_tests {
    use super::preflight_claim_is_self;

    #[test]
    fn own_session_is_self() {
        assert!(preflight_claim_is_self(
            Some("claim-credible-169-2700-1785205121"),
            "claim-credible-169-2700-1785205121"
        ));
    }

    #[test]
    fn foreign_session_is_not_self() {
        assert!(!preflight_claim_is_self(
            Some("claim-mine-1"),
            "claim-someone-else-2"
        ));
    }

    #[test]
    fn absent_session_is_not_self() {
        assert!(!preflight_claim_is_self(None, "claim-anyone-3"));
    }

    #[test]
    fn credible_1569_preflight_selects_shell_tests_for_farmer_status() {
        let paths = vec!["src/farmer_status.rs".to_string()];
        let scripts = crate::preflight::select_shell_tests_for_paths(&paths);
        assert_eq!(
            scripts,
            vec![
                "scripts/ci/test-fleet-kill-switch.sh".to_string(),
                "scripts/ci/test-outcome-gate.sh".to_string(),
                "scripts/ci/test-state-db-yaml-sync.sh".to_string(),
            ]
        );
    }

    #[test]
    fn credible_1569_preflight_selects_no_shell_tests_for_docs_only() {
        let paths = vec!["docs/ROADMAP.md".to_string(), "README.md".to_string()];
        let scripts = crate::preflight::select_shell_tests_for_paths(&paths);
        assert!(scripts.is_empty());
    }
}

/// Serenity adds "Bot " to the token; if .env has "Bot xxx", strip it so we don't send "Bot Bot xxx".
pub(crate) fn normalize_discord_token(s: &str) -> String {
    let s = s.trim();
    if s.eq_ignore_ascii_case("bot") {
        return String::new();
    }
    if s.len() > 4 && s.get(..4).map(|p| p.eq_ignore_ascii_case("bot ")) == Some(true) {
        return s[4..].trim().to_string();
    }
    s.to_string()
}

pub(crate) fn unix_ts() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// INFRA-1611: age-in-days for a gap, preferring `opened_date` (the
/// original-reservation date, stamped by `gap reserve` / the backfill
/// script) over `created_at` (state.db import time). Without this, a
/// fresh `chump gap import` zeroes every gap's age — the P0 aging census
/// in `chump gap audit-priorities` and the "P0 budget = 5 max" enforcement
/// mechanism both depend on real age, not import recency.
pub(crate) fn gap_age_days(opened_date: &str, created_at: i64, now_secs: i64) -> i64 {
    if !opened_date.is_empty() {
        if let Ok(d) = chrono::NaiveDate::parse_from_str(opened_date, "%Y-%m-%d") {
            if let Some(opened_secs) = d.and_hms_opt(0, 0, 0).map(|dt| dt.and_utc().timestamp()) {
                return (now_secs - opened_secs) / 86400;
            }
        }
    }
    (now_secs - created_at) / 86400
}

/// INFRA-1886: `chump gap preflight <ID>` advisory hint. When the target
/// gap is open + unclaimed, surface up to 3 higher-priority unclaimed gaps
/// so the picker is nudged toward what's actually starved without enforcing
/// hard ranked-pull semantics. No exit-code change; prints to stderr after
/// the existing OK line.
///
/// Bypass: `CHUMP_PREFLIGHT_NO_SUGGEST=1` silences the note (mirrors the
/// existing CHUMP_PREFLIGHT_SKIP_* discipline).
///
/// Emits `kind=preflight_priority_hint_shown` to ambient when the note
/// fires, with fields `{target_gap, suggested_gaps_count, target_priority}`.
pub(crate) fn print_priority_hint(
    store: &gap_store::GapStore,
    target_id: &str,
    repo_root: &std::path::Path,
) {
    // Get target priority. If we can't read it, skip silently — preflight's
    // exit code is already set; this is best-effort advisory.
    //
    // gap_store::GapRow.priority is Option<String> on the get() path
    // (different struct than list()'s). Normalize to a plain string.
    let target_priority: String = match store.get(target_id) {
        Ok(Some(row)) => row.priority,
        _ => return,
    };
    // Already P0 → nothing higher to suggest.
    if target_priority == "P0" {
        return;
    }
    // Pull all open gaps; filter to higher-priority (lower priority-number),
    // exclude the target itself, sort by priority asc then created_at asc.
    // INFRA-1555: apply rating-aware tie-break demotion using class ratings
    // from ambient.jsonl (30-day window, threshold 2.5 mean, min 2 samples).
    let opens = match store.list(Some("open")) {
        Ok(v) => v,
        Err(_) => return,
    };
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let class_ratings = atomic_claim::load_class_ratings(&ambient_path);
    let target_rank = priority_rank(&target_priority);
    let mut candidates: Vec<_> = opens
        .into_iter()
        .filter(|g| g.id != target_id)
        .filter(|g| priority_rank(&g.priority) < target_rank)
        .collect();
    candidates.sort_by(|a, b| {
        atomic_claim::effective_priority_rank(&a.priority, &a.id, &class_ratings)
            .cmp(&atomic_claim::effective_priority_rank(
                &b.priority,
                &b.id,
                &class_ratings,
            ))
            .then_with(|| a.created_at.cmp(&b.created_at))
    });
    let top: Vec<_> = candidates.into_iter().take(3).collect();
    if top.is_empty() {
        return;
    }
    eprintln!("[preflight] note — higher-priority unclaimed gaps you could pick instead:");
    for g in &top {
        let title: String = g.title.chars().take(50).collect();
        let pillar = g.title.split(':').next().unwrap_or("").trim();
        eprintln!(
            "[preflight]   {pri:<2} {pillar:<10} {id} — {title}",
            pri = g.priority,
            id = g.id
        );
    }
    // Best-effort ambient emit. Failure here is silent.
    // (ambient_path already bound above for load_class_ratings)
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = format!(
        r#"{{"ts":"{now}","kind":"preflight_priority_hint_shown","target_gap":"{target_id}","suggested_gaps_count":{},"target_priority":"{target_priority}"}}"#,
        top.len()
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{event}");
    }
}

/// Priority string → ordinal (P0=0, P1=1, P2=2, P3=3). Unknown → 99 so it
/// sorts last and doesn't get suggested.
pub(crate) fn priority_rank(p: &str) -> u8 {
    match p {
        "P0" => 0,
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        _ => 99,
    }
}

/// INFRA-431: domains whose rows are pure test fixtures and should be
/// hidden from the default `chump gap list` output. The 2026-05-03 INFRA-428
/// audit found 306 leaked SPIKE/TEST/TEST168 rows in production state.db.
/// Users opt back in via `--include-test-domains`.
pub(crate) fn is_test_domain(domain: &str) -> bool {
    matches!(domain, "SPIKE" | "TEST" | "TEST168")
        || domain.starts_with("TEST")
        || domain.ends_with("TEST")
}

/// INFRA-1259/1878/2984: Returns true if a single AC entry is a placeholder
/// stub or a non-verifiable filler phrase. Only matches entries that ARE
/// stubs, not entries that mention "TODO" in meaningful text (e.g. "AC:
/// ensures no TODO in field X" must not match).
///
/// INFRA-2984: an exact-match allowlist of filler phrases like "verify it
/// works" slipped past the TODO/TBD checks — non-empty, so `chump gap
/// audit-priorities`/preflight let it through as pickable, but not a single
/// concrete, testable claim, so the agent that claimed it had nothing to
/// implement. The phrase list below is deliberately an exact-match
/// allowlist (not a substring/keyword match) so real AC text that happens
/// to contain "works" (e.g. "ensure the retry logic works under load") is
/// never flagged.
pub(crate) fn is_vague_ac_entry(s: &str) -> bool {
    let t = s.trim();
    let upper = t.to_uppercase();
    upper == "TODO"
        || upper == "TBD"
        || upper == "TBC"
        || upper == "N/A"
        || upper.starts_with("TODO:")
        || upper.starts_with("TODO ")
        || upper.starts_with("TBD:")
        || upper.starts_with("TBD ")
        || upper.starts_with("<FILL")
        || upper.starts_with("FILL IN")
        || matches!(
            upper.as_str(),
            "VERIFY IT WORKS"
                | "VERIFY IT"
                | "VERIFY"
                | "IT WORKS"
                | "WORKS"
                | "MAKE IT WORK"
                | "SHOULD WORK"
                | "IT SHOULD WORK"
                | "TEST IT"
                | "DONE"
                | "COMPLETE"
                | "FIX IT"
                | "IMPLEMENT IT"
        )
}

/// INFRA-1259: Check if acceptance_criteria is vague (empty, all-TODO, or all-TBD).
pub(crate) fn is_acceptance_criteria_vague(ac: &str) -> bool {
    let trimmed = ac.trim();
    // Empty AC is vague
    if trimmed.is_empty() {
        return true;
    }

    // Try to parse as JSON array (the canonical format)
    if let Ok(serde_json::Value::Array(arr)) = serde_json::from_str(trimmed) {
        if arr.is_empty() {
            return true; // Empty array
        }
        // All items must be stubs for the gap to be flagged vague (INFRA-1878:
        // entries that merely mention "TODO" in passing must not trigger ⚠).
        let all_vague = arr
            .iter()
            .all(|item| item.as_str().map(is_vague_ac_entry).unwrap_or(false));
        return all_vague;
    }

    // If not JSON array, only flag if the whole string IS a stub keyword.
    let upper = trimmed.to_uppercase();
    upper == "TODO" || upper == "TBD"
}

/// INFRA-094: write a marker recording that the chump CLI just modified
/// docs/gaps.yaml via a canonical operation (`gap dump --out` /
/// `gap ship --update-yaml`). The pre-commit hook reads this marker — if
/// it's < 5 minutes old AND docs/gaps.yaml is staged, the hook treats the
/// diff as canonical and skips the raw-YAML-edit advisory.
///
/// Failures are best-effort: the worst outcome is a spurious pre-commit
/// warning, which is recoverable.
pub(crate) fn write_yaml_op_marker(repo_root: &std::path::Path, op: &str) {
    let dir = repo_root.join(".chump");
    let _ = std::fs::create_dir_all(&dir);
    let marker = dir.join(".last-yaml-op");
    let body = format!(
        "{{\"op\":\"{}\",\"ts\":{},\"sha\":\"{}\"}}\n",
        op,
        unix_ts(),
        env!("CARGO_PKG_VERSION")
    );
    let _ = std::fs::write(&marker, body);
}

/// INFRA-488: parse a friendly duration string ("24h", "7d", "60m",
/// "3600s") into seconds. Pure digits are interpreted as seconds.
/// Returns None for unparseable input.
pub(crate) fn parse_duration_to_secs(s: &str) -> Option<u64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let (num_part, unit_secs): (&str, u64) = if let Some(rest) = s.strip_suffix('d') {
        (rest, 86_400)
    } else if let Some(rest) = s.strip_suffix('h') {
        (rest, 3_600)
    } else if let Some(rest) = s.strip_suffix('m') {
        (rest, 60)
    } else if let Some(rest) = s.strip_suffix('s') {
        (rest, 1)
    } else {
        (s, 1)
    };
    let n: u64 = num_part.parse().ok()?;
    n.checked_mul(unit_secs)
}

// CREDIBLE-623: unit tests for helpers shared by the `gap reserve`, `gap
// claim`, `gap show`, and `gap ship` subcommands (CREDIBLE-004 slice).
#[cfg(test)]
mod credible_623_subcommand_helper_tests {
    use crate::{parse_duration_to_secs, ship_plan_count_behind_ahead};

    // ── parse_duration_to_secs — used by `gap show --since` / `gap list
    // --since` / stuck-gap discipline shared with claim/ship flows ──

    #[test]
    fn parse_duration_plain_seconds() {
        assert_eq!(parse_duration_to_secs("30s"), Some(30));
        assert_eq!(parse_duration_to_secs("30"), Some(30));
    }

    #[test]
    fn parse_duration_minutes_hours_days() {
        assert_eq!(parse_duration_to_secs("5m"), Some(300));
        assert_eq!(parse_duration_to_secs("2h"), Some(7_200));
        assert_eq!(parse_duration_to_secs("1d"), Some(86_400));
    }

    #[test]
    fn parse_duration_empty_is_none() {
        assert_eq!(parse_duration_to_secs(""), None);
        assert_eq!(parse_duration_to_secs("   "), None);
    }

    #[test]
    fn parse_duration_non_numeric_is_none() {
        assert_eq!(parse_duration_to_secs("abc"), None);
        assert_eq!(parse_duration_to_secs("dh"), None);
    }

    #[test]
    fn parse_duration_overflow_is_none() {
        // u64::MAX days would overflow the multiply — checked_mul must catch it.
        assert_eq!(parse_duration_to_secs("18446744073709551615d"), None);
    }

    #[test]
    fn parse_duration_trims_whitespace() {
        assert_eq!(parse_duration_to_secs("  10m  "), Some(600));
    }

    // ── ship_plan_count_behind_ahead — used by `gap ship` to compute the
    // BEHIND/AHEAD counts printed in the ship plan ──

    #[test]
    fn ship_plan_count_behind_ahead_identical_refs_is_zero() {
        // HEAD...HEAD has nothing on either side.
        let (behind, ahead) = ship_plan_count_behind_ahead("HEAD", "HEAD")
            .expect("git rev-list should succeed in a git worktree");
        assert_eq!((behind, ahead), (0, 0));
    }

    #[test]
    fn ship_plan_count_behind_ahead_invalid_spec_is_zero() {
        // An unresolvable ref makes the underlying `git rev-list` fail;
        // the helper degrades to (0, 0) rather than propagating an error.
        let (behind, ahead) = ship_plan_count_behind_ahead("not-a-real-ref-credible-623", "HEAD")
            .expect("command itself should still run and exit non-zero");
        assert_eq!((behind, ahead), (0, 0));
    }
}

/// INFRA-1719: surface file-path-like tokens from arbitrary text (gap
/// description, notes) for the AST crawler to consume.
///
/// We accept paths that:
///   - end in a known source extension (.rs .py .js .ts .tsx .go .sh .yaml .yml),
///   - resolve to an existing file under `repo_root` after a path-join.
///
/// Returns absolute paths (input to crawler), deduplicated, capped at 64 to
/// keep the prompt block bounded.
pub(crate) fn extract_path_hints(
    text: &str,
    repo_root: &std::path::Path,
) -> Vec<std::path::PathBuf> {
    use std::collections::BTreeSet;
    // Match tokens like `crates/foo/src/bar.rs` or `src/main.rs`.
    // Conservative: at least one slash and a known extension.
    static EXT_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = EXT_RE.get_or_init(|| {
        regex::Regex::new(r"[A-Za-z0-9_./\-]+\.(?:rs|py|js|mjs|cjs|ts|tsx|go|sh|bash|yaml|yml)\b")
            .expect("path-hint regex compiles")
    });
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for cap in re.find_iter(text) {
        let raw = cap.as_str().trim_matches(|c: char| {
            !c.is_ascii_alphanumeric() && c != '.' && c != '_' && c != '/' && c != '-'
        });
        if raw.is_empty() || raw.contains("..") {
            continue;
        }
        // Skip URLs (`http://...rs`).
        if raw.starts_with("http") || raw.starts_with("https") {
            continue;
        }
        let candidate = repo_root.join(raw);
        if !candidate.is_file() {
            continue;
        }
        let canon = candidate.canonicalize().unwrap_or(candidate);
        if seen.insert(canon.clone()) {
            out.push(canon);
            if out.len() >= 64 {
                break;
            }
        }
    }
    out
}

/// INFRA-1522: probe the repo's required status checks from branch protection.
///
/// Shells `gh api repos/<owner>/<repo>/branches/main/protection` and extracts
/// the contexts array. Returns empty Vec on any error (caller fails-open).
///
/// Resolves owner/repo from `git remote get-url origin` or the `CHUMP_GH_REPO`
/// env var.
pub(crate) fn list_required_contexts() -> Vec<String> {
    // Allow tests / CI to inject the contexts list (skips the gh shell-out).
    if let Ok(v) = std::env::var("CHUMP_REQUIRED_CHECKS_OVERRIDE") {
        return v
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
    }

    let repo = match std::env::var("CHUMP_GH_REPO") {
        Ok(r) if !r.is_empty() => r,
        _ => {
            // Try `gh repo view` to resolve owner/repo.
            let out = std::process::Command::new("gh")
                .args([
                    "repo",
                    "view",
                    "--json",
                    "nameWithOwner",
                    "-q",
                    ".nameWithOwner",
                ])
                .output();
            match out {
                Ok(o) if o.status.success() => {
                    String::from_utf8_lossy(&o.stdout).trim().to_string()
                }
                _ => return Vec::new(),
            }
        }
    };

    if repo.is_empty() {
        return Vec::new();
    }

    let url = format!("repos/{}/branches/main/protection", repo);
    let out = std::process::Command::new("gh")
        .args(["api", &url, "--jq", ".required_status_checks.contexts[]?"])
        .output();

    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

/// Load .env from CHUMP_HOME/CHUMP_REPO first (so Chump Menu / run-discord.sh always get the right .env),
/// then current dir, then executable dir.
pub(crate) fn load_dotenv() {
    let base = repo_path::runtime_base();
    let env_path = base.join(".env");
    if env_path.is_file() {
        let _ = dotenvy::from_path(&env_path);
        return;
    }
    if dotenvy::dotenv().is_ok() {
        return;
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(dir) = exe.parent() {
            let mut path = dir.to_path_buf();
            path.push(".env");
            let _ = dotenvy::from_path(&path);
        }
    }
}

/// EFFECTIVE-009 — print grouped command reference.
/// Shown when `chump` is run with no args, or when `chump help` / `chump --help` is used.
// EFFECTIVE-011: expand short command aliases before routing.
// "s" is a compound alias: "chump s <ID>" → "chump gap ship <ID>".
/// INFRA-2028: prime `GH_TOKEN` for this process (and every `gh` subprocess
/// it spawns) when the caller hasn't already supplied one. Fixes the class
/// where `chump`'s spawned `gh` calls silently 401 (falls back to anonymous
/// request) because the subprocess context can't read the macOS keychain
/// entry an interactive shell's `gh` uses, even though `gh auth status`
/// reports a valid keyring-backed login. `gh auth token` performs its own
/// keychain read in the *caller's* shell context before chump ever spawns a
/// child, so it is unaffected by the child-subprocess keychain block —
/// resolving it once here and exporting the result lets every later
/// `Command::new("gh")` inherit a working token via plain env-var auth
/// instead of a keychain lookup.
pub(crate) fn ensure_gh_token_env() {
    if std::env::var_os("GH_TOKEN").is_some() || std::env::var_os("GITHUB_TOKEN").is_some() {
        return;
    }
    let Ok(out) = std::process::Command::new("gh")
        .args(["auth", "token"])
        .output()
    else {
        return;
    };
    if !out.status.success() {
        return;
    }
    let token = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if token.is_empty() {
        return;
    }
    // Safety: called once at startup before any threads/async tasks spawn.
    unsafe { std::env::set_var("GH_TOKEN", token) };
}

pub(crate) fn expand_aliases(mut args: Vec<String>) -> Vec<String> {
    if args.len() < 2 {
        return args;
    }
    match args[1].as_str() {
        "g" => {
            args[1] = "gap".to_string();
        }
        "c" => {
            args[1] = "claim".to_string();
        }
        "f" => {
            args[1] = "fleet".to_string();
        }
        "d" => {
            args[1] = "dispatch".to_string();
        }
        "h" => {
            args[1] = "health".to_string();
        }
        "cs" => {
            args[1] = "cost-watch".to_string();
        }
        "s" => {
            args[1] = "gap".to_string();
            args.insert(2, "ship".to_string());
        }
        // INFRA-1238: top-level `chump ship` (literal, not alias-s) was
        // promised in print_help but never wired — fell through to the
        // LLM agent loop. Mirror the `s` expansion.
        // INFRA-1229: leave `chump ship plan` / `chump ship execute` alone
        // — those are the new subcommands (slices 1+2 of bot-merge port).
        // Only the legacy `chump ship <GAP-ID>` form gets the `gap ship` alias.
        "ship" => {
            let sub2 = args.get(2).map(String::as_str);
            let is_ship_executor = matches!(sub2, Some("plan" | "execute" | "run" | "bot-merge"))
                || sub2.map(|s| s.starts_with('-')).unwrap_or(true);
            if !is_ship_executor {
                args[1] = "gap".to_string();
                args.insert(2, "ship".to_string());
            }
        }
        _ => {}
    }
    args
}

/// INFRA-2373: prepend a one-line `chump init` hint to help output when
/// the user has not yet scaffolded `~/.chump/config.toml`. Returns the
/// banner string (incl. trailing blank line) or empty string when:
///   * HOME env is unset (no panic path), or
///   * `~/.chump/config.toml` already exists.
///
/// Tested via `print_help` integration — the standalone helper exists so
/// the same hint can be reused from `chump config show` (see
/// `commands::config::Snapshot::print_human`).
pub(crate) fn chump_init_nudge_if_missing() -> String {
    let home = match std::env::var("HOME") {
        Ok(h) if !h.is_empty() => h,
        _ => return String::new(),
    };
    let cfg = std::path::PathBuf::from(home)
        .join(".chump")
        .join("config.toml");
    if cfg.exists() {
        return String::new();
    }
    "tip: run 'chump init' to scaffold ~/.chump/config.toml (one-time setup)\n\n".to_string()
}

pub(crate) fn print_help() {
    print!("{}", chump_init_nudge_if_missing());
    let ver = version::chump_version();
    println!("chump — gap orchestration tool  (v{ver})");
    println!();
    println!("USAGE");
    println!("  chump <command> [options]");
    println!("  chump <command> --help        show help for that command");
    println!("  chump --version               print version + build SHA");
    println!("  chump --build-info [--json]   print baked build metadata (INFRA-2054)");
    println!("  chump self-check-staleness    classify binary FRESH/STALE/CRITICAL (INFRA-2054)");
    println!("  chump --verbose               escalate RUST_LOG to debug");
    println!("  chump --debug                 debug header (version, args, timestamp) + verbose");
    println!();
    println!("GAP MANAGEMENT");
    println!("  gap <sub>  (alias: g)  list, show, reserve, ship, audit-priorities …");
    println!("  claim <GAP-ID>  (alias: c)  atomic worktree + lease + preflight in one call");
    println!(
        "                              [--role ROLE] tag the claiming session with a role hint"
    );
    println!("  ship <GAP-ID>   (alias: s)  shorthand for 'gap ship <GAP-ID>'");
    println!("  onboard <repo-url-or-path>  first-touch external-repo scanner (INFRA-2108)");
    println!("  improve <owner/repo> [--gap <ID>] [--apply] [--clone-dir <path>]");
    println!("                              autonomous improve loop: pick→dedup→implement→verify-merge (EFFECTIVE-177)");
    println!("  external verify-merge --pr <N> --repo <owner/repo> --gap <ID> [--clone-dir <path>] [--apply]");
    println!("                              autonomous PR merge judge — 3-gate anti-cosmetic bar (CREDIBLE-096)");
    println!("  gen <task>         AI-driven single-shot coding task (offline-LLM)");
    println!();
    println!("FLEET");
    println!("  fleet <sub>  (alias: f)  worker control — up/status/down/doctor …");
    println!("  dispatch <sub>  (alias: d)  route/scoreboard/simulate/cost-report …");
    println!("  brain status [--json]       unified summary: memory + reflections + per-bot routing (INFRA-1773)");
    println!("  brain query <memory|reflections|routing> [--limit N] [--bot NAME] [--json]");
    println!("  orchestrate        Opus-driven conversational loop (interactive)");
    println!();
    println!("ANALYTICS");
    println!("  health  (alias: h)  current gap-registry health snapshot");
    println!(
        "  session-summary    merged + armed + filed PRs in current session window (INFRA-1437)"
    );
    println!("  pe-suite status    P&E suite operator dashboard: curator liveness + consensus (INFRA-2229)");
    println!("  health-digest      markdown digest with P0/P1 counts + warnings");
    println!("  fleet-status       per-worker throughput + lease state");
    println!("  fleet-velocity     PRs/day and ship-rate trend");
    println!("  waste-tally        % of compute spent on closed-without-merge PRs");
    println!("  ship-quality       post-merge signal: pass rate, revert rate");
    println!("  roadmap-status     milestone completion %");
    println!("  roadmap-pillar-score  rank lanes by bottleneck-pillar alignment");
    println!(
        "  mission-grade      current pillar grades (EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE)"
    );
    println!("  lesson-grade       lesson-learning quality score");
    println!("  ci-summary         last-N CI run outcomes");
    println!("  verify --stage <s> unified policy gate: pre-commit|commit-msg|ci (CREDIBLE-155)");
    println!("  classify-failure   categorize a CI/PR failure for the improvement tracker");
    println!(
        "  kpi report         KPI scorecard across all pillars
  kpi report --impact  gap impact ratings (chump gap rate)"
    );
    println!("  kpi report --agents  per-agent throughput (ships/fails/P50)");
    println!("  kpi report --agents --date YYYY-MM-DD  specific date");
    println!("  kpi report --claims  claim-lint bust-rate per model (CREDIBLE-208)");
    println!("  kpi report --ci-pickup  CI runner pickup-latency p50/p95 per hour + ci_runs_queued (CREDIBLE-1512)");
    println!("  kpi report --ci-pickup --emit-if-starved  emit kind=ci_runner_starved when p50 pickup > 10 min");
    println!(
        "  kpi report --debt-index  crown gauge (live_pct/debt/top-5 dormant) + NBA feed (CREDIBLE-357)"
    );
    println!(
        "  kpi report --shell-invariant-writers [--no-gate]  R6.4 gauge: invariant-boundary gate violator count (CREDIBLE-1509)"
    );
    println!(
        "  kpi report --integration  integration-cycle dashboard: ship velocity, CI efficiency, quality, external costs (INFRA-2143)"
    );
    println!("  kpi report --integration --window 24h|7d|30d  window override (default 7d)");
    println!("  claim-lint --range <base>..<head>  ground ship-time claims against the diff (CREDIBLE-208)");
    println!("  cost-watch  (alias: cs)  real-time inference spend + per-slot breakdown");
    println!("  cost record-pr     attach cost metadata to a merged PR");
    println!("  pr-coupling-cost   cost of PRs that move together (coupling smell)");
    println!("  cascade stats      per-slot hit/miss/error counts for the provider cascade");
    println!("  funnel             install → first_task → return_d2 activation funnel");
    println!("  dashboard          open the local web dashboard");
    println!();
    println!("SESSION / REFLECTION");
    println!("  session-track      start or continue a named work session");
    println!("  session-export     export session transcript as markdown");
    println!("  session-resume     re-attach to the most recent session");
    println!("  reflect-delta      compute lesson-delta since last reflection");
    println!("  rebase-stuck       auto-resolve stuck rebase for a given branch");
    println!("  pr fix-clippy      run clippy --fix on the current PR branch");
    println!("  pr triage          assign labels + reviewer to open PRs");
    println!();
    println!("SERVER MODES  (long-running, not for interactive use)");
    println!("  --web              start the PWA web server (default port 3000)");
    println!("  --acp              ACP stdio mode for Zed / JetBrains / VS Code");
    println!("  --discord          Discord gateway bot (requires --features discord)");
    println!("  --telegram         Telegram bot (requires TELEGRAM_BOT_TOKEN)");
    println!("  --slack            Slack Socket Mode bot (requires SLACK_BOT_TOKEN)");
    println!("  --rpc              internal JSON-RPC loop (fleet workers)");
    println!();
    println!("FIRST RUN");
    println!("  init               detect model, write .env, start server, open browser");
    println!();
    println!("DOCS");
    println!("  AGENTS.md          coordination rules and pillar definitions");
    println!("  docs/ROADMAP.md    milestone plan");
    println!("  scripts/README.md  script taxonomy and entry points");
}

/// `chump plan` subcommand (INFRA-1021 / INFRA-8143).
///
/// Thin wrapper around chump-planner library — keeps main.rs free of the
/// scoring/graph internals so the planner can evolve independently. Errors
/// bubble up via Result; reconciliation-gate breach maps to exit code 2.
pub(crate) fn run_plan_subcommand(args: &[String]) -> Result<()> {
    use chump_planner::output::{json as out_json, table, Format};
    use chump_planner::score::TelemetryInputs;
    use chump_planner::{
        build_plan, collect_reconcile, load_gaps_dir, DependencyGraph, PlanRequest, Weights,
    };

    if args.iter().any(|a| a == "--help" || a == "help") {
        println!("Usage: chump plan [OPTIONS]");
        println!();
        println!("Rank the open gap backlog and recommend the next N to dispatch.");
        println!("v0.2: supports --format table|json, --top N, --output PATH, and --write-lock.");
        println!();
        println!("OPTIONS:");
        println!("  --gaps PATH             Gaps directory (default: docs/gaps)");
        println!("  --agents N              Plan for N concurrent agents (default: 5)");
        println!("  --top N                 Limit output to top N items (overrides --agents)");
        println!("  --pillar DOMAIN         Filter to a single domain");
        println!("  --max-effort SIZE       Skip gaps larger than this (xs/s/m/l/xl)");
        println!("  --no-pillar-cap         Disable the running pillar-share cap");
        println!("  --include-blocked       Include gaps with open prerequisites");
        println!("  --format FORMAT         Output format: table | json (default: table)");
        println!("  --json                  Shorthand for --format json");
        println!("  --output PATH           Write output to PATH instead of stdout");
        println!(
            "  --write-lock            Atomically write JSON to .chump-locks/gap-priority.json"
        );
        println!("  --reconcile-threshold N Exit non-zero when status:open+closed_pr backlog > N");
        println!("                          (default 10)");
        return Ok(());
    }

    let mut gaps_path = std::path::PathBuf::from("docs/gaps");
    let mut agents: usize = 5;
    let mut top: Option<usize> = None;
    let mut pillar: Option<String> = None;
    let mut max_effort: Option<String> = None;
    let mut no_pillar_cap = false;
    let mut include_blocked = false;
    let mut reconcile_threshold: usize = 10;
    let mut format = Format::Table;
    let mut output_path: Option<std::path::PathBuf> = None;
    let mut write_lock = false;

    let mut it = args.iter().skip(2);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--gaps" => {
                gaps_path = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--gaps needs a value"))?
                    .into();
            }
            "--agents" => {
                agents = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--agents needs a value"))?
                    .parse()?;
            }
            "--top" => {
                top = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--top needs a value"))?
                        .parse()?,
                );
            }
            "--pillar" => {
                pillar = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--pillar needs a value"))?
                        .clone(),
                );
            }
            "--max-effort" => {
                max_effort = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--max-effort needs a value"))?
                        .clone(),
                );
            }
            "--no-pillar-cap" => no_pillar_cap = true,
            "--include-blocked" => include_blocked = true,
            "--reconcile-threshold" => {
                reconcile_threshold = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--reconcile-threshold needs a value"))?
                    .parse()?;
            }
            "--format" => {
                let v = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--format needs a value"))?;
                format = v.parse()?;
            }
            "--json" => {
                format = Format::Json;
            }
            "--output" => {
                output_path = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--output needs a value"))?
                        .into(),
                );
            }
            "--write-lock" => {
                write_lock = true;
                format = Format::Json;
            }
            other => anyhow::bail!("unknown arg {other} (see chump plan --help)"),
        }
    }

    let gaps = load_gaps_dir(&gaps_path)
        .map_err(|e| anyhow::anyhow!("loading gaps from {}: {e}", gaps_path.display()))?;
    let graph = DependencyGraph::build(&gaps);

    if let Err(cycle) = graph.topo_order() {
        eprintln!(
            "warning: dependency cycle detected ({} members, identity {}): {:?}",
            cycle.gaps.len(),
            &cycle.identity()[..16],
            cycle.gaps.iter().map(|g| g.0.as_str()).collect::<Vec<_>>(),
        );
    }

    let pillar_filter = match pillar.as_deref() {
        Some(s) => Some(<chump_planner::Domain as std::str::FromStr>::from_str(s)?),
        None => None,
    };
    let max_effort_val = match max_effort.as_deref() {
        Some(s) => Some(<chump_planner::Effort as std::str::FromStr>::from_str(s)?),
        None => None,
    };

    let req = PlanRequest {
        agents: top.unwrap_or(agents),
        pillar_filter,
        max_effort: max_effort_val,
        respect_pillar_cap: !no_pillar_cap,
        include_blocked,
    };

    let weights = Weights::default();
    let telemetry = TelemetryInputs::default();
    let today = chrono::Utc::now().date_naive();

    let plan = build_plan(&gaps, &graph, &req, &telemetry, today, &weights);
    let reconcile = collect_reconcile(&gaps);

    let target_file = if let Some(out) = output_path {
        Some(out)
    } else if write_lock {
        Some(std::path::PathBuf::from(".chump-locks/gap-priority.json"))
    } else {
        None
    };

    let atomic_write = |target: &std::path::Path, bytes: &[u8]| -> Result<()> {
        if let Some(parent) = target.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        let tmp = target.with_extension(format!("json.tmp.{}", std::process::id()));
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(&tmp, target)?;
        Ok(())
    };

    match format {
        Format::Table => {
            let rendered = table::render(&plan, &reconcile);
            if let Some(target) = target_file {
                atomic_write(&target, rendered.as_bytes())?;
            } else {
                print!("{rendered}");
            }
        }
        Format::Json => {
            let mut buf = Vec::new();
            out_json::render_json(&plan, &weights, &mut buf)?;
            if let Some(target) = target_file {
                atomic_write(&target, &buf)?;
            } else {
                use std::io::Write;
                let stdout = std::io::stdout();
                let mut handle = stdout.lock();
                handle.write_all(&buf)?;
            }
        }
    }

    if reconcile.breaches(reconcile_threshold) {
        eprintln!(
            "error: reconciliation backlog {} exceeds threshold {} — run scripts/coord/gap-doctor-reconcile.py",
            reconcile.count(),
            reconcile_threshold
        );
        std::process::exit(2);
    }

    Ok(())
}

/// INFRA-3461: parse `chump llm-complete` flags from argv. Scans `args[2..]` for
/// `--system <text>`, `--max-tokens <n>` (default 1024), and `--prompt <text>`.
/// Returns `(system, max_tokens, prompt_from_flag)`; `prompt_from_flag` is `None`
/// when `--prompt` was absent (the caller then reads the prompt from stdin).
/// Pure over `args` so the flag handling is unit-testable without a provider.
pub(crate) fn parse_llm_complete_args(
    args: &[String],
) -> (Option<String>, u32, Option<String>, Option<String>) {
    let mut system = None;
    let mut max_tokens = 1024u32;
    let mut prompt = None;
    let mut positional: Vec<String> = Vec::new();
    // INFRA-3462: --model <class> (haiku/sonnet/opus) biases the cascade's slot
    // selection via CHUMP_PREFERRED_MODEL_CLASS; None = cascade default.
    let mut model_class = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--system" => {
                system = args.get(i + 1).cloned();
                i += 2;
            }
            "--max-tokens" => {
                max_tokens = args.get(i + 1).and_then(|s| s.parse().ok()).unwrap_or(1024);
                i += 2;
            }
            "--prompt" => {
                prompt = args.get(i + 1).cloned();
                i += 2;
            }
            "--model" => {
                model_class = args.get(i + 1).cloned().filter(|s| !s.is_empty());
                i += 2;
            }
            other if !other.starts_with('-') => {
                positional.push(other.to_string());
                i += 1;
            }
            _ => i += 1,
        }
    }
    if prompt.is_none() && !positional.is_empty() {
        prompt = Some(positional.join(" "));
    }
    (system, max_tokens, prompt, model_class)
}

/// INFRA-3475: parse `chump agent-run` flags. Scans `args[2..]` for
/// `--prompt-file <path>` and `--cwd <dir>`. Returns `(prompt_file, cwd)`;
/// `prompt_file` is `None` when the flag is absent (caller reads stdin). Pure so
/// the flag handling is unit-testable without building an agent.
pub(crate) fn parse_agent_run_args(args: &[String]) -> (Option<String>, Option<String>) {
    let mut prompt_file = None;
    let mut cwd = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--prompt-file" => {
                prompt_file = args.get(i + 1).cloned();
                i += 2;
            }
            "--cwd" => {
                cwd = args.get(i + 1).cloned();
                i += 2;
            }
            _ => i += 1,
        }
    }
    (prompt_file, cwd)
}

#[cfg(test)]
mod agent_run_tests {
    use super::parse_agent_run_args;

    fn argv(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_prompt_file_and_cwd() {
        let a = argv(&[
            "chump",
            "agent-run",
            "--prompt-file",
            "/tmp/p.txt",
            "--cwd",
            "/tmp/clone",
        ]);
        let (pf, cwd) = parse_agent_run_args(&a);
        assert_eq!(pf.as_deref(), Some("/tmp/p.txt"));
        assert_eq!(cwd.as_deref(), Some("/tmp/clone"));
    }

    #[test]
    fn defaults_to_stdin_and_current_dir() {
        let a = argv(&["chump", "agent-run"]);
        let (pf, cwd) = parse_agent_run_args(&a);
        assert!(pf.is_none(), "no --prompt-file → None so stdin is read");
        assert!(cwd.is_none(), "no --cwd → run in the current dir");
    }
}

#[cfg(test)]
mod llm_complete_tests {
    use super::parse_llm_complete_args;

    fn argv(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_all_flags() {
        let a = argv(&[
            "chump",
            "llm-complete",
            "--system",
            "you are terse",
            "--max-tokens",
            "256",
            "--prompt",
            "hello",
            "--model",
            "opus",
        ]);
        let (sys, mt, prompt, model) = parse_llm_complete_args(&a);
        assert_eq!(sys.as_deref(), Some("you are terse"));
        assert_eq!(mt, 256);
        assert_eq!(prompt.as_deref(), Some("hello"));
        assert_eq!(model.as_deref(), Some("opus"));
    }

    #[test]
    fn defaults_and_stdin_prompt() {
        // No flags → default max_tokens, no system, prompt None (caller reads stdin),
        // no model class (cascade default).
        let a = argv(&["chump", "llm-complete"]);
        let (sys, mt, prompt, model) = parse_llm_complete_args(&a);
        assert!(sys.is_none());
        assert_eq!(mt, 1024);
        assert!(prompt.is_none(), "no --prompt → None so stdin is read");
        assert!(model.is_none(), "no --model → cascade default");
    }

    #[test]
    fn bad_max_tokens_falls_back_to_default() {
        let a = argv(&["chump", "llm-complete", "--max-tokens", "notanumber"]);
        let (_, mt, _, _) = parse_llm_complete_args(&a);
        assert_eq!(
            mt, 1024,
            "unparseable --max-tokens must not panic; defaults"
        );
    }

    #[test]
    fn empty_model_is_none() {
        // --model "" must not pin an empty class (would zero out the cascade default).
        let a = argv(&["chump", "llm-complete", "--model", ""]);
        let (_, _, _, model) = parse_llm_complete_args(&a);
        assert!(model.is_none());
    }

    #[test]
    fn positional_prompt_when_flag_omitted() {
        let a = argv(&["chump", "llm-complete", "--max-tokens", "16", "Reply", "OK"]);
        let (_, mt, prompt, _) = parse_llm_complete_args(&a);
        assert_eq!(mt, 16);
        assert_eq!(prompt.as_deref(), Some("Reply OK"));
    }
}
