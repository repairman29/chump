/// RESILIENT-073: Fleet kill switch — `~/.chump/AUTONOMY_LEVEL` is the
/// single source of truth for whether the fleet may perform any work.
///
/// # Fail-closed contract
///
/// This module has **zero** dependency on chump-ops, state.db, NATS, the
/// GitHub cache, or any network call. It does exactly one thing: read a
/// file, parse an integer, and return go/stop. Any failure mode — file
/// absent, unreadable, empty, non-numeric, or corrupt — RETURNS STOP.
/// There is no shared failure mode with the fleet: this check works even
/// when the rest of the control plane is deadlocked or running away.
///
/// # Invariant
///
/// Do NOT add I/O, DB reads, or any `chump` op to this module. That is
/// the anti-pattern being replaced (`.chump/fleet-paused` + daemons that
/// crash on it). The value of this check comes entirely from its
/// independence.
use std::path::{Path, PathBuf};

/// The default path for the kill switch flag, relative to $HOME.
pub const AUTONOMY_LEVEL_REL: &str = ".chump/AUTONOMY_LEVEL";

/// Returns the path to the AUTONOMY_LEVEL file: `~/.chump/AUTONOMY_LEVEL`.
/// Falls back to `/tmp/chump-AUTONOMY_LEVEL` if $HOME is unset (never
/// reachable in normal operation; purely defensive).
pub fn default_path() -> PathBuf {
    std::env::var("HOME")
        .ok()
        .map(|h| PathBuf::from(h).join(AUTONOMY_LEVEL_REL))
        .unwrap_or_else(|| PathBuf::from("/tmp/chump-AUTONOMY_LEVEL"))
}

/// Read the autonomy level from the flag file at `path`.
///
/// Fail-closed: returns `0` (STOP) for every failure mode:
///   - file missing
///   - unreadable (permission error, I/O error)
///   - empty content
///   - content is not a valid integer
///   - content parses to a negative number (treat as 0)
///
/// Returns the parsed non-negative integer on success.
pub fn read_level(path: &Path) -> i64 {
    let content = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(_) => return 0, // missing or unreadable → STOP
    };
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return 0; // empty → STOP
    }
    match trimmed.parse::<i64>() {
        Ok(n) if n > 0 => n,
        _ => 0, // non-numeric, zero, or negative → STOP
    }
}

/// Returns `true` if the fleet is permitted to do work (level >= 1).
/// Returns `false` (STOP) for level == 0 and for every error condition.
///
/// This is the canonical gate. Call this from every work entry-point.
pub fn is_go() -> bool {
    read_level(&default_path()) >= 1
}

/// Same as `is_go()` but reads from an explicit path (for tests and
/// ops that have a custom AUTONOMY_LEVEL path).
pub fn is_go_at(path: &Path) -> bool {
    read_level(path) >= 1
}

/// Write `level` to the flag file, creating `~/.chump/` if needed.
/// Returns an error string (never panics) if the write fails.
pub fn write_level(level: i64, path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create_dir_all {:?}: {e}", parent))?;
    }
    std::fs::write(path, format!("{level}\n")).map_err(|e| format!("write {:?}: {e}", path))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn tmp() -> TempDir {
        tempfile::tempdir().expect("tmp dir")
    }

    #[test]
    fn missing_file_is_stop() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        assert_eq!(read_level(&p), 0, "missing → 0 (STOP)");
    }

    #[test]
    fn empty_file_is_stop() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        fs::write(&p, "").unwrap();
        assert_eq!(read_level(&p), 0, "empty → 0 (STOP)");
    }

    #[test]
    fn whitespace_only_is_stop() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        fs::write(&p, "   \n").unwrap();
        assert_eq!(read_level(&p), 0, "whitespace → 0 (STOP)");
    }

    #[test]
    fn non_numeric_is_stop() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        fs::write(&p, "banana\n").unwrap();
        assert_eq!(read_level(&p), 0, "non-numeric → 0 (STOP)");
    }

    #[test]
    fn zero_is_stop() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        fs::write(&p, "0\n").unwrap();
        assert_eq!(read_level(&p), 0, "0 → STOP");
        assert!(!is_go_at(&p));
    }

    #[test]
    fn negative_is_stop() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        fs::write(&p, "-1\n").unwrap();
        assert_eq!(read_level(&p), 0, "negative → 0 (STOP)");
    }

    #[test]
    fn one_is_go() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        fs::write(&p, "1\n").unwrap();
        assert_eq!(read_level(&p), 1);
        assert!(is_go_at(&p));
    }

    #[test]
    fn five_is_go() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        fs::write(&p, "5\n").unwrap();
        assert_eq!(read_level(&p), 5);
        assert!(is_go_at(&p));
    }

    #[test]
    fn write_then_read() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        write_level(5, &p).unwrap();
        assert_eq!(read_level(&p), 5);
        write_level(0, &p).unwrap();
        assert_eq!(read_level(&p), 0);
    }
}
