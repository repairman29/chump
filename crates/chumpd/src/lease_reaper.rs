//! Pure-Rust stale lease reaper (`Milestone 4`).
//!
//! Periodically scans `<repo>/.chump-locks/*.json` inside `chumpd` and removes:
//! 1. Leases whose owner PID is confirmed dead on this host (`!chump_pal::is_pid_alive(pid)`).
//! 2. Leases whose `expires_at` (+ 30s grace) or `heartbeat_at` (15m stale window)
//!    has elapsed.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Duration as ChronoDuration, Utc};

/// Default periodic lease-reap interval in seconds.
pub const DEFAULT_LEASE_REAP_INTERVAL_SECS: u64 = 60;

const REAP_GRACE_SECS: i64 = 30;
const HEARTBEAT_STALE_SECS: i64 = 15 * 60;

/// Counts returned by a single [`reap_locks_dir`] pass.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LeaseReapSummary {
    pub scanned: usize,
    pub reaped_expired: usize,
    pub reaped_dead_pid: usize,
}

fn parse_rfc3339_utc(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s.trim())
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

/// Extract an owner PID from either an explicit `"pid"` JSON field or a canonical
/// `claim-<gap>-<pid>-<epoch>.json` lease filename.
pub fn extract_owner_pid(file_stem: &str, json: &serde_json::Value) -> Option<u32> {
    if let Some(pid) = json.get("pid").and_then(|v| {
        v.as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .or_else(|| v.as_str().and_then(|s| s.trim().parse::<u32>().ok()))
    }) {
        if pid > 1 {
            return Some(pid);
        }
    }

    if file_stem.starts_with("claim-") {
        let parts: Vec<&str> = file_stem.rsplitn(3, '-').collect();
        // `rsplitn(3, '-')` yields `[epoch, pid, "claim-<gap>"]`
        if parts.len() == 3 && parts[0].parse::<u64>().is_ok() {
            if let Ok(pid) = parts[1].parse::<u32>() {
                if pid > 1 {
                    return Some(pid);
                }
            }
        }
    }
    None
}

fn is_timestamp_expired_or_stale(json: &serde_json::Value, now: DateTime<Utc>) -> bool {
    if let Some(exp_str) = json.get("expires_at").and_then(|v| v.as_str()) {
        if let Some(exp) = parse_rfc3339_utc(exp_str) {
            if now > exp + ChronoDuration::seconds(REAP_GRACE_SECS) {
                return true;
            }
        }
    }
    if let Some(hb_str) = json.get("heartbeat_at").and_then(|v| v.as_str()) {
        if let Some(hb) = parse_rfc3339_utc(hb_str) {
            if (now - hb).num_seconds() > HEARTBEAT_STALE_SECS {
                return true;
            }
        }
    }
    false
}

/// Scan `locks_dir` once and remove expired or dead-PID `.json` lease files.
pub fn reap_locks_dir(locks_dir: &Path) -> LeaseReapSummary {
    let mut summary = LeaseReapSummary::default();
    let Ok(entries) = fs::read_dir(locks_dir) else {
        return summary;
    };
    let now = Utc::now();

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if stem.starts_with('.') {
            continue;
        }
        summary.scanned += 1;

        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue;
        };

        if let Some(pid) = extract_owner_pid(stem, &val) {
            if !chump_pal::is_pid_alive(pid) {
                if fs::remove_file(&path).is_ok() {
                    summary.reaped_dead_pid += 1;
                }
                continue;
            }
        }

        if is_timestamp_expired_or_stale(&val, now) && fs::remove_file(&path).is_ok() {
            summary.reaped_expired += 1;
        }
    }

    summary
}

/// Spawn the periodic background stale-lease reaper inside `chumpd`.
pub fn spawn_background_reaper(locks_dir: PathBuf, interval_secs: u64) {
    let cadence = interval_secs.max(5);
    tokio::spawn(async move {
        loop {
            let _ = reap_locks_dir(&locks_dir);
            tokio::time::sleep(Duration::from_secs(cadence)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::SecondsFormat;
    use tempfile::TempDir;

    #[test]
    fn reaps_dead_pid_and_expired_leases_while_keeping_live_ones() {
        let tmp = TempDir::new().unwrap();
        let now = Utc::now();
        let future = (now + ChronoDuration::minutes(20)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let past = (now - ChronoDuration::minutes(20)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let now_s = now.to_rfc3339_opts(SecondsFormat::Secs, true);

        // 1. Live lease owned by our own PID -> MUST survive.
        let live_path = tmp.path().join(format!(
            "claim-infra-1-{}-1700000000.json",
            std::process::id()
        ));
        fs::write(
            &live_path,
            serde_json::json!({
                "session_id": "live",
                "expires_at": future,
                "heartbeat_at": now_s,
            })
            .to_string(),
        )
        .unwrap();

        // 2. Dead PID lease -> MUST be reaped.
        let dead_path = tmp.path().join("claim-infra-2-99999991-1700000000.json");
        fs::write(
            &dead_path,
            serde_json::json!({
                "session_id": "dead-pid",
                "expires_at": future,
                "heartbeat_at": now_s,
            })
            .to_string(),
        )
        .unwrap();

        // 3. Expired timestamp lease -> MUST be reaped.
        let exp_path = tmp.path().join("expired-session.json");
        fs::write(
            &exp_path,
            serde_json::json!({
                "session_id": "expired",
                "expires_at": past,
                "heartbeat_at": now_s,
            })
            .to_string(),
        )
        .unwrap();

        let summary = reap_locks_dir(tmp.path());
        assert_eq!(summary.scanned, 3);
        assert_eq!(summary.reaped_dead_pid, 1);
        assert_eq!(summary.reaped_expired, 1);
        assert!(live_path.exists(), "live lease must remain");
        assert!(!dead_path.exists(), "dead-PID lease must be reaped");
        assert!(!exp_path.exists(), "expired lease must be reaped");
    }
}
