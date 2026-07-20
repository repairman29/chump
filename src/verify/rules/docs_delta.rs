//! Rule: docs-delta — net-new docs/*.md require an explicit
//! `Net-new-docs: +N` commit trailer (or a comparable deletion).
//!
//! Ported from scripts/git-hooks/commit-msg (binding) and the advisory notice
//! in scripts/git-hooks/pre-commit block 7. Semantics preserved exactly:
//! count = files ADDED under docs/ ending .md minus files DELETED there;
//! trailer must be present and must equal or exceed the computed net
//! (INFRA-124 rule). Parsed values, not raw-line grep: the trailer number is
//! extracted and compared numerically.

use super::{Evaluation, Rule};
use crate::verify::{ChangeKind, VerifyContext};

pub struct DocsDelta;

const RULE_ID: &str = "docs-delta";

const RECEIPT: &str = "INFRA-009/INFRA-124/INFRA-1969 (Red Letter #3): docs/ grew 66 -> 119 -> 139 files across three review cycles with zero deletions; the original pre-commit-stage trailer check could never see the message, always blocked, and forced blanket env bypasses that destroyed the audit signal";

impl Rule for DocsDelta {
    fn id(&self) -> &'static str {
        RULE_ID
    }

    fn incident_receipt(&self) -> &'static str {
        RECEIPT
    }

    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation {
        let is_docs_md = |p: &str| p.starts_with("docs/") && p.ends_with(".md");
        let added = ctx
            .files
            .iter()
            .filter(|f| f.kind == ChangeKind::Added && is_docs_md(&f.path))
            .count();
        let deleted = ctx
            .files
            .iter()
            .filter(|f| f.kind == ChangeKind::Deleted && is_docs_md(&f.path))
            .count();

        if added == 0 || added <= deleted {
            return Evaluation::NotApplicable("no net-new docs/*.md in diff".to_string());
        }
        let net = added - deleted;
        let remediation = format!(
            "add commit trailer 'Net-new-docs: +{net}' (intentional declaration), or delete/archive a comparable doc in the same commit"
        );

        let Some(message) = ctx.commit_message.as_deref() else {
            // Pre-commit preview: the message does not exist yet. Report the
            // pending requirement; the commit-msg stage enforces it.
            return Evaluation::Fail {
                detail: format!(
                    "commit adds {added} docs/*.md, deletes {deleted} (net +{net}); trailer check pending — message not available at this stage"
                ),
                remediation,
            };
        };

        match parse_net_new_docs_trailer(message) {
            None => Evaluation::Fail {
                detail: format!(
                    "commit adds {added} docs/*.md, deletes {deleted} (net +{net}) with no Net-new-docs trailer"
                ),
                remediation,
            },
            Some(v) if v < net => Evaluation::Fail {
                detail: format!(
                    "trailer claims Net-new-docs: +{v} but commit adds {added}, deletes {deleted} (net +{net}); trailer must equal or exceed the computed delta"
                ),
                remediation,
            },
            Some(_) => Evaluation::Pass(format!("net +{net} docs declared by trailer")),
        }
    }
}

/// Parse the first `Net-new-docs: +N` trailer (case-insensitive, '+' optional).
fn parse_net_new_docs_trailer(message: &str) -> Option<usize> {
    for line in message.lines() {
        let lower = line.trim_start().to_ascii_lowercase();
        let Some(rest) = lower.strip_prefix("net-new-docs:") else {
            continue;
        };
        let rest = rest.trim_start();
        let rest = rest.strip_prefix('+').unwrap_or(rest);
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(v) = digits.parse::<usize>() {
            return Some(v);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::{test_context, DiffFile, Stage};
    use std::path::Path;

    fn file(path: &str, kind: ChangeKind) -> DiffFile {
        DiffFile {
            path: path.to_string(),
            kind,
            added_lines: Vec::new(),
        }
    }

    fn eval(files: Vec<DiffFile>, msg: Option<&str>) -> Evaluation {
        let ctx = test_context(
            Stage::CommitMsg,
            Path::new("/nonexistent"),
            files,
            msg,
            None,
        );
        DocsDelta.evaluate(&ctx)
    }

    #[test]
    fn not_applicable_without_net_new_docs() {
        assert!(matches!(
            eval(vec![file("src/a.rs", ChangeKind::Added)], Some("m")),
            Evaluation::NotApplicable(_)
        ));
        // add 1 delete 1 -> net zero -> inapplicable
        assert!(matches!(
            eval(
                vec![
                    file("docs/a.md", ChangeKind::Added),
                    file("docs/b.md", ChangeKind::Deleted)
                ],
                Some("m")
            ),
            Evaluation::NotApplicable(_)
        ));
    }

    #[test]
    fn fails_without_trailer() {
        let ev = eval(
            vec![file("docs/new.md", ChangeKind::Added)],
            Some("msg body"),
        );
        match ev {
            Evaluation::Fail { remediation, .. } => {
                assert!(remediation.contains("Net-new-docs: +1"), "{remediation}");
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn fails_when_trailer_understates() {
        let ev = eval(
            vec![
                file("docs/a.md", ChangeKind::Added),
                file("docs/b.md", ChangeKind::Added),
            ],
            Some("msg\n\nNet-new-docs: +1\n"),
        );
        match ev {
            Evaluation::Fail { detail, .. } => assert!(detail.contains("net +2"), "{detail}"),
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn passes_with_adequate_trailer_case_insensitive() {
        let ev = eval(
            vec![file("docs/process/new.md", ChangeKind::Added)],
            Some("msg\n\nnet-new-docs: 1\n"),
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn preview_stage_reports_pending_fail_without_message() {
        let ctx = test_context(
            Stage::PreCommit,
            Path::new("/nonexistent"),
            vec![file("docs/new.md", ChangeKind::Added)],
            None,
            None,
        );
        match DocsDelta.evaluate(&ctx) {
            Evaluation::Fail { detail, .. } => {
                assert!(detail.contains("pending"), "{detail}");
            }
            _ => panic!("expected pending fail at preview stage"),
        }
    }

    #[test]
    fn modified_docs_do_not_count() {
        assert!(matches!(
            eval(
                vec![file("docs/existing.md", ChangeKind::Modified)],
                Some("m")
            ),
            Evaluation::NotApplicable(_)
        ));
    }
}
