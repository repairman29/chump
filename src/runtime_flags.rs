//! INFRA-062 (M4 of WORLD_CLASS_ROADMAP) — minimal feature-flag layer for
//! gating COG-* (and any other) cognitive-architecture experiments.
//!
//! Design (deliberately ~50 LOC):
//!   - One env var: `CHUMP_FLAGS`.
//!   - Comma-separated, case-insensitive: `CHUMP_FLAGS=cog_040,cog_041`.
//!   - One predicate: `is_enabled("cog_040") -> bool`.
//!   - Parsed once at first use (`OnceLock<HashSet<String>>`) so hot paths
//!     are a single `HashSet::contains` lookup.
//!
//! Why so small: the value of feature flags here is policy + discipline,
//! not a fancy framework. The trunk-based dark-launch loop is:
//!
//!   1. New COG-* gap lands behind `cog_NNN` flag (default off).
//!   2. Bench harness runs flag-off baseline vs flag-on candidate; COG
//!      reflection rows tag the flag set under test (`notes=flags=cog_040`).
//!   3. After bench + cycle review, we flip the default by editing the
//!      caller from `if flags::is_enabled("cog_040")` to unconditional.
//!   4. Cleanup PR removes the dead `is_enabled` call site and the flag
//!      from this module's CHUMP_KNOWN_FLAGS list.
//!
//! See `CLAUDE.md` "Hard rules" / "Long COG branches forbidden" for the
//! coordination policy. See `docs/WORLD_CLASS_ROADMAP.md` M4 for rationale.

use std::collections::HashSet;
use std::sync::OnceLock;

/// Cached set of currently-enabled flag names, lower-cased and trimmed.
/// Parsed once on first call from `CHUMP_FLAGS`.
fn enabled_set() -> &'static HashSet<String> {
    static CELL: OnceLock<HashSet<String>> = OnceLock::new();
    CELL.get_or_init(|| parse_flags_str(&std::env::var("CHUMP_FLAGS").unwrap_or_default()))
}

/// Returns `true` when `flag` (case-insensitive) is in `CHUMP_FLAGS`.
///
/// Hot-path callers may freely do `if runtime_flags::is_enabled("cog_040")`
/// without worrying about cost — the env-parse runs once for the process.
pub fn is_enabled(flag: &str) -> bool {
    enabled_set().contains(&flag.trim().to_ascii_lowercase())
}

/// Returns the parsed enabled-set as a sorted Vec (for debugging /
/// `chump --doctor` output).
pub fn enabled_flags_sorted() -> Vec<String> {
    let mut v: Vec<String> = enabled_set().iter().cloned().collect();
    v.sort();
    v
}

/// Pure-fn parser for testability. Splits on `,`, trims, lower-cases,
/// drops empties.
pub fn parse_flags_str(raw: &str) -> HashSet<String> {
    raw.split(',')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_flags_str_handles_comma_separated() {
        let s = parse_flags_str("cog_040,cog_041, COG_042 ");
        assert_eq!(s.len(), 3);
        assert!(s.contains("cog_040"));
        assert!(s.contains("cog_041"));
        assert!(s.contains("cog_042"));
    }

    #[test]
    fn parse_flags_str_drops_empties() {
        let s = parse_flags_str("");
        assert!(s.is_empty());
        let s = parse_flags_str(",,, ,");
        assert!(s.is_empty());
    }

    #[test]
    fn parse_flags_str_is_case_insensitive_and_trimmed() {
        let s = parse_flags_str("  COG_040  ,  cog_041");
        assert!(s.contains("cog_040"));
        assert!(s.contains("cog_041"));
    }

    /// The OnceLock cache means we can't reliably set CHUMP_FLAGS in a
    /// unit test (parse runs at first call, not per-test). Test the pure
    /// parser instead. Integration test in tests/ exercises the env path.
    #[test]
    fn is_enabled_returns_false_for_unknown() {
        assert!(!is_enabled("definitely_not_a_real_flag_name"));
    }
}
