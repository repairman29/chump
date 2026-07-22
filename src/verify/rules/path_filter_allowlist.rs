//! Rule: path-filter-allowlist — files added under a top-level directory (or
//! key top-level file) that is missing from the `code:` paths-filter
//! allowlist in .github/workflows/ci.yml fail verification, naming the exact
//! `- 'dir/**'` line to add.
//!
//! Ported from scripts/ci/check-path-filter-coverage.sh (INFRA-682). The
//! legacy script sweeps every top-level directory of the checkout on each CI
//! run; the ported rule is diff-scoped — it fires only on the change that
//! INTRODUCES paths under an uncovered top level, which is the moment the
//! author can still fix ci.yml in the same commit. The repo-wide CI sweep
//! stays in place (parallel-run).
//!
//! Parsed semantics: the `code:` patterns are extracted from the
//! `filters: |` block of ci.yml with the same anchoring the legacy awk used
//! (skipping the job `outputs:` section that shares key names), and coverage
//! is a first-path-segment comparison, not a substring grep.

use super::{Evaluation, Rule};
use crate::verify::{ChangeKind, VerifyContext};
use std::collections::BTreeSet;

pub struct PathFilterAllowlist;

const RULE_ID: &str = "path-filter-allowlist";

const RECEIPT: &str = "INFRA-272/INFRA-682: a PR whose sole diff touches a path outside the ci.yml code: paths-filter allowlist has ALL required CI checks skipped — branch protection counts skipped != passing and blocks the merge permanently; the failure mode is silent until someone stares at a wedged PR";

/// Key top-level files the legacy check covered (can be the sole diff of a
/// real PR).
const KEY_TOP_FILES: &[&str] = &["Cargo.toml", "Cargo.lock", ".release-plz.toml"];

impl Rule for PathFilterAllowlist {
    fn id(&self) -> &'static str {
        RULE_ID
    }

    fn incident_receipt(&self) -> &'static str {
        RECEIPT
    }

    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation {
        // Coverage names introduced by this diff.
        let mut names: BTreeSet<String> = BTreeSet::new();
        for f in &ctx.files {
            if f.kind == ChangeKind::Deleted {
                continue;
            }
            match f.path.split_once('/') {
                Some((top, _)) => {
                    if top.starts_with('.') {
                        // Hidden top levels are out of scope except the one
                        // that changes solo in real PRs: .github/workflows.
                        if f.path.starts_with(".github/workflows/") {
                            names.insert(".github/workflows".to_string());
                        }
                    } else {
                        names.insert(top.to_string());
                    }
                }
                None => {
                    // Top-level file: only the key files the legacy check
                    // covered are in scope.
                    if KEY_TOP_FILES.contains(&f.path.as_str()) {
                        names.insert(f.path.clone());
                    }
                }
            }
        }

        if names.is_empty() {
            return Evaluation::NotApplicable("no in-scope top-level paths in diff".to_string());
        }

        let ci_yml = ctx.repo_root.join(".github/workflows/ci.yml");
        let Ok(body) = std::fs::read_to_string(&ci_yml) else {
            return Evaluation::NotApplicable(
                "no .github/workflows/ci.yml in this repo — paths-filter coverage does not apply"
                    .to_string(),
            );
        };

        let patterns = extract_code_patterns(&body);
        if patterns.is_empty() {
            return Evaluation::NotApplicable("ci.yml has no code: paths-filter block".to_string());
        }

        let missing: Vec<&String> = names.iter().filter(|n| !is_covered(n, &patterns)).collect();
        if missing.is_empty() {
            return Evaluation::Pass(format!(
                "all {} top-level path(s) in diff covered by code: allowlist",
                names.len()
            ));
        }

        let lines: Vec<String> = missing
            .iter()
            .map(|m| {
                if m.contains('.') && !m.contains('/') {
                    // Key top-level file — exact entry, no glob.
                    format!("- '{m}'")
                } else {
                    format!("- '{m}/**'")
                }
            })
            .collect();
        Evaluation::Fail {
            detail: format!(
                "diff touches top-level path(s) missing from the ci.yml code: paths-filter allowlist: {}",
                missing
                    .iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            remediation: format!(
                "add to the code: section of the filters: | block in .github/workflows/ci.yml: {}",
                lines.join(" and ")
            ),
        }
    }
}

/// Extract the `code:` patterns from the `filters: |` block — same anchoring
/// as the legacy awk (skips the job outputs: section with identical keys).
fn extract_code_patterns(ci_yml: &str) -> Vec<String> {
    let mut in_filters = false;
    let mut in_code = false;
    let mut out = Vec::new();
    for line in ci_yml.lines() {
        if line.contains("filters: |") {
            in_filters = true;
            in_code = false;
            continue;
        }
        if !in_filters {
            continue;
        }
        let t = line.trim();
        if !in_code {
            if t == "code:" {
                in_code = true;
            }
            continue;
        }
        if let Some(rest) = t.strip_prefix("- ") {
            out.push(rest.trim().trim_matches('\'').trim_matches('"').to_string());
            continue;
        }
        // Comments and blank lines inside the list are fine (the real
        // ci.yml documents the allowlist inline); anything else — the next
        // filter key like `e2e:` — ends the code: section. Same effective
        // semantics as the legacy awk, which matched only `- ` entries and
        // exited on `^\s+[a-z]`.
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        break;
    }
    out
}

