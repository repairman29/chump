//! Rule: install-manifest — every NEW scripts/setup/install-*.sh must be
//! mapped in exactly one of the three installer manifests:
//!   (1) REQUIRED_DAEMONS in scripts/setup/chump-fleet-bootstrap.sh
//!   (2) scripts/setup/optional-installers-allowlist.txt
//!   (3) scripts/setup/deprecated-installers-allowlist.txt
//!
//! Ported from scripts/ci/test-install-script-manifest.sh (INFRA-1810). The
//! legacy gate audits every installer in the tree on each CI run; the ported
//! rule is diff-scoped — it fires on the change that ADDS the installer,
//! when the author can still map it in the same commit. The repo-wide CI
//! audit stays in place (parallel-run).
//!
//! The manifests are read from the repo root at evaluation time, so mapping
//! the installer in the same commit satisfies the rule (the working tree
//! already contains the manifest edit when the hook runs).

use super::{Evaluation, Rule};
use crate::verify::{ChangeKind, VerifyContext};
use std::collections::BTreeSet;

pub struct InstallManifest;

const RULE_ID: &str = "install-manifest";

const RECEIPT: &str = "INFRA-1810: installers accumulated in scripts/setup/ with no record of whether the fleet bootstrap needs them, they are situational, or they are scheduled for removal — unmapped installers become shelf-ware daemons nobody installs or dead code nobody dares delete";

impl Rule for InstallManifest {
    fn id(&self) -> &'static str {
        RULE_ID
    }

    fn incident_receipt(&self) -> &'static str {
        RECEIPT
    }

    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation {
        let new_installers: Vec<String> = ctx
            .files
            .iter()
            .filter(|f| {
                f.kind == ChangeKind::Added
                    && f.path.starts_with("scripts/setup/install-")
                    && f.path.ends_with(".sh")
                    && f.path.matches('/').count() == 2
            })
            .filter_map(|f| f.path.rsplit('/').next().map(str::to_string))
            .collect();

        if new_installers.is_empty() {
            return Evaluation::NotApplicable(
                "no new scripts/setup/install-*.sh in diff".to_string(),
            );
        }

        let bootstrap =
            std::fs::read_to_string(ctx.repo_root.join("scripts/setup/chump-fleet-bootstrap.sh"))
                .unwrap_or_default();
        let optional = load_allowlist(ctx, "scripts/setup/optional-installers-allowlist.txt");
        let deprecated = load_allowlist(ctx, "scripts/setup/deprecated-installers-allowlist.txt");

        let mut unmapped = Vec::new();
        let mut mapped_deprecated = Vec::new();
        for name in &new_installers {
            if bootstrap.contains(name.as_str()) || optional.contains(name) {
                continue;
            }
            if deprecated.contains(name) {
                // Odd (a brand-new installer already scheduled for removal)
                // but mapped — the legacy gate warns and passes; keep parity.
                mapped_deprecated.push(name.clone());
                continue;
            }
            unmapped.push(name.clone());
        }

        if unmapped.is_empty() {
            let mut msg = format!("{} new installer(s) mapped", new_installers.len());
            if !mapped_deprecated.is_empty() {
                msg.push_str(&format!(
                    " (note: {} mapped as deprecated at birth: {})",
                    mapped_deprecated.len(),
                    mapped_deprecated.join(", ")
                ));
            }
            return Evaluation::Pass(msg);
        }

        Evaluation::Fail {
            detail: format!("unmapped new installer(s): {}", unmapped.join(", ")),
            remediation: format!(
                "map each installer — pick ONE per script: (A) add \"com.chump.<label>|scripts/setup/{first}\" to REQUIRED_DAEMONS in scripts/setup/chump-fleet-bootstrap.sh, (B) add '{first}' to scripts/setup/optional-installers-allowlist.txt (situational/opt-in), or (C) add '{first}' to scripts/setup/deprecated-installers-allowlist.txt (about to be removed)",
                first = unmapped[0]
            ),
        }
    }
}

