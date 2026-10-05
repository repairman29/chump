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

/// EFFECTIVE-086 slice (EFFECTIVE-955): the graduated autonomy dial.
///
/// `read_level`/`write_level` above operate on the raw `i64` and are the
/// fail-closed kill-switch primitive (RESILIENT-073) — keep them
/// dependency-free. This enum is a typed view over the same file/value so
/// callers can match on named levels instead of magic numbers. Any value
/// outside 0-5 (including all failure modes of `read_level`) maps to
/// `Stop`, preserving the fail-closed contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum AutonomyLevel {
    #[default]
    Stop = 0,
    Observe = 1,
    Assist = 2,
    Supervised = 3,
    Autonomous = 4,
    Unleashed = 5,
}

impl AutonomyLevel {
    /// Human-readable name, matching EFFECTIVE-086's level names.
    pub fn name(self) -> &'static str {
        match self {
            AutonomyLevel::Stop => "STOP",
            AutonomyLevel::Observe => "OBSERVE",
            AutonomyLevel::Assist => "ASSIST",
            AutonomyLevel::Supervised => "SUPERVISED",
            AutonomyLevel::Autonomous => "AUTONOMOUS",
            AutonomyLevel::Unleashed => "UNLEASHED",
        }
    }

    /// EFFECTIVE-086 AC #1/#2: whether this level permits auto-merge at
    /// all. Levels 0-2 (STOP/OBSERVE/ASSIST) never auto-merge — ASSIST
    /// builds PRs but every one waits for a human. Levels 3-5
    /// (SUPERVISED/AUTONOMOUS/UNLEASHED) defer to the existing
    /// chump-policy chain (trust ladder, lane, human-review gates) —
    /// this is a *ceiling*, not a replacement for that chain.
    pub fn allows_auto_merge(self) -> bool {
        self >= AutonomyLevel::Supervised
    }

    /// EFFECTIVE-086 AC #3: worker-concurrency ceiling for this level,
    /// binding into the existing fleet scaling gate
    /// (docs/process/FLEET_SLOS.md / INFRA-518 scale-up criteria) rather
    /// than introducing a parallel cap. `None` means "no level-imposed
    /// ceiling" — the fleet scaling gate's own criteria are the only
    /// limit (UNLEASHED).
    ///
    ///   0 STOP        -> 0 (no workers)
    ///   1 OBSERVE      -> 0 (propose only, zero writes)
    ///   2 ASSIST       -> 1 (build, but every PR waits on a human)
    ///   3 SUPERVISED   -> 2 (matches the 2->3 scale-up tier's starting point)
    ///   4 AUTONOMOUS   -> 4 (matches the fleet scaling gate's 3->4 tier ceiling)
    ///   5 UNLEASHED    -> None (uncapped by level; scaling gate still applies)
    pub fn max_workers(self) -> Option<u32> {
        match self {
            AutonomyLevel::Stop => Some(0),
            AutonomyLevel::Observe => Some(0),
            AutonomyLevel::Assist => Some(1),
            AutonomyLevel::Supervised => Some(2),
            AutonomyLevel::Autonomous => Some(4),
            AutonomyLevel::Unleashed => None,
        }
    }
}

impl From<AutonomyLevel> for i64 {
    fn from(level: AutonomyLevel) -> i64 {
        level as i64
    }
}

/// Out-of-range values (including everything `read_level` fails closed to)
/// map to `Stop` — there is no invalid `AutonomyLevel`.
impl From<i64> for AutonomyLevel {
    fn from(n: i64) -> AutonomyLevel {
        match n {
            0 => AutonomyLevel::Stop,
            1 => AutonomyLevel::Observe,
            2 => AutonomyLevel::Assist,
            3 => AutonomyLevel::Supervised,
            4 => AutonomyLevel::Autonomous,
            5 => AutonomyLevel::Unleashed,
            _ => AutonomyLevel::Stop,
        }
    }
}

/// Typed counterpart to `read_level`: same fail-closed file read, decoded
/// into `AutonomyLevel`. Default (missing/unreadable/corrupt/out-of-range)
/// is `AutonomyLevel::Stop`.
pub fn read_autonomy_level(path: &Path) -> AutonomyLevel {
    AutonomyLevel::from(read_level(path))
}

