//! Rule: no-new-bypass-env-vars — forbid introducing new bypass-class env
//! vars (CHUMP_*_ with a bypass/skip suffix, or the CHUMP ignore-prefix
//! family) unless allowlisted in scripts/ci/bypass-env-var-allowlist.txt.
//!
//! Ported from scripts/ci/test-no-new-bypass-env-vars.sh (INFRA-2429). The
//! ported scan is parsed, not raw grep: tokens are extracted on identifier
//! boundaries, comment-only added lines are skipped (INFRA-2438 — a deletion
//! PR documenting what it removed must not self-flag), *_DISABLED names are
//! exempt (Category B operator kill-switches), and the same three registry
//! files the original exempted are exempt here. The EFFECTIVE-094
//! debt-ceiling companion stays in the shell script (repo-wide count, not a
//! diff property) — see docs/process/VERIFY_MIGRATION.md.
//!
//! NOTE: pattern fragments below are deliberately split string literals so
//! this file never contains a contiguous bypass-class token — the rule must
//! not flag its own source (the original script had the same self-exemption).

use super::{Evaluation, Rule};
use crate::verify::{ChangeKind, VerifyContext};
use std::collections::BTreeSet;

pub struct NoNewBypassEnvVars;

const RULE_ID: &str = "no-new-bypass-env-vars";

const RECEIPT: &str = "INFRA-2429 zero-bypass thesis + EFFECTIVE-094: the bypass/skip var count climbed 113 -> 233 through growth-with-paperwork; every new bypass-class env var is a future silent regression path, so introductions are forbidden without an operator-reviewed allowlist entry";

/// Files that legitimately contain bypass-class var names (documentation or
/// the lint machinery itself), mirrored from the original script's awk filter,
/// plus this rule's own source.
const EXEMPT_PATHS: &[&str] = &[
    "scripts/ci/test-no-new-bypass-env-vars.sh",
    "scripts/ci/bypass-env-var-allowlist.txt",
    "scripts/ci/env-vars-internal.txt",
    "src/verify/rules/no_new_bypass_env_vars.rs",
];

fn suffix_bypass() -> &'static str {
    concat!("BY", "PASS")
}

fn suffix_skip() -> &'static str {
    concat!("SK", "IP")
}

fn ignore_prefix() -> String {
    format!("CHUMP_{}{}_", "IGN", "ORE")
}

impl Rule for NoNewBypassEnvVars {
    fn id(&self) -> &'static str {
        RULE_ID
    }

    fn incident_receipt(&self) -> &'static str {
        RECEIPT
    }

    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation {
        let mut candidates: BTreeSet<String> = BTreeSet::new();

        for f in &ctx.files {
            if f.kind == ChangeKind::Deleted || EXEMPT_PATHS.contains(&f.path.as_str()) {
                continue;
            }
            for line in &f.added_lines {
                let t = line.trim_start();
                // INFRA-2438: comment-only lines document deletions, they
                // don't introduce vars.
                if t.starts_with('#')
                    || t.starts_with("//")
                    || t.starts_with('*')
                    || t.starts_with('>')
                {
                    continue;
                }
                for token in extract_chump_tokens(line) {
                    if is_bypass_class(&token) {
                        candidates.insert(token);
                    }
                }
            }
        }

        if candidates.is_empty() {
            return Evaluation::Pass("no bypass-class env vars introduced".to_string());
        }

        let allowlist = load_allowlist(ctx);
        let violations: Vec<String> = candidates
            .into_iter()
            .filter(|v| !allowlist.contains(v))
            .collect();

        if violations.is_empty() {
            return Evaluation::Pass(
                "all introduced bypass-class vars are allowlisted".to_string(),
            );
        }

        Evaluation::Fail {
            detail: format!(
                "new bypass-class env var(s) not in allowlist: {}",
                violations.join(", ")
            ),
            remediation: "remove the env var and fix the underlying gate (preferred; see INFRA-2422..INFRA-2428 for the deletion pattern), or add the name to scripts/ci/bypass-env-var-allowlist.txt with a Bypass-Justification: comment referencing a deletion gap ID (operator review required)".to_string(),
        }
    }
}

