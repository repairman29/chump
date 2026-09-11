//! INFRA-3481/INFRA-5340: honest go/no-go gate on a user's vision
//! (evidence-before-build).
//!
//! `parse_verdict` is cloned from `pr_ac_coverage::parse_judge_verdicts`'s
//! keyword-anywhere-on-the-line parsing shape: robust to case and extra
//! prose from the LLM, format-agnostic ("GO -", "1. GO -", "VERDICT: GO -").

/// Verdict returned by the go/no-go judge for a single vision line.
#[allow(dead_code)] // INFRA-5340 slice: wired into the full gate by later INFRA-3481 slices
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Go,
    NoGo,
    NeedsNarrowing,
    NoGoOnCost,
}

impl Verdict {
    /// True if this verdict should block the build path.
    #[allow(dead_code)] // INFRA-5340 slice: wired into the full gate by later INFRA-3481 slices
    pub fn blocks_build(self) -> bool {
        matches!(self, Verdict::NoGo | Verdict::NoGoOnCost)
    }
}

/// Parse a single LLM-shaped go/no-go output line into a [`Verdict`].
/// `NO-GO` is checked before `GO` since "NO-GO" contains "GO" as a substring
/// (same ordering trick as `parse_judge_verdicts`'s `UNMET`-before-`MET`).
/// Returns `None` if the line contains none of the recognized keywords.
#[allow(dead_code)] // INFRA-5340 slice: wired into the full gate by later INFRA-3481 slices
pub(crate) fn parse_verdict(line: &str) -> Option<Verdict> {
    let up = line.to_uppercase();
    if up.contains("NO-GO") || up.contains("NO GO") || up.contains("NOGO") {
        Some(Verdict::NoGo)
    } else if up.contains("NEEDS-NARROWING") || up.contains("NEEDS NARROWING") {
        Some(Verdict::NeedsNarrowing)
    } else if up.contains("GO") {
        Some(Verdict::Go)
    } else {
        None
    }
}

/// Apply a cost ceiling on top of an existing verdict: if the estimated
/// cost exceeds the ceiling, the cost axis overrides with `NoGoOnCost`
/// regardless of the input verdict; otherwise the input verdict passes
/// through unchanged.
#[allow(dead_code)] // INFRA-4731 slice: wired into the full gate by later INFRA-3481 slices
pub(crate) fn cost_axis(estimate_usd: f64, ceiling_usd: f64, input_verdict: Verdict) -> Verdict {
    if estimate_usd > ceiling_usd {
        Verdict::NoGoOnCost
    } else {
        input_verdict
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_verdict_fixture() {
        let fixture = [
            (
                "VERDICT: GO - clear demand signal, no incumbent risk",
                Some(Verdict::Go),
            ),
            ("1. GO - evidence supports build", Some(Verdict::Go)),
            (
                "VERDICT: NO-GO - no evidence of demand",
                Some(Verdict::NoGo),
            ),
            (
                "2. NO-GO - incumbent already dominates this niche",
                Some(Verdict::NoGo),
            ),
            (
                "VERDICT: NEEDS-NARROWING - vision too broad, narrow the ICP first",
                Some(Verdict::NeedsNarrowing),
            ),
        ];
        for (line, expected) in fixture {
            assert_eq!(parse_verdict(line), expected, "line={line:?}");
        }
    }

    #[test]
    fn test_parse_verdict_unrecognized() {
        assert_eq!(parse_verdict("no keyword here"), None);
    }

    #[test]
    fn test_blocks_build() {
        assert!(Verdict::NoGo.blocks_build());
        assert!(Verdict::NoGoOnCost.blocks_build());
        assert!(!Verdict::Go.blocks_build());
        assert!(!Verdict::NeedsNarrowing.blocks_build());
    }

    #[test]
    fn test_cost_axis_over_ceiling() {
        assert_eq!(cost_axis(8.0, 5.0, Verdict::Go), Verdict::NoGoOnCost);
    }

    #[test]
    fn test_cost_axis_under_ceiling_passthrough() {
        assert_eq!(cost_axis(3.0, 5.0, Verdict::Go), Verdict::Go);
    }
}
