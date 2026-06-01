//! INFRA-1883: `/api/dashboard-summary` — operator quick-glance endpoint.
//!
//! Returns a single JSON document with:
//!
//! - `today_ships` — count of PRs merged in the last 24 h.
//!   Reads `.chump/github_cache.db` first (cache-first per INFRA-1081);
//!   falls through to `gh pr list --state merged --json mergedAt` on cold cache.
//! - `ci_qa_score` — payload of the most recent `kind=ci_qa_score` event from
//!   `.chump-locks/ambient.jsonl` (INFRA-1872 emit) within the last 24 h.
//!   Returns `null` when no qualifying event exists.
//! - `active_leases` — top-10 active claim leases sorted by `expires_at` DESC,
//!   sourced from `.chump-locks/claim-*.json`.
//! - `window_hours` — always 24 (seconds per window).

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ── public response shape ─────────────────────────────────────────────────────

/// Top-level response for `GET /api/dashboard-summary`.
#[derive(Debug, Serialize)]
pub struct DashboardSummary {
    pub today_ships: u64,
    pub ci_qa_score: Option<CiQaScore>,
    pub active_leases: Vec<ActiveLease>,
    pub window_hours: u32,
}

/// Payload surfaced from the most-recent `kind=ci_qa_score` ambient event.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CiQaScore {
    /// Pass-rate as a percentage (0.0–100.0).
    pub pct: f64,
    /// Number of CI runs included in the score.
    pub sample_size: u64,
    /// Human-readable status label (e.g. "healthy", "degraded").
    pub status: String,
}

/// One active claim lease entry.
#[derive(Debug, Serialize)]
pub struct ActiveLease {
    pub gap: String,
    pub session: String,
    pub expires_at: String,
}

// ── path helpers ──────────────────────────────────────────────────────────────

/// Resolve the repo root via `git rev-parse --show-toplevel`.
/// Falls back to `.` on failure.
pub fn repo_root() -> PathBuf {
    std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

// ── today_ships ───────────────────────────────────────────────────────────────

/// Count PRs merged in the last `window_hours` hours.
///
/// Strategy:
///  1. Open `.chump/github_cache.db` read-only.
///  2. Query `merged_at IS NOT NULL AND merged_at >= <cutoff_rfc3339>`.
///  3. On any error (missing DB, SQL error), fall back to `gh pr list`.
pub fn count_today_ships(repo_root: &Path, window_hours: u32) -> u64 {
    count_today_ships_from_cache(repo_root, window_hours)
        .unwrap_or_else(|_| count_today_ships_from_gh(window_hours))
}

fn count_today_ships_from_cache(repo_root: &Path, window_hours: u32) -> Result<u64> {
    let db_path = repo_root.join(".chump").join("github_cache.db");
    let conn = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("opening github_cache at {}", db_path.display()))?;

    // Compute the cutoff timestamp as RFC 3339 string.
    // The `merged_at` column stores ISO 8601 strings from GitHub's API, e.g.
    // "2026-05-28T12:34:56Z" — lexicographic comparison is correct for UTC.
    let cutoff = cutoff_rfc3339(window_hours);

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pr_state WHERE merged_at IS NOT NULL AND merged_at >= ?1",
            params![cutoff],
            |r| r.get(0),
        )
        .context("querying merged PR count from cache")?;

    Ok(count.max(0) as u64)
}

/// RFC 3339 timestamp for `now - window_hours`.
fn cutoff_rfc3339(window_hours: u32) -> String {
    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs();
    let cutoff_secs = secs.saturating_sub(u64::from(window_hours) * 3600);
    // Build a minimal RFC 3339 string: YYYY-MM-DDTHH:MM:SSZ
    epoch_to_rfc3339(cutoff_secs)
}

fn epoch_to_rfc3339(secs: u64) -> String {
    // Manual conversion — avoids pulling in `chrono` or `time` crates.
    let s = secs;
    let sec = s % 60;
    let min = (s / 60) % 60;
    let hour = (s / 3600) % 24;
    let days = s / 86400;
    // Days since 1970-01-01.
    let (year, month, day) = days_to_ymd(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, min, sec
    )
}

fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    // Gregorian calendar: 400-year cycle = 146097 days.
    let z = days + 719468; // shift epoch to 0000-03-01
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

/// Fallback: shell out to `gh pr list` to count merged PRs in window.
fn count_today_ships_from_gh(window_hours: u32) -> u64 {
    // Ask for up to 200 recent merged PRs; count those merged after the cutoff.
    let cutoff = cutoff_rfc3339(window_hours);
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "merged",
            "--repo",
            "repairman29/chump",
            "--limit",
            "200",
            "--json",
            "mergedAt",
        ])
        .output();

    let out = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return 0,
    };

    let json: serde_json::Value = match serde_json::from_slice(&out) {
        Ok(v) => v,
        Err(_) => return 0,
    };

    let arr = match json.as_array() {
        Some(a) => a,
        None => return 0,
    };

    arr.iter()
        .filter(|pr| {
            pr.get("mergedAt")
                .and_then(|v| v.as_str())
                .map(|t| t >= cutoff.as_str())
                .unwrap_or(false)
        })
        .count() as u64
}

// ── ci_qa_score ───────────────────────────────────────────────────────────────