/// Extract `CHUMP_`-prefixed identifier tokens on word boundaries.
fn extract_chump_tokens(line: &str) -> Vec<String> {
    let bytes = line.as_bytes();
    let is_ident = |b: u8| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_';
    let mut out = Vec::new();
    let needle = b"CHUMP_";
    let mut i = 0;
    while i + needle.len() <= bytes.len() {
        if &bytes[i..i + needle.len()] == needle {
            // Word boundary on the left (previous byte must not be ident-ish).
            if i > 0 && (is_ident(bytes[i - 1]) || bytes[i - 1].is_ascii_lowercase()) {
                i += 1;
                continue;
            }
            let mut j = i + needle.len();
            while j < bytes.len() && is_ident(bytes[j]) {
                j += 1;
            }
            if j > i + needle.len() {
                out.push(line[i..j].to_string());
            }
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

/// A token is bypass-class when it carries a bypass/skip suffix fragment or
/// the ignore-prefix, and is not a *_DISABLED Category B kill-switch.
fn is_bypass_class(token: &str) -> bool {
    if token.ends_with("_DISABLED") {
        return false;
    }
    let ip = ignore_prefix();
    token.contains(suffix_bypass())
        || token.contains(suffix_skip())
        || (token.len() > ip.len() && token.starts_with(&ip))
}

fn load_allowlist(ctx: &VerifyContext) -> BTreeSet<String> {
    let path = ctx
        .repo_root
        .join("scripts/ci/bypass-env-var-allowlist.txt");
    let Ok(body) = std::fs::read_to_string(&path) else {
        return BTreeSet::new();
    };
    body.lines()
        .filter_map(|l| {
            let t = l.trim();
            if t.is_empty() || t.starts_with('#') {
                return None;
            }
            t.split_whitespace().next().map(str::to_string)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::{test_context, DiffFile, Stage};
    use std::path::Path;

    fn var(mid: &str, suffix: &str) -> String {
        format!("CHUMP_{mid}_{suffix}")
    }

    fn diff(path: &str, lines: &[String]) -> DiffFile {
        DiffFile {
            path: path.to_string(),
            kind: ChangeKind::Modified,
            added_lines: lines.to_vec(),
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
        NoNewBypassEnvVars.evaluate(&ctx)
    }

    #[test]
    fn flags_new_bypass_var() {
        let v = var("NEW", suffix_bypass());
        let ev = eval(vec![diff("scripts/foo.sh", &[format!("export {v}=1")])]);
        match ev {
            Evaluation::Fail { detail, .. } => assert!(detail.contains(&v), "{detail}"),
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn flags_skip_and_ignore_families() {
        let skip = var("THING", suffix_skip());
        let ign = format!("{}X", ignore_prefix());
        let ev = eval(vec![diff(
            "src/x.rs",
            &[
                format!("std::env::var(\"{skip}\")"),
                format!("if {ign} {{}}"),
            ],
        )]);
        match ev {
            Evaluation::Fail { detail, .. } => {
                assert!(detail.contains(&skip) && detail.contains(&ign), "{detail}");
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn comment_only_lines_are_exempt() {
        let v = var("DOCUMENTED", suffix_bypass());
        let ev = eval(vec![diff(
            "scripts/foo.sh",
            &[
                format!("# {v} is deleted"),
                format!("// {v} removed"),
                format!("> {v} was the old escape hatch"),
            ],
        )]);
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn disabled_kill_switches_are_exempt() {
        let v = format!("CHUMP_THING_{}_DISABLED", suffix_skip());
        let ev = eval(vec![diff("scripts/foo.sh", &[format!("export {v}=1")])]);
        assert!(
            matches!(ev, Evaluation::Pass(_)),
            "{v} should be Category B exempt"
        );
    }

    #[test]
    fn exempt_registry_files_are_skipped() {
        let v = var("REGISTRY", suffix_bypass());
        let ev = eval(vec![diff(
            "scripts/ci/env-vars-internal.txt",
            std::slice::from_ref(&v),
        )]);
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn allowlisted_var_passes() {
        let tmp = std::env::temp_dir().join(format!("verify-bypass-allow-{}", std::process::id()));
        let ci = tmp.join("scripts/ci");
        std::fs::create_dir_all(&ci).unwrap();
        let v = var("GRANDFATHERED", suffix_bypass());
        std::fs::write(
            ci.join("bypass-env-var-allowlist.txt"),
            format!("# allowlist\n{v}  # Bypass-Justification: legacy, deletion gap filed\n"),
        )
        .unwrap();
        let ctx = test_context(
            Stage::CommitMsg,
            &tmp,
            vec![diff("scripts/foo.sh", &[format!("export {v}=1")])],
            Some("msg"),
            None,
        );
        let ev = NoNewBypassEnvVars.evaluate(&ctx);
        std::fs::remove_dir_all(&tmp).ok();
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn token_extraction_respects_word_boundaries() {
        let v = var("REAL", suffix_bypass());
        // XCHUMP_... is not a CHUMP_ token; lowercase prefix breaks the boundary.
        let toks = extract_chump_tokens(&format!("xCHUMP_FAKE_{} {v}", suffix_bypass()));
        assert_eq!(toks, vec![v]);
    }
}