/// Typed counterpart to `read_autonomy_level` using the default
/// `~/.chump/AUTONOMY_LEVEL` path.
pub fn current_autonomy_level() -> AutonomyLevel {
    read_autonomy_level(&default_path())
}

/// Typed counterpart to `write_level`: persists the enum's numeric value.
pub fn write_autonomy_level(level: AutonomyLevel, path: &Path) -> Result<(), String> {
    write_level(level.into(), path)
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

    #[test]
    fn autonomy_level_default_is_stop() {
        assert_eq!(AutonomyLevel::default(), AutonomyLevel::Stop);
        assert_eq!(i64::from(AutonomyLevel::default()), 0);
    }

    #[test]
    fn autonomy_level_from_i64_round_trips_0_through_5() {
        let expected = [
            AutonomyLevel::Stop,
            AutonomyLevel::Observe,
            AutonomyLevel::Assist,
            AutonomyLevel::Supervised,
            AutonomyLevel::Autonomous,
            AutonomyLevel::Unleashed,
        ];
        for (n, level) in expected.into_iter().enumerate() {
            assert_eq!(AutonomyLevel::from(n as i64), level);
            assert_eq!(i64::from(level), n as i64);
        }
    }

    #[test]
    fn autonomy_level_out_of_range_fails_closed_to_stop() {
        assert_eq!(AutonomyLevel::from(6), AutonomyLevel::Stop);
        assert_eq!(AutonomyLevel::from(-1), AutonomyLevel::Stop);
        assert_eq!(AutonomyLevel::from(999), AutonomyLevel::Stop);
    }

    #[test]
    fn autonomy_level_names() {
        assert_eq!(AutonomyLevel::Stop.name(), "STOP");
        assert_eq!(AutonomyLevel::Observe.name(), "OBSERVE");
        assert_eq!(AutonomyLevel::Assist.name(), "ASSIST");
        assert_eq!(AutonomyLevel::Supervised.name(), "SUPERVISED");
        assert_eq!(AutonomyLevel::Autonomous.name(), "AUTONOMOUS");
        assert_eq!(AutonomyLevel::Unleashed.name(), "UNLEASHED");
    }

    /// EFFECTIVE-086 AC #4: exercise every level 0-5 and assert its
    /// allowed/forbidden action set — auto-merge ceiling + worker-count
    /// ceiling — matches the graduated dial's contract.
    #[test]
    fn autonomy_level_action_set_matrix() {
        let cases = [
            (AutonomyLevel::Stop, false, Some(0)),
            (AutonomyLevel::Observe, false, Some(0)),
            (AutonomyLevel::Assist, false, Some(1)),
            (AutonomyLevel::Supervised, true, Some(2)),
            (AutonomyLevel::Autonomous, true, Some(4)),
            (AutonomyLevel::Unleashed, true, None),
        ];
        for (level, expect_auto_merge, expect_max_workers) in cases {
            assert_eq!(
                level.allows_auto_merge(),
                expect_auto_merge,
                "{:?} auto-merge allowance mismatch",
                level
            );
            assert_eq!(
                level.max_workers(),
                expect_max_workers,
                "{:?} max-workers ceiling mismatch",
                level
            );
        }
    }

    #[test]
    fn read_autonomy_level_missing_file_is_stop() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        assert_eq!(read_autonomy_level(&p), AutonomyLevel::Stop);
    }

    #[test]
    fn write_then_read_autonomy_level_round_trips() {
        let dir = tmp();
        let p = dir.path().join("AUTONOMY_LEVEL");
        write_autonomy_level(AutonomyLevel::Supervised, &p).unwrap();
        assert_eq!(read_autonomy_level(&p), AutonomyLevel::Supervised);
        assert_eq!(read_level(&p), 3);

        write_autonomy_level(AutonomyLevel::Unleashed, &p).unwrap();
        assert_eq!(read_autonomy_level(&p), AutonomyLevel::Unleashed);
    }
}
