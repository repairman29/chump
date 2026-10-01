//! INFRA-3470: comprehension->work engine — wires the shared
//! `chump-comprehension-organ::StructuredFinding` type into `chump external
//! verify-merge` (the "verifier") as an opt-in Gate 0 that can HELD a merge
//! before Gate 1/2/3 ever run.
//!
//! The comprehend binary (built from the sibling almanac repo, same
//! resolution rule as `src/comprehend_tool.rs`'s `comprehend_bin()`) prints a
//! human-readable report; `chump_comprehension_organ::parse_organ_report`
//! turns that into structured findings so this gate gets machine-checkable
//! severities instead of re-reading prose.
//!
//! Gate is **opt-in** (`CHUMP_VERIFY_COMPREHEND_GATE=1`) and **fails open**
//! when the comprehend binary isn't installed on this machine — an absent
//! organ is a coverage gap, not grounds to HELD every external_repo PR.

use chump_comprehension_organ::{parse_organ_report, Severity, StructuredFinding};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Resolve the `comprehend` binary the same way `src/comprehend_tool.rs`
/// does: `CHUMP_COMPREHEND_BIN` env override, else `~/.cargo/bin/comprehend`.
pub fn comprehend_bin() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("CHUMP_COMPREHEND_BIN") {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }
    let home = std::env::var("HOME").ok()?;
    let default = PathBuf::from(home).join(".cargo/bin/comprehend");
    default.exists().then_some(default)
}

/// `true` if the opt-in comprehend gate is armed for this run.
pub fn gate_enabled() -> bool {
    std::env::var("CHUMP_VERIFY_COMPREHEND_GATE").as_deref() == Ok("1")
}

/// Reduce a set of findings to a single HELD reason, or `None` if clean.
/// Caps the listed findings so the reason string stays short.
pub fn hold_reason(findings: &[StructuredFinding]) -> Option<String> {
    let high: Vec<&StructuredFinding> = findings
        .iter()
        .filter(|f| f.severity >= Severity::High)
        .collect();
    if high.is_empty() {
        return None;
    }
    let listed: Vec<String> = high
        .iter()
        .take(3)
        .map(|f| format!("{:?}: {}", f.category, f.location))
        .collect();
    let suffix = if high.len() > 3 {
        format!(" (+{} more)", high.len() - 3)
    } else {
        String::new()
    };
    Some(format!(
        "{} comprehend organ finding(s): {}{}",
        high.len(),
        listed.join("; "),
        suffix
    ))
}

/// Run the comprehend organs over `clone_dir` and return a HELD reason if the
/// opt-in gate is armed and the binary reports a high-severity (or above)
/// finding. Fails open (returns `Ok(None)`) when the gate is disabled or the
/// comprehend binary isn't installed on this machine.
pub fn run_gate(clone_dir: &Path) -> anyhow::Result<Option<String>> {
    if !gate_enabled() {
        return Ok(None);
    }
    let Some(bin) = comprehend_bin() else {
        return Ok(None);
    };
    let out = Command::new(&bin)
        .arg("--repo")
        .arg(clone_dir)
        .output()
        .map_err(|e| anyhow::anyhow!("running comprehend: {e}"))?;
    let raw = String::from_utf8_lossy(&out.stdout);
    let findings = parse_organ_report(&raw);
    Ok(hold_reason(&findings))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chump_comprehension_organ::FindingCategory;

    #[test]
    fn hold_reason_none_when_all_clean() {
        let findings = vec![StructuredFinding::new(
            FindingCategory::Wiring,
            "capability X is live and well-covered",
            Severity::Info,
        )];
        assert_eq!(hold_reason(&findings), None);
    }

    #[test]
    fn hold_reason_summarizes_high_findings_capped_at_three() {
        let findings = vec![
            StructuredFinding::new(FindingCategory::Wiring, "WIRING organ", Severity::High),
            StructuredFinding::new(FindingCategory::Gate, "GATES organ", Severity::High),
            StructuredFinding::new(FindingCategory::Config, "CONFIG organ", Severity::Critical),
        ];
        let reason = hold_reason(&findings).expect("3 high-severity findings should HELD");
        assert!(reason.starts_with("3 comprehend organ finding(s):"));
    }

    #[test]
    #[serial_test::serial(comprehend_gate_env)]
    fn gate_disabled_by_default_skips_even_with_findings() {
        std::env::remove_var("CHUMP_VERIFY_COMPREHEND_GATE");
        assert!(!gate_enabled());
    }

    #[test]
    #[serial_test::serial(comprehend_gate_env)]
    fn run_gate_fails_open_when_binary_absent() {
        std::env::set_var("CHUMP_VERIFY_COMPREHEND_GATE", "1");
        std::env::set_var("CHUMP_COMPREHEND_BIN", "/definitely/not/a/real/binary");
        let result = run_gate(Path::new("/tmp"));
        std::env::remove_var("CHUMP_VERIFY_COMPREHEND_GATE");
        std::env::remove_var("CHUMP_COMPREHEND_BIN");
        assert_eq!(result.unwrap(), None);
    }
}