fn load_allowlist(ctx: &VerifyContext, rel: &str) -> BTreeSet<String> {
    let Ok(body) = std::fs::read_to_string(ctx.repo_root.join(rel)) else {
        return BTreeSet::new();
    };
    body.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_whitespace().next().map(str::to_string))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::{test_context, DiffFile, Stage};
    use std::path::{Path, PathBuf};

    fn file(path: &str, kind: ChangeKind) -> DiffFile {
        DiffFile {
            path: path.to_string(),
            kind,
            added_lines: Vec::new(),
        }
    }

    fn fixture_root(tag: &str, required: &str, optional: &str, deprecated: &str) -> PathBuf {
        let tmp = std::env::temp_dir().join(format!(
            "verify-install-manifest-{tag}-{}",
            std::process::id()
        ));
        let setup = tmp.join("scripts/setup");
        std::fs::create_dir_all(&setup).unwrap();
        std::fs::write(
            setup.join("chump-fleet-bootstrap.sh"),
            format!("REQUIRED_DAEMONS=(\n  \"com.chump.x|scripts/setup/{required}\"\n)\n"),
        )
        .unwrap();
        std::fs::write(
            setup.join("optional-installers-allowlist.txt"),
            format!("# optional\n{optional}\n"),
        )
        .unwrap();
        std::fs::write(
            setup.join("deprecated-installers-allowlist.txt"),
            format!("# deprecated\n{deprecated}\n"),
        )
        .unwrap();
        tmp
    }

    fn eval_with(root: &Path, files: Vec<DiffFile>) -> Evaluation {
        let ctx = test_context(Stage::CommitMsg, root, files, Some("msg"), None);
        InstallManifest.evaluate(&ctx)
    }

    #[test]
    fn not_applicable_without_new_installers() {
        let ev = eval_with(
            Path::new("/nonexistent-chump-fixture"),
            vec![
                file("scripts/setup/install-existing.sh", ChangeKind::Modified),
                file("scripts/setup/helper.sh", ChangeKind::Added),
                file("scripts/setup/install-nested/x.sh", ChangeKind::Added),
            ],
        );
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn unmapped_new_installer_fails_with_three_options() {
        let root = fixture_root("unmapped", "install-a.sh", "install-b.sh", "install-c.sh");
        let ev = eval_with(
            &root,
            vec![file(
                "scripts/setup/install-new-thing.sh",
                ChangeKind::Added,
            )],
        );
        match ev {
            Evaluation::Fail {
                detail,
                remediation,
            } => {
                assert!(detail.contains("install-new-thing.sh"), "{detail}");
                assert!(remediation.contains("REQUIRED_DAEMONS"), "{remediation}");
                assert!(
                    remediation.contains("optional-installers-allowlist.txt"),
                    "{remediation}"
                );
                assert!(
                    remediation.contains("deprecated-installers-allowlist.txt"),
                    "{remediation}"
                );
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn required_mapping_passes() {
        let root = fixture_root("required", "install-new-thing.sh", "install-b.sh", "");
        let ev = eval_with(
            &root,
            vec![file(
                "scripts/setup/install-new-thing.sh",
                ChangeKind::Added,
            )],
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn optional_mapping_passes() {
        let root = fixture_root("optional", "install-a.sh", "install-new-thing.sh", "");
        let ev = eval_with(
            &root,
            vec![file(
                "scripts/setup/install-new-thing.sh",
                ChangeKind::Added,
            )],
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn deprecated_mapping_passes_with_note() {
        let root = fixture_root("deprecated", "install-a.sh", "", "install-new-thing.sh");
        let ev = eval_with(
            &root,
            vec![file(
                "scripts/setup/install-new-thing.sh",
                ChangeKind::Added,
            )],
        );
        match ev {
            Evaluation::Pass(msg) => assert!(msg.contains("deprecated at birth"), "{msg}"),
            _ => panic!("expected pass"),
        }
    }

    #[test]
    fn missing_manifests_fail_unmapped() {
        // Fixture repo without any manifest files: a new installer cannot be
        // mapped anywhere -> fail (matches the legacy gate's hard-fail on
        // missing allowlist files).
        let ev = eval_with(
            Path::new("/nonexistent-chump-fixture"),
            vec![file("scripts/setup/install-orphan.sh", ChangeKind::Added)],
        );
        assert!(matches!(ev, Evaluation::Fail { .. }));
    }
}
