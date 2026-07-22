//! Rule: pipefail-race — forbid new `printf ... | grep -q` pipelines in
//! hot-path script directories (scripts/coord/, scripts/git-hooks/,
//! scripts/dispatch/).
//!
//! Ported from scripts/ci/test-pipefail-race-sweep.sh (INFRA-1658). The
//! legacy sweep greps the whole tree on every CI run; the ported rule is
//! diff-scoped (added lines only) so authors get the verdict at commit time
//! with the same allowlist marker semantics. The repo-wide CI sweep stays in
//! place (parallel-run) to catch bypassed history.
//!
//! THE BUG: under `set -o pipefail`, `printf 'X' | grep -q Y` is racy —
//! grep -q closes stdin on first match, printf gets SIGPIPE, the pipeline
//! exits non-zero EVEN WHEN the pattern matched. Silent false-negatives in
//! conditional branches.
//!
//! Parsed semantics: the scan tokenizes each added line looking for a
//! `printf` word, a single following pipe, and a `grep` word in the segment
//! directly after that pipe whose next flag cluster contains `q` — the same
//! shape the legacy regex (`printf[^|]*\|[^|]*grep\s+-[a-zA-Z]*q`) matched.
//! Comment-only lines and lines carrying the `# pipefail-sweep-allowed`
//! marker are exempt, exactly like the legacy sweep.

use super::{Evaluation, Rule};
use crate::verify::{ChangeKind, VerifyContext};

pub struct PipefailRace;

const RULE_ID: &str = "pipefail-race";

const RECEIPT: &str = "INFRA-1658: under set -o pipefail, printf|grep -q races — grep -q closes stdin on first match, printf gets SIGPIPE, the whole pipeline exits non-zero even when the pattern matched; cost 6 hours debugging the INFRA-755 pre-commit-obs-budget false-negative chain before the race was located";

const HOT_DIRS: &[&str] = &["scripts/coord/", "scripts/git-hooks/", "scripts/dispatch/"];

const ALLOW_MARKER: &str = "# pipefail-sweep-allowed";

impl Rule for PipefailRace {
    fn id(&self) -> &'static str {
        RULE_ID
    }

    fn incident_receipt(&self) -> &'static str {
        RECEIPT
    }

    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation {
        let mut violations: Vec<String> = Vec::new();

        for f in &ctx.files {
            if f.kind == ChangeKind::Deleted {
                continue;
            }
            if !HOT_DIRS.iter().any(|d| f.path.starts_with(d)) {
                continue;
            }
            for line in &f.added_lines {
                let t = line.trim_start();
                if t.starts_with('#') || line.contains(ALLOW_MARKER) {
                    continue;
                }
                if has_printf_grep_q_pipe(line) {
                    violations.push(format!("{}: {}", f.path, t));
                }
            }
        }

        if violations.is_empty() {
            return Evaluation::NotApplicable(
                "no new printf|grep -q pipelines in hot-path scripts".to_string(),
            );
        }

        Evaluation::Fail {
            detail: format!(
                "pipefail-race-prone printf|grep -q added in hot-path script(s): {}",
                violations.join(" ; ")
            ),
            remediation: "materialize the producer to a tempfile (_t=$(mktemp); printf '%s\\n' \"$BLOB\" > \"$_t\"; grep -qE 'pattern' \"$_t\"; rm -f \"$_t\") or use a herestring (grep -qE 'pattern' <<< \"$BLOB\"); if the script does not set pipefail, append the marker '# pipefail-sweep-allowed' to the line. See docs/process/CLAUDE_GOTCHAS.md -> 'printf | grep -q pipefail race'".to_string(),
        }
    }
}

