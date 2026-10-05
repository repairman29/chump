//! Shared `StructuredFinding` types for the ChumpOS comprehension organs
//! (comprehend / flagmap / gatemap / livemap / tracemap). Organs currently
//! emit human prose only; this crate defines the structured shape they need
//! to instead emit machine-parseable findings that a thin filer can pipe into
//! holler and a verifier can consume (INFRA-3470 slice).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One structured observation emitted by a comprehension organ.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StructuredFinding {
    /// Which organ dimension this finding belongs to.
    pub category: FindingCategory,
    /// Where the finding applies — a file path, symbol name, or gate/flag
    /// identifier, depending on `category`.
    pub location: String,
    /// How urgent the finding is.
    pub severity: Severity,
    /// Free-form key/value context (e.g. `flag_name`, `bypass_count`,
    /// `coverage_status`). Kept as a map instead of fixed fields since each
    /// organ's context shape differs.
    pub metadata: BTreeMap<String, String>,
}

/// Which comprehension organ produced (or would produce) a finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FindingCategory {
    /// comprehend: is a capability wired up and reachable.
    Wiring,
    /// gatemap: CI/hook gates a change trips + their bypasses.
    Gate,
    /// flagmap: config flags + inconsistent-default drift.
    Config,
    /// whymap: git-blame provenance for why code exists.
    Provenance,
    /// tracemap: PR/issue history traces.
    Trace,
}

/// Finding severity, ordered least to most urgent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Info,
    Low,
    Medium,
    High,
    Critical,
}

impl StructuredFinding {
    pub fn new(category: FindingCategory, location: impl Into<String>, severity: Severity) -> Self {
        Self {
            category,
            location: location.into(),
            severity,
            metadata: BTreeMap::new(),
        }
    }

    pub fn with_metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.insert(key.into(), value.into());
        self
    }
}

/// High-severity marker substrings (case-insensitive) in an organ bullet —
/// these are the prose cues organ authors already use to flag a real problem
/// (as opposed to a plain informational observation).
const HIGH_SEVERITY_MARKERS: [&str; 5] = ["drift", "missing", "not wired", "unwired", "no caller"];

/// Parse a `comprehend`-style organ report (`## ORGAN (coverage)` section
/// headers, `- ` bullets underneath) into [`StructuredFinding`]s. Pure / no
/// I/O — this is the bridge between today's prose-only organ output and the
/// structured shape a filer or verifier can act on (INFRA-3470).
///
/// An organ section reporting zero coverage (`(none)`) with no bullets
/// underneath is itself surfaced as a `High` finding — "we checked and found
/// nothing" is different from "we never checked."
pub fn parse_organ_report(raw: &str) -> Vec<StructuredFinding> {
    let mut findings = Vec::new();
    let mut current: Option<(FindingCategory, String)> = None;
    let mut saw_bullet = false;

    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some(header) = trimmed.strip_prefix("## ") {
            flush_zero_coverage(&mut findings, &current, saw_bullet);
            current = parse_header(header);
            saw_bullet = false;
            continue;
        }
        let Some(bullet) = trimmed.strip_prefix("- ") else {
            continue;
        };
        let Some((category, _)) = current else {
            continue;
        };
        saw_bullet = true;
        let severity = if is_high_severity(bullet) {
            Severity::High
        } else {
            Severity::Info
        };
        findings.push(StructuredFinding::new(
            category,
            bullet.to_string(),
            severity,
        ));
    }
    flush_zero_coverage(&mut findings, &current, saw_bullet);
    findings
}

fn is_high_severity(bullet: &str) -> bool {
    let lower = bullet.to_lowercase();
    HIGH_SEVERITY_MARKERS.iter().any(|m| lower.contains(m))
}

fn flush_zero_coverage(
    findings: &mut Vec<StructuredFinding>,
    current: &Option<(FindingCategory, String)>,
    saw_bullet: bool,
) {
    if let Some((category, coverage)) = current {
        if coverage.eq_ignore_ascii_case("none") && !saw_bullet {
            findings.push(
                StructuredFinding::new(*category, format!("{category:?} organ"), Severity::High)
                    .with_metadata("coverage_status", "none"),
            );
        }
    }
}

