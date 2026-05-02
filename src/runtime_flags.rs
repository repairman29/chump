//! INFRA-062 (M4 of WORLD_CLASS_ROADMAP) — minimal feature-flag layer for
//! gating COG-* (and any other) cognitive-architecture experiments.
//!
//! Design (deliberately small):
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
//!   4. Cleanup PR removes the dead `is_enabled` call site AND the flag
//!      from `KNOWN_FLAGS` below. Unknown flags in `CHUMP_FLAGS` emit a
//!      stderr warning so dead flags surface during the next agent run.
//!
//! See `CLAUDE.md` "Hard rules" / "Long COG branches forbidden" for the
//! coordination policy. See `docs/strategy/WORLD_CLASS_ROADMAP.md` M4 for rationale.

use std::collections::HashSet;
use std::sync::OnceLock;

/// Canonical list of currently-recognized flag names (lower-cased).
///
/// Add an entry here when introducing a new `cog_NNN` (or other-domain)
/// feature flag; remove the entry in the cleanup PR that drops the last
/// `is_enabled("…")` call site. `enabled_set()` warns on `CHUMP_FLAGS`
/// entries not present here so dead flags surface during the next run.
///
/// **Empty by default**: no live cog_NNN experiments at the moment of
/// writing (INFRA-116, 2026-05-02). Update this list when a new flag is
/// introduced.
pub const KNOWN_FLAGS: &[&str] = &[];

/// Cached set of currently-enabled flag names, lower-cased and trimmed.
/// Parsed once on first call from `CHUMP_FLAGS`. Emits a stderr warning
/// for any flag not present in `KNOWN_FLAGS`.
fn enabled_set() -> &'static HashSet<String> {
    static CELL: OnceLock<HashSet<String>> = OnceLock::new();
    CELL.get_or_init(|| {
        let parsed = parse_flags_str(&std::env::var("CHUMP_FLAGS").unwrap_or_default());
        warn_unknown_flags(&parsed);
        parsed
    })
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

/// Pure-fn helper for testability: returns the set of flags in `enabled`
/// that are NOT in `KNOWN_FLAGS`.
pub fn unknown_flags(enabled: &HashSet<String>) -> Vec<String> {
    let known: HashSet<String> = KNOWN_FLAGS.iter().map(|s| s.to_string()).collect();
    let mut v: Vec<String> = enabled.difference(&known).cloned().collect();
    v.sort();
    v
}

fn warn_unknown_flags(enabled: &HashSet<String>) {
    let unknown = unknown_flags(enabled);
    if unknown.is_empty() {
        return;
    }
    eprintln!(
        "[runtime_flags] WARN: CHUMP_FLAGS contains {} unknown flag(s): {}. \
         Either add to KNOWN_FLAGS in src/runtime_flags.rs or remove from CHUMP_FLAGS.",
        unknown.len(),
        unknown.join(", ")
    );
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

    #[test]
    fn unknown_flags_returns_sorted_diff() {
        let enabled = parse_flags_str("cog_999,not_a_flag,zzz_foo");
        let unknown = unknown_flags(&enabled);
        // KNOWN_FLAGS is empty, so all parsed flags are unknown.
        assert_eq!(unknown, vec!["cog_999", "not_a_flag", "zzz_foo"]);
    }

    #[test]
    fn unknown_flags_returns_empty_when_all_known() {
        // Empty enabled set → empty unknown set, regardless of KNOWN_FLAGS.
        let enabled = parse_flags_str("");
        assert!(unknown_flags(&enabled).is_empty());
    }
}
