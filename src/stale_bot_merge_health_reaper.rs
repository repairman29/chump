//! INFRA-1531: stale bot-merge `.health` file reaper.
//!
//! `scripts/coord/bot-merge.sh` writes `.chump-locks/bot-merge-<pid>.health`
//! on startup and removes it on exit (trap EXIT). When a bot-merge process
//! is killed (OOM, `kill -9`, host reboot) the trap never fires and the
//! `.health` file lingers — `queue-health-monitor`/`bot-merge-watchdog.sh`
//! then fire a `bot_merge_hung` ALERT against a process that no longer
//! exists (observed: pid=91790, health from 22h ago, alert firing every
//! 30 min until 11 files were cleaned by hand across 4 worktrees).
//!
//! This module scans `.chump-locks/bot-merge-*.health` and removes any
//! entry whose pid is not alive (`kill -0` fails). It's called from
//! `chump fleet up` (AC2) so the fleet self-heals stale health files on
//! every start.

use std::path::{Path, PathBuf};
use std::process::Command;

/// One reaped (or would-be-reaped) stale health file.
#[derive(Debug, Clone)]
pub struct ReapedHealthFile {
    pub path: PathBuf,
    pub pid: i32,
    pub age_hours: f64,
}

fn pid_alive(pid: i32) -> bool {
    Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Extract the pid encoded in `bot-merge-<pid>.health`.
fn pid_from_filename(path: &Path) -> Option<i32> {
    let stem = path.file_stem()?.to_str()?; // "bot-merge-91790"
    let pid_str = stem.strip_prefix("bot-merge-")?;
    pid_str.parse::<i32>().ok()
}

/// Age of the file in hours, from its mtime, best-effort (0.0 on error).
fn age_hours(path: &Path) -> f64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|mtime| mtime.elapsed().ok())
        .map(|d| d.as_secs_f64() / 3600.0)
        .unwrap_or(0.0)
}

/// Scan `lock_dir` for `bot-merge-*.health` files whose pid is not alive
/// and remove them. Returns the list of files that were reaped.
pub fn reap_stale_health_files(lock_dir: &Path) -> Vec<ReapedHealthFile> {
    let mut reaped = Vec::new();
    let entries = match std::fs::read_dir(lock_dir) {
        Ok(e) => e,
        Err(_) => return reaped,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n,
            None => continue,
        };
        if !name.starts_with("bot-merge-") || !name.ends_with(".health") {
            continue;
        }
        let pid = match pid_from_filename(&path) {
            Some(p) => p,
            None => continue,
        };
        if pid_alive(pid) {
            continue;
        }
        let age = age_hours(&path);
        if std::fs::remove_file(&path).is_ok() {
            reaped.push(ReapedHealthFile {
                path,
                pid,
                age_hours: age,
            });
        }
    }
    reaped
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn reaps_dead_pid_health_file() {
        let dir = tempfile::tempdir().unwrap();
        // pid=99999 is very unlikely to be a live process in CI.
        let path = dir.path().join("bot-merge-99999.health");
        fs::write(&path, r#"{"pid":99999,"started_at":"2026-05-15T20:22:00Z"}"#).unwrap();

        let reaped = reap_stale_health_files(dir.path());

        assert_eq!(reaped.len(), 1);
        assert_eq!(reaped[0].pid, 99999);
        assert!(!path.exists());
    }

    #[test]
    fn leaves_live_pid_health_file() {
        let dir = tempfile::tempdir().unwrap();
        let live_pid = std::process::id() as i32;
        let path = dir
            .path()
            .join(format!("bot-merge-{live_pid}.health"));
        fs::write(&path, r#"{"pid":0}"#).unwrap();

        let reaped = reap_stale_health_files(dir.path());

        assert!(reaped.is_empty());
        assert!(path.exists());
    }

    #[test]
    fn ignores_unrelated_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bot-merge-99999.step");
        fs::write(&path, "init").unwrap();

        let reaped = reap_stale_health_files(dir.path());

        assert!(reaped.is_empty());
        assert!(path.exists());
    }
}