/// Read the most recent `kind=ci_qa_score` event from `ambient.jsonl`
/// (INFRA-1872 emit) within the last `window_hours` hours.
///
/// Returns `None` if the file is absent, empty, or no qualifying event
/// exists within the window.
pub fn read_ci_qa_score(repo_root: &Path, window_hours: u32) -> Option<CiQaScore> {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let content = std::fs::read_to_string(&ambient_path).ok()?;

    let cutoff_ms = {
        use std::time::{Duration, SystemTime, UNIX_EPOCH};
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();
        (secs.saturating_sub(u64::from(window_hours) * 3600)) as i64 * 1000
    };

    // Scan lines in reverse; return the first (= most recent) matching event.
    for line in content.lines().rev() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        // Filter by kind.
        if v.get("kind").and_then(|k| k.as_str()) != Some("ci_qa_score") {
            continue;
        }

        // Filter by timestamp — ambient events use either `ts` (ISO string) or
        // `ts_ms` (integer milliseconds). Try both.
        let in_window = event_in_window(&v, cutoff_ms);
        if !in_window {
            continue;
        }

        // Extract the score payload. The INFRA-1872 spec emits the fields
        // directly at the top level; fall back to a nested `payload` object.
        let score = extract_ci_qa_score(&v);
        if score.is_some() {
            return score;
        }
    }

    None
}

fn event_in_window(v: &serde_json::Value, cutoff_ms: i64) -> bool {
    // Try ts_ms (integer milliseconds).
    if let Some(ts_ms) = v.get("ts_ms").and_then(|t| t.as_i64()) {
        return ts_ms >= cutoff_ms;
    }
    // Try ts (ISO 8601 / RFC 3339 string) — parse manually by comparing
    // the first 19 characters lexicographically against the cutoff.
    if let Some(ts_str) = v.get("ts").and_then(|t| t.as_str()) {
        let cutoff_secs = cutoff_ms / 1000;
        let cutoff_str = epoch_to_rfc3339(cutoff_secs.max(0) as u64);
        return ts_str >= cutoff_str.as_str();
    }
    // No timestamp found — include by default (conservatively).
    true
}

fn extract_ci_qa_score(v: &serde_json::Value) -> Option<CiQaScore> {
    // The INFRA-1872 emitter may place fields at top-level or inside `payload`.
    let candidates: &[&serde_json::Value] = &[v, v.get("payload").unwrap_or(v)];

    for obj in candidates {
        let pct = obj
            .get("pct")
            .and_then(|p| p.as_f64())
            .or_else(|| obj.get("pass_pct").and_then(|p| p.as_f64()))
            .or_else(|| obj.get("score").and_then(|p| p.as_f64()));

        let sample_size = obj
            .get("sample_size")
            .and_then(|s| s.as_u64())
            .or_else(|| obj.get("n").and_then(|s| s.as_u64()))
            .or_else(|| obj.get("count").and_then(|s| s.as_u64()));

        let status = obj
            .get("status")
            .and_then(|s| s.as_str())
            .map(str::to_owned)
            .or_else(|| obj.get("label").and_then(|s| s.as_str()).map(str::to_owned));

        if let (Some(pct), Some(sample_size), Some(status)) = (pct, sample_size, status) {
            return Some(CiQaScore {
                pct,
                sample_size,
                status,
            });
        }
    }
    None
}

// ── active_leases ─────────────────────────────────────────────────────────────

/// Parse `.chump-locks/claim-*.json` and return the top-10 leases sorted by
/// `expires_at` descending (soonest-to-expire last; most time remaining first).
pub fn read_active_leases(repo_root: &Path) -> Vec<ActiveLease> {
    let lock_dir = repo_root.join(".chump-locks");
    let pattern = lock_dir.join("claim-*.json");

    let entries = match glob::glob(pattern.to_str().unwrap_or("")) {
        Ok(e) => e,
        Err(_) => return vec![],
    };

    let mut leases: Vec<ActiveLease> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|path| parse_claim_json(&path))
        .collect();

    // Sort by expires_at descending (most time remaining first).
    leases.sort_by(|a, b| b.expires_at.cmp(&a.expires_at));
    leases.truncate(10);
    leases
}

fn parse_claim_json(path: &Path) -> Option<ActiveLease> {
    let content = std::fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&content).ok()?;

    // The claim JSON has varied field names across versions.
    // Try gap_id / gap, session_id / session, expires_at / lease_expires.
    let gap = v
        .get("gap_id")
        .or_else(|| v.get("gap"))
        .and_then(|g| g.as_str())
        .map(str::to_owned)?;

    let session = v
        .get("session_id")
        .or_else(|| v.get("session"))
        .and_then(|s| s.as_str())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            // Derive from filename: claim-<gap>-<session>.json
            path.file_stem()
                .and_then(|s| s.to_str())
                .map(str::to_owned)
                .unwrap_or_default()
        });

    let expires_at = v
        .get("expires_at")
        .or_else(|| v.get("lease_expires"))
        .or_else(|| v.get("expiry"))
        .and_then(|e| {
            // Accept either string or numeric (epoch seconds).
            if let Some(s) = e.as_str() {
                Some(s.to_owned())
            } else {
                e.as_i64().map(|ts| epoch_to_rfc3339(ts.max(0) as u64))
            }
        })
        .unwrap_or_default();

    Some(ActiveLease {
        gap,
        session,
        expires_at,
    })
}

// ── entrypoint called from routes ─────────────────────────────────────────────

/// Build the full `DashboardSummary` for a given repo root.
/// All errors are absorbed into reasonable defaults.
pub fn build_summary(repo_root: &Path) -> DashboardSummary {
    const WINDOW_HOURS: u32 = 24;

    let today_ships = count_today_ships(repo_root, WINDOW_HOURS);
    let ci_qa_score = read_ci_qa_score(repo_root, WINDOW_HOURS);
    let active_leases = read_active_leases(repo_root);

    DashboardSummary {
        today_ships,
        ci_qa_score,
        active_leases,
        window_hours: WINDOW_HOURS,
    }
}
