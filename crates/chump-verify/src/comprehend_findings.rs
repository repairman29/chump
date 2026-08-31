//! INFRA-3470: structured findings from the `comprehend` organs report.
//!
//! The `comprehend` binary (almanac-organs, shelled out to via
//! `comprehend_tool::comprehend_bin` in the bin crate and reused here for the
//! external-repo verifier) emits a free-text report: one line per section
//! (`WIRING` / `GATES` / `CONFIG`) carrying a coverage label
//! (`full`/`partial`/`none`) plus an optional detail in parens, e.g.
//! `WIRING: full (12 live)`. Every consumer of that report up to now
//! (`src/briefing.rs`, `src/execute_gap.rs`) treats it as opaque prose —
//! embedded verbatim into a prompt or markdown block. That's fine for a
//! human/LLM reader, but it means nothing in the codebase can *reason* about
//! coverage (e.g. "block on a `none` finding") without re-parsing prose
//! ad hoc at each call site.
//!
//! This module gives the report a typed shape once, so callers (the
//! external-repo verifier, `external_verify_merge.rs`) can consume
//! `ComprehendFinding`s instead of grepping strings.

use serde_json::json;

/// One section's coverage verdict from a `comprehend --repo` report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Coverage {
    Full,
    Partial,
    None,
    /// The section had a colon-delimited line but the coverage word wasn't
    /// one of full/partial/none (organs report format drift) — surfaced
    /// rather than silently dropped, so a future format change is visible.
    Unknown,
}

impl Coverage {
    fn parse(word: &str) -> Coverage {
        match word.trim().to_ascii_lowercase().as_str() {
            "full" => Coverage::Full,
            "partial" => Coverage::Partial,
            "none" => Coverage::None,
            _ => Coverage::Unknown,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Coverage::Full => "full",
            Coverage::Partial => "partial",
            Coverage::None => "none",
            Coverage::Unknown => "unknown",
        }
    }
}

/// One structured finding extracted from a comprehend report section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ComprehendFinding {
    /// Section name as reported (e.g. "WIRING", "GATES", "CONFIG").
    pub section: String,
    pub coverage: Coverage,
    /// Free-text detail from the parens, e.g. "12 live". Empty when the
    /// report line carried no detail.
    pub detail: String,
}

/// Parse a `comprehend --repo` text report into structured findings.
///
/// Recognizes lines of the shape `SECTION: coverage` or
/// `SECTION: coverage (detail)`, where SECTION is an all-caps token (the
/// organs' section-header convention). Lines that don't match this shape
/// (blank lines, prose, sub-bullets) are skipped rather than erroring — the
/// report is prose-with-structure, not a strict grammar, so best-effort
/// extraction is the only viable contract.
pub fn parse_comprehend_report(report: &str) -> Vec<ComprehendFinding> {
    let mut findings = Vec::new();
    for line in report.lines() {
        let line = line.trim();
        let Some((section, rest)) = line.split_once(':') else {
            continue;
        };
        let section = section.trim();
        if section.is_empty()
            || !section
                .chars()
                .all(|c| c.is_ascii_uppercase() || c == '_' || c == ' ')
        {
            continue;
        }
        let rest = rest.trim();
        if rest.is_empty() {
            continue;
        }
        let (cov_word, detail) = match rest.split_once('(') {
            Some((cov, detail)) => (cov.trim(), detail.trim_end_matches(')').trim().to_string()),
            None => (rest, String::new()),
        };
        let coverage = Coverage::parse(cov_word);
        // A section line whose "coverage" word isn't recognized AND carries
        // no detail is more likely unrelated prose that happened to contain a
        // colon (e.g. "NOTE: see below") than a real organs finding — skip it.
        if coverage == Coverage::Unknown && detail.is_empty() {
            continue;
        }
        findings.push(ComprehendFinding {
            section: section.to_string(),
            coverage,
            detail,
        });
    }
    findings
}

/// Serialize findings to a JSON value, for embedding in an ambient event or
/// any other structured sink.
pub fn findings_to_json(findings: &[ComprehendFinding]) -> serde_json::Value {
    json!(findings
        .iter()
        .map(|f| json!({
            "section": f.section,
            "coverage": f.coverage.as_str(),
            "detail": f.detail,
        }))
        .collect::<Vec<_>>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_full_with_detail() {
        let report = "WIRING: full (12 live)\nGATES: partial\nCONFIG: none";
        let findings = parse_comprehend_report(report);
        assert_eq!(findings.len(), 3);

        assert_eq!(findings[0].section, "WIRING");
        assert_eq!(findings[0].coverage, Coverage::Full);
        assert_eq!(findings[0].detail, "12 live");

        assert_eq!(findings[1].section, "GATES");
        assert_eq!(findings[1].coverage, Coverage::Partial);
        assert_eq!(findings[1].detail, "");

        assert_eq!(findings[2].section, "CONFIG");
        assert_eq!(findings[2].coverage, Coverage::None);
        assert_eq!(findings[2].detail, "");
    }

    #[test]
    fn skips_non_section_prose_lines() {
        let report = "Comprehension report for foo/bar\n\nWIRING: full (3 live)\n\
                       Some free-text note about the repo.\nDone.";
        let findings = parse_comprehend_report(report);
        assert_eq!(findings.len(), 1, "only WIRING is a real section finding");
        assert_eq!(findings[0].section, "WIRING");
    }

    #[test]
    fn unknown_coverage_word_with_detail_is_surfaced_not_dropped() {
        let report = "GATES: degraded (parser mismatch)";
        let findings = parse_comprehend_report(report);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].coverage, Coverage::Unknown);
        assert_eq!(findings[0].detail, "parser mismatch");
    }

    #[test]
    fn empty_report_yields_no_findings() {
        assert!(parse_comprehend_report("").is_empty());
        assert!(parse_comprehend_report("   \n  \n").is_empty());
    }

    #[test]
    fn findings_to_json_round_trips_fields() {
        let findings = parse_comprehend_report("WIRING: full (12 live)\nCONFIG: none");
        let value = findings_to_json(&findings);
        let arr = value.as_array().expect("json array");
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["section"], "WIRING");
        assert_eq!(arr[0]["coverage"], "full");
        assert_eq!(arr[0]["detail"], "12 live");
        assert_eq!(arr[1]["section"], "CONFIG");
        assert_eq!(arr[1]["coverage"], "none");
    }
}