/// True when the line contains `printf`, then one pipe, then `grep` in the
/// segment DIRECTLY after that pipe, with a following flag cluster containing
/// `q` (e.g. `-q`, `-qE`, `-Fxq`).
fn has_printf_grep_q_pipe(line: &str) -> bool {
    let mut search_from = 0usize;
    while let Some(rel) = line[search_from..].find("printf") {
        let pf = search_from + rel;
        // Word boundary on the left.
        let left_ok = pf == 0
            || !line.as_bytes()[pf - 1].is_ascii_alphanumeric() && line.as_bytes()[pf - 1] != b'_';
        search_from = pf + "printf".len();
        if !left_ok {
            continue;
        }
        let after_printf = &line[pf + "printf".len()..];
        // Segment between printf and its FIRST pipe must not contain grep's
        // pipe — the legacy regex requires grep in the segment right after
        // the first pipe following printf.
        let Some(pipe_pos) = after_printf.find('|') else {
            continue;
        };
        let after_pipe = &after_printf[pipe_pos + 1..];
        // `||` is a logical-or, not a pipe.
        if after_pipe.starts_with('|') {
            continue;
        }
        let segment = after_pipe.split('|').next().unwrap_or("");
        if segment_has_grep_q(segment) {
            return true;
        }
    }
    false
}

/// True when the segment contains a `grep` word followed by a `-...q...`
/// flag cluster (possibly with other flags between, e.g. `grep -i -qE`).
fn segment_has_grep_q(segment: &str) -> bool {
    let mut tokens = segment.split_whitespace().peekable();
    while let Some(tok) = tokens.next() {
        // Match bare `grep` or a path suffix like /usr/bin/grep.
        let is_grep = tok == "grep" || tok.ends_with("/grep");
        if !is_grep {
            continue;
        }
        for flag in tokens.by_ref() {
            if !flag.starts_with('-') {
                break; // first non-flag token = pattern; -q must precede it
            }
            if flag == "--" {
                break;
            }
            if !flag.starts_with("--") && flag.contains('q') {
                return true;
            }
            if flag == "--quiet" || flag == "--silent" {
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

    fn file(path: &str, added: &[&str]) -> DiffFile {
        DiffFile {
            path: path.to_string(),
            kind: ChangeKind::Modified,
            added_lines: added.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn eval(files: Vec<DiffFile>) -> Evaluation {
        let ctx = test_context(
            Stage::CommitMsg,
            Path::new("/nonexistent-chump-fixture"),
            files,
            Some("msg"),
            None,
        );
        PipefailRace.evaluate(&ctx)
    }

    #[test]
    fn flags_printf_grep_q_in_hot_dir() {
        let ev = eval(vec![file(
            "scripts/coord/foo.sh",
            &[r#"if printf '%s\n' "$x" | grep -q needle; then"#],
        )]);
        match ev {
            Evaluation::Fail { detail, .. } => {
                assert!(detail.contains("scripts/coord/foo.sh"), "{detail}");
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn flags_combined_flag_clusters() {
        for flags in ["-qE", "-Fxq", "-i -q"] {
            let line = format!("printf '%s' \"$v\" | grep {flags} pat");
            let ev = eval(vec![file("scripts/dispatch/bar.sh", &[line.as_str()])]);
            assert!(
                matches!(ev, Evaluation::Fail { .. }),
                "expected fail for grep {flags}"
            );
        }
    }

    #[test]
    fn allowlist_marker_exempts_line() {
        let ev = eval(vec![file(
            "scripts/git-hooks/baz.sh",
            &[r#"if printf '%s\n' "$x" | grep -q y; then  # pipefail-sweep-allowed"#],
        )]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn comment_lines_are_exempt() {
        let ev = eval(vec![file(
            "scripts/coord/foo.sh",
            &["# example of the bug: printf x | grep -q y"],
        )]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn non_hot_dirs_are_out_of_scope() {
        let ev = eval(vec![file(
            "scripts/ci/fixture.sh",
            &["printf x | grep -q y"],
        )]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn grep_without_q_is_fine() {
        let ev = eval(vec![file(
            "scripts/coord/foo.sh",
            &[
                "printf '%s' \"$v\" | grep -c pat",
                "printf '%s' \"$v\" | grep pat",
            ],
        )]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn grep_q_must_be_in_segment_after_first_pipe() {
        // printf | sed | grep -q — grep is NOT in the segment directly after
        // printf's pipe; the legacy regex did not match this shape either.
        let ev = eval(vec![file(
            "scripts/coord/foo.sh",
            &["printf '%s' \"$v\" | sed 's/a/b/' | grep -q pat"],
        )]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn logical_or_is_not_a_pipe() {
        let ev = eval(vec![file(
            "scripts/coord/foo.sh",
            &["printf done || grep -q marker file"],
        )]);
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }
}