fn parse_header(header: &str) -> Option<(FindingCategory, String)> {
    let (name, coverage) = match header.split_once('(') {
        Some((name, rest)) => (
            name.trim(),
            rest.trim_end().trim_end_matches(')').trim().to_string(),
        ),
        None => (header.trim(), String::new()),
    };
    let category = match name.to_uppercase().as_str() {
        "WIRING" => FindingCategory::Wiring,
        "GATES" | "GATE" => FindingCategory::Gate,
        "CONFIG" => FindingCategory::Config,
        "PROVENANCE" => FindingCategory::Provenance,
        "TRACE" | "TRACES" => FindingCategory::Trace,
        _ => return None,
    };
    Some((category, coverage))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_json() {
        let finding =
            StructuredFinding::new(FindingCategory::Gate, "ci.yml:fast-checks", Severity::High)
                .with_metadata("bypass_count", "3")
                .with_metadata("coverage_status", "full");

        let json = serde_json::to_string(&finding).expect("serialize");
        let back: StructuredFinding = serde_json::from_str(&json).expect("deserialize");

        assert_eq!(back, finding);
        assert_eq!(back.category, FindingCategory::Gate);
        assert_eq!(back.severity, Severity::High);
        assert_eq!(
            back.metadata.get("bypass_count").map(String::as_str),
            Some("3")
        );
    }

    #[test]
    fn category_and_severity_serialize_as_snake_case() {
        let finding =
            StructuredFinding::new(FindingCategory::Provenance, "src/foo.rs", Severity::Info);
        let json = serde_json::to_value(&finding).expect("serialize");
        assert_eq!(json["category"], "provenance");
        assert_eq!(json["severity"], "info");
    }

    #[test]
    fn severity_orders_least_to_most_urgent() {
        assert!(Severity::Info < Severity::Low);
        assert!(Severity::Low < Severity::Medium);
        assert!(Severity::Medium < Severity::High);
        assert!(Severity::High < Severity::Critical);
    }

    const SAMPLE_REPORT: &str = "\
## WIRING (full)
- capability X is live, gated by feature flag Y
- DRIFT: capability Z claims wired but no caller found

## GATES (partial)
- pre-commit blocks on fmt
- MISSING: no CI gate for clippy

## CONFIG (none)
";

    #[test]
    fn parses_organ_headers_and_bullets_into_categorized_findings() {
        let findings = parse_organ_report(SAMPLE_REPORT);
        assert_eq!(findings.len(), 5);
        assert_eq!(findings[0].category, FindingCategory::Wiring);
        assert_eq!(findings[0].severity, Severity::Info);
        assert_eq!(findings[1].category, FindingCategory::Wiring);
        assert_eq!(findings[1].severity, Severity::High);
        assert!(findings[1].location.contains("DRIFT"));
        assert_eq!(findings[2].category, FindingCategory::Gate);
        assert_eq!(findings[3].severity, Severity::High);
    }

    #[test]
    fn zero_coverage_organ_with_no_bullets_synthesizes_a_high_finding() {
        let findings = parse_organ_report(SAMPLE_REPORT);
        let config_finding = findings
            .iter()
            .find(|f| f.category == FindingCategory::Config)
            .expect("CONFIG organ should synthesize a zero-coverage finding");
        assert_eq!(config_finding.severity, Severity::High);
        assert_eq!(
            config_finding
                .metadata
                .get("coverage_status")
                .map(String::as_str),
            Some("none")
        );
    }

    #[test]
    fn full_coverage_organ_without_markers_has_only_info_findings() {
        let raw = "## WIRING (full)\n- capability X is live and well-covered\n";
        let findings = parse_organ_report(raw);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].severity, Severity::Info);
    }

    #[test]
    fn unrecognized_section_header_is_ignored() {
        let raw = "## SOMETHING ELSE (full)\n- a bullet under an unknown organ\n";
        assert!(parse_organ_report(raw).is_empty());
    }
}
