//! Rule: test-lag — new gap-implementing source wants test coverage in the
//! same change: a `scripts/ci/test-<gap-id>.sh` (existing or added), any
//! scripts/ci script referencing the gap ID, or `#[test]` coverage in the
//! diff itself.
//!
//! Ported from scripts/git-hooks/pre-commit block 3c (META-032). The original
//! fired when a docs/gaps YAML mirror flipped to status:done with
//! test-checkable ACs and no scripts/ci reference; the YAML mirrors are being
//! retired (ZERO-WASTE-020), so the ported rule anchors on the observable
//! event that still exists in the diff: brand-new source files implementing
//! the claimed gap. Coverage signals are parsed (file adds, attribute lines),
//! not raw-line grep.

use super::{Evaluation, Rule};
use crate::verify::{ChangeKind, VerifyContext};

pub struct TestLag;

const RULE_ID: &str = "test-lag";

const RECEIPT: &str = "META-032: gaps were closed status:done with test-checkable acceptance criteria while no scripts/ci test referenced the gap ID — green != covered (shop rule 8: every coverage claim names its depth)";

impl Rule for TestLag {
    fn id(&self) -> &'static str {
        RULE_ID
    }

    fn incident_receipt(&self) -> &'static str {
        RECEIPT
    }

    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation {
        let new_src: Vec<&str> = ctx
            .files
            .iter()
            .filter(|f| {
                f.kind == ChangeKind::Added
                    && f.path.ends_with(".rs")
                    && (f.path.starts_with("src/") || f.path.starts_with("crates/"))
            })
            .map(|f| f.path.as_str())
            .collect();

        if new_src.is_empty() {
            return Evaluation::NotApplicable("no new src/ or crates/ .rs files".to_string());
        }

        let Some(gap_id) = ctx.gap_id.as_deref() else {
            return Evaluation::NotApplicable(
                "gap id not resolvable (message/branch/CHUMP_GAP_ID)".to_string(),
            );
        };

        let script_rel = format!(
            "scripts/ci/test-{}.sh",
            gap_id.to_ascii_lowercase().replace('_', "-")
        );

        // Signal 1: the per-gap CI script is added in this diff or already on disk.
        let script_in_diff = ctx
            .files
            .iter()
            .any(|f| f.path == script_rel && f.kind != ChangeKind::Deleted);
        if script_in_diff || ctx.repo_root.join(&script_rel).is_file() {
            return Evaluation::Pass(format!("{script_rel} covers {gap_id}"));
        }

        // Signal 2: any existing scripts/ci/*.sh references the gap ID.
        if scripts_ci_mentions_gap(ctx, gap_id) {
            return Evaluation::Pass(format!("existing scripts/ci script references {gap_id}"));
        }

        // Signal 3: the diff itself adds Rust test coverage.
        let has_rust_tests = ctx
            .files
            .iter()
            .filter(|f| f.path.ends_with(".rs"))
            .flat_map(|f| f.added_lines.iter())
            .map(|l| l.trim_start())
            .any(|l| {
                l.starts_with("#[test]")
                    || l.starts_with("#[tokio::test")
                    || l.starts_with("#[cfg(test)]")
            });
        if has_rust_tests {
            return Evaluation::Pass("diff adds #[test] coverage alongside new source".to_string());
        }

        Evaluation::Fail {
            detail: format!(
                "new gap-implementing source with no test-coverage signal for {gap_id}: {}",
                new_src.join(", ")
            ),
            remediation: format!(
                "create {script_rel} referencing {gap_id}, or add #[test] coverage in the same commit"
            ),
        }
    }
}

/// Content scan over scripts/ci/*.sh for the gap ID (mirrors the original
/// META-032 lookup: filename match OR content match).
fn scripts_ci_mentions_gap(ctx: &VerifyContext, gap_id: &str) -> bool {
    let dir = ctx.repo_root.join("scripts/ci");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return false;
    };
    let gap_lower = gap_id.to_ascii_lowercase().replace('_', "-");
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.ends_with(".sh") {
            continue;
        }
        if name.to_ascii_lowercase().contains(&gap_lower) {
            return true;
        }
        if let Ok(body) = std::fs::read_to_string(entry.path()) {
            if body.contains(gap_id) {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::{test_context, DiffFile, Stage};
    use std::path::Path;

    fn file(path: &str, kind: ChangeKind, added: &[&str]) -> DiffFile {
        DiffFile {
            path: path.to_string(),
            kind,
            added_lines: added.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn eval_at(root: &Path, files: Vec<DiffFile>, gap: Option<&str>) -> Evaluation {
        let ctx = test_context(Stage::CommitMsg, root, files, Some("msg"), gap);
        TestLag.evaluate(&ctx)
    }

    fn eval(files: Vec<DiffFile>, gap: Option<&str>) -> Evaluation {
        // Nonexistent root: no scripts/ci directory on disk.
        eval_at(Path::new("/nonexistent-chump-fixture"), files, gap)
    }

    #[test]
    fn not_applicable_without_new_source() {
        assert!(matches!(
            eval(
                vec![file("src/existing.rs", ChangeKind::Modified, &["let a=1;"])],
                Some("META-999")
            ),
            Evaluation::NotApplicable(_)
        ));
    }

    #[test]
    fn not_applicable_without_gap_id() {
        assert!(matches!(
            eval(vec![file("src/new_thing.rs", ChangeKind::Added, &[])], None),
            Evaluation::NotApplicable(_)
        ));
    }

    #[test]
    fn fails_on_new_source_without_coverage() {
        let ev = eval(
            vec![file(
                "src/new_thing.rs",
                ChangeKind::Added,
                &["pub fn f() {}"],
            )],
            Some("META-999"),
        );
        match ev {
            Evaluation::Fail { remediation, .. } => {
                assert!(
                    remediation.contains("scripts/ci/test-meta-999.sh"),
                    "{remediation}"
                );
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn passes_when_ci_script_added_in_same_diff() {
        let ev = eval(
            vec![
                file("src/new_thing.rs", ChangeKind::Added, &[]),
                file("scripts/ci/test-meta-999.sh", ChangeKind::Added, &[]),
            ],
            Some("META-999"),
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn passes_when_diff_adds_rust_tests() {
        let ev = eval(
            vec![file(
                "src/new_thing.rs",
                ChangeKind::Added,
                &["pub fn f() {}", "#[cfg(test)]", "mod tests {", "#[test]"],
            )],
            Some("META-999"),
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn passes_when_ci_script_exists_on_disk() {
        let tmp = std::env::temp_dir().join(format!("verify-test-lag-{}", std::process::id()));
        let ci = tmp.join("scripts/ci");
        std::fs::create_dir_all(&ci).unwrap();
        std::fs::write(ci.join("test-meta-998.sh"), "# covers META-998\n").unwrap();
        let ev = eval_at(
            &tmp,
            vec![file("src/new_thing.rs", ChangeKind::Added, &[])],
            Some("META-998"),
        );
        std::fs::remove_dir_all(&tmp).ok();
        assert!(matches!(ev, Evaluation::Pass(_)));
    }
}