/// A name is covered when a pattern's first path segment equals it, when the
/// pattern extends it (`.github/workflows/**` covers `.github/workflows`), or
/// when a pattern names the exact file (`Cargo.toml`).
fn is_covered(name: &str, patterns: &[String]) -> bool {
    patterns.iter().any(|p| {
        p == name || p.starts_with(&format!("{name}/")) || p.trim_end_matches("/**") == name
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::{test_context, DiffFile, Stage};

    // Mirrors the real ci.yml shape, including inline comments inside the
    // code: list (the regression that hid the block from the first parser).
    const CI_YML: &str = "jobs:\n  changes:\n    outputs:\n      code: x\n    steps:\n      - uses: dorny/paths-filter@v4\n        with:\n          filters: |\n            code:\n              # INFRA-272: this is an ALLOWLIST.\n              - 'src/**'\n\n              - 'scripts/**'\n              - '.github/workflows/**'\n              - 'Cargo.toml'\n            e2e:\n              - 'src/**'\n";

    fn fixture_root(with_ci_yml: bool) -> std::path::PathBuf {
        let tmp = std::env::temp_dir().join(format!(
            "verify-path-filter-{}-{with_ci_yml}",
            std::process::id()
        ));
        let wf = tmp.join(".github/workflows");
        std::fs::create_dir_all(&wf).unwrap();
        if with_ci_yml {
            std::fs::write(wf.join("ci.yml"), CI_YML).unwrap();
        } else {
            let _ = std::fs::remove_file(wf.join("ci.yml"));
        }
        tmp
    }

    fn file(path: &str, kind: ChangeKind) -> DiffFile {
        DiffFile {
            path: path.to_string(),
            kind,
            added_lines: Vec::new(),
        }
    }

    fn eval_with(root: &std::path::Path, files: Vec<DiffFile>) -> Evaluation {
        let ctx = test_context(Stage::CommitMsg, root, files, Some("msg"), None);
        PathFilterAllowlist.evaluate(&ctx)
    }

    #[test]
    fn covered_dirs_pass() {
        let root = fixture_root(true);
        let ev = eval_with(
            &root,
            vec![
                file("src/lib.rs", ChangeKind::Modified),
                file("scripts/ci/x.sh", ChangeKind::Added),
                file(".github/workflows/audit.yml", ChangeKind::Modified),
                file("Cargo.toml", ChangeKind::Modified),
            ],
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn uncovered_new_dir_fails_and_names_exact_line() {
        let root = fixture_root(true);
        let ev = eval_with(
            &root,
            vec![file("new-feature-dir/main.rs", ChangeKind::Added)],
        );
        match ev {
            Evaluation::Fail {
                detail,
                remediation,
            } => {
                assert!(detail.contains("new-feature-dir"), "{detail}");
                assert!(
                    remediation.contains("- 'new-feature-dir/**'"),
                    "{remediation}"
                );
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn key_top_file_uncovered_fails_without_glob() {
        let root = std::env::temp_dir().join(format!("verify-pf-keyfile-{}", std::process::id()));
        let wf = root.join(".github/workflows");
        std::fs::create_dir_all(&wf).unwrap();
        // code: block missing Cargo.lock
        std::fs::write(wf.join("ci.yml"), CI_YML).unwrap();
        let ev = eval_with(&root, vec![file("Cargo.lock", ChangeKind::Modified)]);
        match ev {
            Evaluation::Fail { remediation, .. } => {
                assert!(remediation.contains("- 'Cargo.lock'"), "{remediation}");
                assert!(!remediation.contains("Cargo.lock/**"), "{remediation}");
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn hidden_dirs_and_plain_top_files_out_of_scope() {
        let root = fixture_root(true);
        let ev = eval_with(
            &root,
            vec![
                file(".claude/agents/x.md", ChangeKind::Added),
                file("README.md", ChangeKind::Modified),
            ],
        );
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn deleted_files_do_not_count() {
        let root = fixture_root(true);
        let ev = eval_with(&root, vec![file("old-dir/x.rs", ChangeKind::Deleted)]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn missing_ci_yml_is_not_applicable() {
        let root = fixture_root(false);
        let ev = eval_with(&root, vec![file("anything/x.rs", ChangeKind::Added)]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn code_pattern_extraction_skips_outputs_section() {
        let pats = extract_code_patterns(CI_YML);
        assert_eq!(
            pats,
            vec!["src/**", "scripts/**", ".github/workflows/**", "Cargo.toml"]
        );
    }
}
