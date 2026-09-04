// INFRA-3481 slice: honest go/no-go gate on the CREATE/build path.
// This is the foundational slice — Verdict enum + blocks_build + parse_verdict stub.
// Full LLM-judge rail (cost_axis, run_llm_gonogo, chump gonogo dispatch) lands in follow-up slices.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Go,
    NoGo,
    NeedsNarrowing,
    NoGoOnCost,
}

impl Verdict {
    pub fn blocks_build(&self) -> bool {
        matches!(self, Verdict::NoGo | Verdict::NoGoOnCost)
    }
}

/// Parses a single line of LLM output into a `Verdict`.
///
/// Stub: keyword scan over the uppercased line. "NO-GO" is checked before
/// "GO" since "GO" is a substring of "NO-GO" and "NEEDS-NARROWING".
pub fn parse_verdict(line: &str) -> Option<Verdict> {
    let up = line.to_uppercase();
    if up.contains("NEEDS-NARROWING") || up.contains("NEEDS NARROWING") {
        Some(Verdict::NeedsNarrowing)
    } else if up.contains("NO-GO-ON-COST") || up.contains("NO GO ON COST") {
        Some(Verdict::NoGoOnCost)
    } else if up.contains("NO-GO") || up.contains("NO GO") {
        Some(Verdict::NoGo)
    } else if up.contains("GO") {
        Some(Verdict::Go)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_build_true_for_nogo_variants() {
        assert!(Verdict::NoGo.blocks_build());
        assert!(Verdict::NoGoOnCost.blocks_build());
    }

    #[test]
    fn blocks_build_false_for_go_variants() {
        assert!(!Verdict::Go.blocks_build());
        assert!(!Verdict::NeedsNarrowing.blocks_build());
    }

    #[test]
    fn parse_verdict_recognizes_all_variants() {
        assert_eq!(parse_verdict("GO - strong signal"), Some(Verdict::Go));
        assert_eq!(parse_verdict("NO-GO - too risky"), Some(Verdict::NoGo));
        assert_eq!(
            parse_verdict("NEEDS-NARROWING - scope too broad"),
            Some(Verdict::NeedsNarrowing)
        );
        assert_eq!(
            parse_verdict("NO-GO-ON-COST - exceeds ceiling"),
            Some(Verdict::NoGoOnCost)
        );
        assert_eq!(parse_verdict("gibberish line"), None);
    }
}
