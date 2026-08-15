//! INFRA-2225: `chump fleet rebase-queue` — operator surface for the
//! pr-auto-rebase daemon (scripts/coord/pr-auto-rebase.sh).
//!
//! 2026-05-29 overnight: with 25+ PRs in flight the daemon lagged and 8
//! BEHIND PRs accumulated silently — nobody had a single command to check
//! "is the auto-rebase daemon keeping up?" without manually cross-referencing
//! `gh pr list` state against `tail ambient.jsonl`. This gives that one view:
//! current BEHIND count (from the local GitHub cache, INFRA-1081 pattern —
//! no live `gh` call) + how long since the daemon last landed a rebase.
//!
//! Read-only. No network calls: BEHIND count comes from the local
//! `.chump/github_cache.db` (populated by the webhook receiver); if that
//! cache is unavailable, behind_count is reported as unknown rather than
//! falling back to a live `gh` call (this command must stay <500ms, same
//! discipline as `chump fleet pulse`).

use serde::Serialize;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize)]
pub struct RebaseQueueStatus {
    pub generated_at: String,
    /// None when the local GitHub cache DB is unavailable/unqueryable.
    pub behind_count: Option<usize>,
    pub cache_source: String,
    pub last_rebase_ts: Option<String>,
    pub last_rebase_age_secs: Option<u64>,
    /// How long the current BEHIND backlog has gone without a successful
    /// rebase landing — 0 if there's no backlog right now.
    pub backlog_age_secs: u64,
    pub recent_skipped_1h: usize,
    pub recent_deferred_1h: usize,
    pub recent_failed_1h: usize,
    pub throttle_active: bool,
}

pub fn build(repo_root: &Path) -> RebaseQueueStatus {
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");
    let (behind_count, cache_source) = query_behind_count(repo_root);
    let last_rebase = last_event_ts(&ambient, &["pr_auto_rebased", "pr_auto_rebase_fallback"]);
    let now_secs = now_unix();
    let last_rebase_age_secs = last_rebase
        .as_deref()
        .and_then(parse_rfc3339_secs)
        .map(|t| now_secs.saturating_sub(t));
    let backlog_age_secs = match behind_count {
        Some(n) if n > 0 => last_rebase_age_secs.unwrap_or(0),
        _ => 0,
    };
    let throttle_active = last_event_ts(&ambient, &["pr_auto_rebase_throttle"])
        .as_deref()
        .and_then(parse_rfc3339_secs)
        .map(|t| now_secs.saturating_sub(t) < 900)
        .unwrap_or(false);

    RebaseQueueStatus {
        generated_at: now_rfc3339(now_secs),
        behind_count,
        cache_source,
        last_rebase_ts: last_rebase,
        last_rebase_age_secs,
        backlog_age_secs,
        recent_skipped_1h: count_events_last_hour(&ambient, "pr_auto_rebase_skipped", now_secs),
        recent_deferred_1h: count_events_last_hour(
            &ambient,
            "pr_auto_rebase_deferred_for_operator",
            now_secs,
        ),
        recent_failed_1h: count_events_last_hour(&ambient, "pr_auto_rebase_failed", now_secs),
        throttle_active,
    }
}

/// Query the local GitHub PR-state cache for BEHIND+armed open PRs.
/// Mirrors `cache_query_behind_prs` in scripts/coord/lib/github_cache.sh
/// (INFRA-1081) — same table/columns, read-only, no live `gh` call.
fn query_behind_count(repo_root: &Path) -> (Option<usize>, String) {
    let db = repo_root.join(".chump").join("github_cache.db");
    if !db.exists() {
        return (None, "unavailable (no .chump/github_cache.db)".to_string());
    }
    let out = Command::new("sqlite3")
        .arg(&db)
        .arg(
            "SELECT COUNT(*) FROM pr_state \
             WHERE mergeable_state = 'BEHIND' \
               AND auto_merge_enabled = 1 \
               AND merged_at IS NULL",
        )
        .output();
    match out {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout);
            match s.trim().parse::<usize>() {
                Ok(n) => (Some(n), db.display().to_string()),
                Err(_) => (None, "unavailable (unparseable sqlite3 output)".to_string()),
            }
        }
        _ => (None, "unavailable (sqlite3 query failed)".to_string()),
    }
}

fn last_event_ts(ambient: &Path, kinds: &[&str]) -> Option<String> {
    let file = std::fs::File::open(ambient).ok()?;
    let reader = BufReader::new(file);
    let mut latest: Option<String> = None;
    for line in reader.lines().map_while(Result::ok) {
        if !kinds
            .iter()
            .any(|k| line.contains(&format!("\"kind\":\"{}\"", k)))
        {
            continue;
        }
        if let Some(ts) = extract_json_string(&line, "ts") {
            latest = Some(ts);
        }
    }
    latest
}

fn count_events_last_hour(ambient: &Path, kind: &str, now_secs: u64) -> usize {
    let Ok(file) = std::fs::File::open(ambient) else {
        return 0;
    };
    let reader = BufReader::new(file);
    let needle = format!("\"kind\":\"{}\"", kind);
    let mut count = 0usize;
    for line in reader.lines().map_while(Result::ok) {
        if !line.contains(&needle) {
            continue;
        }
        if let Some(ts) = extract_json_string(&line, "ts") {
            if let Some(t) = parse_rfc3339_secs(&ts) {
                if now_secs.saturating_sub(t) <= 3600 {
                    count += 1;
                }
            }
        }
    }
    count
}

fn extract_json_string(s: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":", key);
    let start_colon = s.find(&needle)? + needle.len();
    let after_ws = s[start_colon..]
        .find(|c: char| !c.is_whitespace())
        .map(|i| start_colon + i)?;
    if !s[after_ws..].starts_with('"') {
        return None;
    }
    let val_start = after_ws + 1;
    let val_end = s[val_start..].find('"')? + val_start;
    Some(s[val_start..val_end].to_string())
}

/// Parse a minimal RFC3339 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`) into unix
/// seconds. No timezone offsets — every ambient.jsonl writer uses `date -u`.
fn parse_rfc3339_secs(ts: &str) -> Option<u64> {
    let b = ts.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let y: i64 = ts.get(0..4)?.parse().ok()?;
    let mo: i64 = ts.get(5..7)?.parse().ok()?;
    let d: i64 = ts.get(8..10)?.parse().ok()?;
    let h: i64 = ts.get(11..13)?.parse().ok()?;
    let mi: i64 = ts.get(14..16)?.parse().ok()?;
    let s: i64 = ts.get(17..19)?.parse().ok()?;

    // Days-from-civil algorithm (Howard Hinnant), inverse of the one used
    // in fleet_pulse::now_rfc3339.
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;

    let secs = days * 86400 + h * 3600 + mi * 60 + s;
    if secs < 0 {
        None
    } else {
        Some(secs as u64)
    }
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn now_rfc3339(secs: u64) -> String {
    let days = (secs / 86400) as i64;
    let sod = (secs % 86400) as u32;
    let hr = sod / 3600;
    let mn = (sod % 3600) / 60;
    let sc = sod % 60;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i32 + era as i32 * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let yr = y + if m <= 2 { 1 } else { 0 };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", yr, m, d, hr, mn, sc)
}

pub fn render_text(s: &RebaseQueueStatus) -> String {
    let mut out = String::new();
    out.push_str(&format!("=== Rebase queue — {} ===\n\n", s.generated_at));
    match s.behind_count {
        Some(n) => out.push_str(&format!(
            "BEHIND + armed PRs: {n} (source: {})\n",
            s.cache_source
        )),
        None => out.push_str(&format!(
            "BEHIND + armed PRs: unknown ({})\n",
            s.cache_source
        )),
    }
    match &s.last_rebase_ts {
        Some(ts) => out.push_str(&format!(
            "Last successful auto-rebase: {ts} ({}s ago)\n",
            s.last_rebase_age_secs.unwrap_or(0)
        )),
        None => out.push_str("Last successful auto-rebase: none seen in ambient.jsonl\n"),
    }
    if s.backlog_age_secs > 0 {
        out.push_str(&format!(
            "Backlog age: {}s ({:.1} min) since last landed rebase while BEHIND PRs exist\n",
            s.backlog_age_secs,
            s.backlog_age_secs as f64 / 60.0
        ));
    } else {
        out.push_str("Backlog age: 0 (no BEHIND backlog, or cache unavailable)\n");
    }
    out.push_str(&format!(
        "Last 1h: skipped={} deferred={} failed={}\n",
        s.recent_skipped_1h, s.recent_deferred_1h, s.recent_failed_1h
    ));
    out.push_str(&format!(
        "Queue-aware throttle active: {}\n",
        if s.throttle_active { "yes" } else { "no" }
    ));
    out
}
