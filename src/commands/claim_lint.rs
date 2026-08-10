//! CREDIBLE-208: claim-lint — the pre-ship bullshit gate.
//!
//! Parses an agent's ship-time claims (commit subject/body, PR description)
//! into checkable statements and grounds each against the diff:
//!   - claimed touched files must appear in `git diff --name-only <range>`
//!   - claimed symbols must appear on an added line (`^\+`) within the diff
//!   - claimed tests must appear as a `#[test] fn <name>` (or `fn <name>`)
//!     added by the diff, AND (best-effort) show up as executed in a
//!     supplied test-log file (`--test-log <path>`, checked for the
//!     "running N tests" / "test <name> ... ok" lines per
//!     DURABLE_FIX_DOCTRINE — exit 0 alone is not "ran").
//!
//! Claim extraction prefers structured trailers (cheap, unambiguous) and
//! falls back to NL patterns (backtick-quoted tokens) when no trailers are
//! present:
//!
//!   Files-Touched: src/foo.rs, src/bar.rs
//!   Symbols-Touched: foo::bar, run_baz
//!   Tests-Run: test_foo_grounds, test_bar_bounces
//!
//! Usage:
//!   chump claim-lint --range <base>..<head> [--message-file <path>]
//!                     [--test-log <path>] [--model <name>] [--gap-id <id>]
//!                     [--json] [--no-emit]
//!
//! Exit code: 0 if every claim grounds (or there are no claims), 1 if any
//! claim is ungrounded (bounce — the specific claim is named in the output).
//!
//! Emits `kind=claim_lint_result` to ambient.jsonl (unless `--no-emit`) so
//! bust-rate per model becomes a measured KPI (see `chump kpi report
//! --claims`).

use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
enum ClaimKind {
    File,
    Symbol,
    Test,
}

impl ClaimKind {
    fn as_str(&self) -> &'static str {
        match self {
            ClaimKind::File => "file",
            ClaimKind::Symbol => "symbol",
            ClaimKind::Test => "test",
        }
    }
}

#[derive(Debug, Clone)]
struct Claim {
    kind: ClaimKind,
    text: String,
}

#[derive(Debug, Clone)]
struct GroundingResult {
    claim: Claim,
    grounded: bool,
    reason: String,
}

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(c) = std::fs::read_to_string(&cargo) {
                if c.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Extract claims from free text. Structured trailers win when present;
/// otherwise fall back to backtick-quoted-token NL extraction.
fn extract_claims(text: &str) -> Vec<Claim> {
    let mut claims = Vec::new();
    let mut saw_trailer = false;

    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Files-Touched:") {
            saw_trailer = true;
            for tok in rest.split(',') {
                let tok = tok.trim();
                if !tok.is_empty() {
                    claims.push(Claim {
                        kind: ClaimKind::File,
                        text: tok.to_string(),
                    });
                }
            }
        } else if let Some(rest) = line.strip_prefix("Symbols-Touched:") {
            saw_trailer = true;
            for tok in rest.split(',') {
                let tok = tok.trim();
                if !tok.is_empty() {
                    claims.push(Claim {
                        kind: ClaimKind::Symbol,
                        text: tok.to_string(),
                    });
                }
            }
        } else if let Some(rest) = line.strip_prefix("Tests-Run:") {
            saw_trailer = true;
            for tok in rest.split(',') {
                let tok = tok.trim();
                if !tok.is_empty() {
                    claims.push(Claim {
                        kind: ClaimKind::Test,
                        text: tok.to_string(),
                    });
                }
            }
        }
    }

    if saw_trailer {
        return claims;
    }

    // NL fallback: backtick-quoted tokens. Classify by shape.
    let mut in_tick = false;
    let mut cur = String::new();
    for c in text.chars() {
        if c == '`' {
            if in_tick {
                let tok = cur.trim().to_string();
                cur.clear();
                if !tok.is_empty() {
                    claims.push(classify_nl_token(&tok));
                }
            }
            in_tick = !in_tick;
        } else if in_tick {
            cur.push(c);
        }
    }
    claims
}

fn classify_nl_token(tok: &str) -> Claim {
    let looks_like_file = tok.contains('/')
        && tok
            .rsplit('.')
            .next()
            .map(|ext| ext.len() <= 5 && ext.chars().all(|c| c.is_ascii_alphanumeric()))
            .unwrap_or(false);
    if looks_like_file {
        return Claim {
            kind: ClaimKind::File,
            text: tok.to_string(),
        };
    }
    if tok.starts_with("test_") || tok.starts_with("test ") {
        return Claim {
            kind: ClaimKind::Test,
            text: tok.trim_start_matches("test ").to_string(),
        };
    }
    Claim {
        kind: ClaimKind::Symbol,
        text: tok.to_string(),
    }
}

fn run_git(repo: &PathBuf, args: &[&str]) -> String {
    Command::new("git")
        .current_dir(repo)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
}

/// Ground each claim against the diff for `range` (default: working tree vs
/// HEAD when range is empty).
fn ground_claims(
    repo: &PathBuf,
    range: &str,
    claims: &[Claim],
    test_log: Option<&str>,
) -> Vec<GroundingResult> {
    let diff_args: Vec<&str> = if range.is_empty() {
        vec!["diff"]
    } else {
        vec!["diff", range]
    };
    let name_args: Vec<&str> = if range.is_empty() {
        vec!["diff", "--name-only"]
    } else {
        vec!["diff", "--name-only", range]
    };

    let diff = run_git(repo, &diff_args);
    let name_output = run_git(repo, &name_args);
    let touched_files: Vec<&str> = name_output.lines().collect();

    let added_lines: Vec<&str> = diff
        .lines()
        .filter(|l| l.starts_with('+') && !l.starts_with("+++"))
        .collect();

    let test_log_content = test_log.and_then(|p| std::fs::read_to_string(p).ok());

    claims
        .iter()
        .map(|claim| {
            ground_one(
                claim,
                &touched_files,
                &added_lines,
                test_log_content.as_deref(),
            )
        })
        .collect()
}

fn ground_one(
    claim: &Claim,
    touched_files: &[&str],
    added_lines: &[&str],
    test_log: Option<&str>,
) -> GroundingResult {
    match claim.kind {
        ClaimKind::File => {
            let grounded = touched_files.iter().any(|f| *f == claim.text);
            let reason = if grounded {
                format!("{} present in diff --name-only", claim.text)
            } else {
                format!(
                    "{} NOT in diff --name-only (claimed touched but no such file in the diff)",
                    claim.text
                )
            };
            GroundingResult {
                claim: claim.clone(),
                grounded,
                reason,
            }
        }
        ClaimKind::Symbol => {
            let grounded = added_lines.iter().any(|l| l.contains(&claim.text));
            let reason = if grounded {
                format!("{} found on an added line in the diff", claim.text)
            } else {
                format!(
                    "{} NOT found on any added line (claimed symbol does not exist in the diff)",
                    claim.text
                )
            };
            GroundingResult {
                claim: claim.clone(),
                grounded,
                reason,
            }
        }
        ClaimKind::Test => {
            let in_diff = added_lines
                .iter()
                .any(|l| l.contains(&claim.text) && (l.contains("fn ") || l.contains("#[test]")));
            let executed = test_log
                .map(|log| log_shows_test_executed(log, &claim.text))
                .unwrap_or(true); // no log supplied: don't penalize (best-effort, AC1 grounds on diff presence)
            let grounded = in_diff && executed;
            let reason = if !in_diff {
                format!(
                    "{} NOT found as a test fn on an added line (claimed test does not exist in the diff)",
                    claim.text
                )
            } else if !executed {
                format!(
                    "{} exists in the diff but did not appear as executed in the supplied test log (exit 0 is not assertions — DURABLE_FIX_DOCTRINE)",
                    claim.text
                )
            } else {
                format!("{} present in diff and executed", claim.text)
            };
            GroundingResult {
                claim: claim.clone(),
                grounded,
                reason,
            }
        }
    }
}

/// Best-effort check that a test log shows the named test actually ran
/// (not just that the binary exited 0). Looks for a "running N tests" line
/// followed somewhere by "test <name> ... ok" or "test <name> ... FAILED".
fn log_shows_test_executed(log: &str, name: &str) -> bool {
    if !log.contains("running ") || !log.contains(" tests") {
        return false;
    }
    log.lines()
        .any(|l| l.contains(&format!("test {name}")) && (l.contains(" ok") || l.contains("FAILED")))
}

fn ambient_path() -> PathBuf {
    std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root().join(".chump-locks/ambient.jsonl"))
}

fn emit_ambient(gap_id: &str, model: &str, results: &[GroundingResult]) {
    let total = results.len();
    let ungrounded: Vec<&GroundingResult> = results.iter().filter(|r| !r.grounded).collect();
    let bust = !ungrounded.is_empty();
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let ungrounded_kinds: Vec<String> = ungrounded
        .iter()
        .map(|r| r.claim.kind.as_str().to_string())
        .collect();

    let line = format!(
        r#"{{"ts":"{ts}","event":"FEEDBACK","kind":"claim_lint_result","gap_id":"{gap_id}","model":"{model}","total_claims":{total},"ungrounded_count":{ungrounded_count},"bust":{bust},"ungrounded_kinds":[{kinds}]}}"#,
        ts = ts,
        gap_id = json_escape(gap_id),
        model = json_escape(model),
        total = total,
        ungrounded_count = ungrounded.len(),
        bust = bust,
        kinds = ungrounded_kinds
            .iter()
            .map(|k| format!("\"{k}\""))
            .collect::<Vec<_>>()
            .join(","),
    );

    let path = ambient_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{line}");
    }
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

pub fn run(args: &[String]) -> i32 {
    let mut range = String::new();
    let mut message_file: Option<String> = None;
    let mut test_log: Option<String> = None;
    let mut model = "unknown".to_string();
    let mut gap_id = "unknown".to_string();
    let mut want_json = false;
    let mut no_emit = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--range" => {
                i += 1;
                if i < args.len() {
                    range = args[i].clone();
                }
            }
            "--message-file" => {
                i += 1;
                if i < args.len() {
                    message_file = Some(args[i].clone());
                }
            }
            "--test-log" => {
                i += 1;
                if i < args.len() {
                    test_log = Some(args[i].clone());
                }
            }
            "--model" => {
                i += 1;
                if i < args.len() {
                    model = args[i].clone();
                }
            }
            "--gap-id" => {
                i += 1;
                if i < args.len() {
                    gap_id = args[i].clone();
                }
            }
            "--json" => want_json = true,
            "--no-emit" => no_emit = true,
            "--help" | "-h" => {
                println!(
                    "Usage: chump claim-lint --range <base>..<head> [--message-file <path>] \
                     [--test-log <path>] [--model <name>] [--gap-id <id>] [--json] [--no-emit]"
                );
                return 0;
            }
            _ => {}
        }
        i += 1;
    }

    let text = match &message_file {
        Some(p) => std::fs::read_to_string(p).unwrap_or_default(),
        None => {
            // Fall back to the HEAD commit message so a bare invocation
            // (e.g. from a pre-push hook) works with no extra plumbing.
            let repo = repo_root();
            run_git(&repo, &["log", "-1", "--pretty=%B"])
        }
    };

    let repo = repo_root();
    let claims = extract_claims(&text);

    if claims.is_empty() {
        if want_json {
            println!(r#"{{"total_claims":0,"ungrounded_count":0,"bust":false,"claims":[]}}"#);
        } else {
            println!("[claim-lint] no checkable claims found — nothing to ground");
        }
        return 0;
    }

    let results = ground_claims(&repo, &range, &claims, test_log.as_deref());
    let ungrounded: Vec<&GroundingResult> = results.iter().filter(|r| !r.grounded).collect();
    let bust = !ungrounded.is_empty();

    if !no_emit {
        emit_ambient(&gap_id, &model, &results);
    }

    if want_json {
        let claims_json: Vec<String> = results
            .iter()
            .map(|r| {
                format!(
                    r#"{{"kind":"{}","text":"{}","grounded":{},"reason":"{}"}}"#,
                    r.claim.kind.as_str(),
                    json_escape(&r.claim.text),
                    r.grounded,
                    json_escape(&r.reason),
                )
            })
            .collect();
        println!(
            r#"{{"total_claims":{},"ungrounded_count":{},"bust":{},"claims":[{}]}}"#,
            results.len(),
            ungrounded.len(),
            bust,
            claims_json.join(",")
        );
    } else if bust {
        println!(
            "[claim-lint] BOUNCE — {} ungrounded claim(s):",
            ungrounded.len()
        );
        for r in &ungrounded {
            println!(
                "  - [{}] {}: {}",
                r.claim.kind.as_str(),
                r.claim.text,
                r.reason
            );
        }
    } else {
        println!(
            "[claim-lint] all {} claim(s) grounded — clear to ship",
            results.len()
        );
    }

    if bust {
        1
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_structured_trailers() {
        let text = "Fix the thing\n\nFiles-Touched: src/foo.rs, src/bar.rs\nSymbols-Touched: run_baz\nTests-Run: test_baz_works\n";
        let claims = extract_claims(text);
        assert_eq!(claims.len(), 4);
        assert!(claims
            .iter()
            .any(|c| c.kind == ClaimKind::File && c.text == "src/foo.rs"));
        assert!(claims
            .iter()
            .any(|c| c.kind == ClaimKind::Symbol && c.text == "run_baz"));
        assert!(claims
            .iter()
            .any(|c| c.kind == ClaimKind::Test && c.text == "test_baz_works"));
    }

    #[test]
    fn nl_fallback_classifies_by_shape() {
        let text = "Implemented `run_baz` and touched `src/foo.rs`, ran `test_baz_works`.";
        let claims = extract_claims(text);
        assert_eq!(claims.len(), 3);
        let file = claims.iter().find(|c| c.text == "src/foo.rs").unwrap();
        assert_eq!(file.kind, ClaimKind::File);
        let test = claims.iter().find(|c| c.text == "test_baz_works").unwrap();
        assert_eq!(test.kind, ClaimKind::Test);
    }

    #[test]
    fn no_trailers_no_backticks_yields_no_claims() {
        let claims = extract_claims("just a plain sentence with no structure");
        assert!(claims.is_empty());
    }

    #[test]
    fn file_claim_grounds_when_present() {
        let claim = Claim {
            kind: ClaimKind::File,
            text: "src/foo.rs".to_string(),
        };
        let touched = vec!["src/foo.rs", "src/bar.rs"];
        let result = ground_one(&claim, &touched, &[], None);
        assert!(result.grounded);
    }

    #[test]
    fn file_claim_bounces_when_absent() {
        let claim = Claim {
            kind: ClaimKind::File,
            text: "src/nope.rs".to_string(),
        };
        let touched = vec!["src/foo.rs"];
        let result = ground_one(&claim, &touched, &[], None);
        assert!(!result.grounded);
        assert!(result.reason.contains("NOT in diff"));
    }

    #[test]
    fn symbol_claim_grounds_on_added_line() {
        let claim = Claim {
            kind: ClaimKind::Symbol,
            text: "run_baz".to_string(),
        };
        let added = vec!["+pub fn run_baz() {}"];
        let result = ground_one(&claim, &[], &added, None);
        assert!(result.grounded);
    }

    #[test]
    fn symbol_claim_bounces_when_not_in_diff() {
        let claim = Claim {
            kind: ClaimKind::Symbol,
            text: "does_not_exist_anywhere".to_string(),
        };
        let added = vec!["+pub fn run_baz() {}"];
        let result = ground_one(&claim, &[], &added, None);
        assert!(!result.grounded);
    }

    #[test]
    fn test_claim_grounds_without_log_when_present_in_diff() {
        let claim = Claim {
            kind: ClaimKind::Test,
            text: "test_baz_works".to_string(),
        };
        let added = vec!["+    fn test_baz_works() {"];
        let result = ground_one(&claim, &[], &added, None);
        assert!(result.grounded);
    }

    #[test]
    fn test_claim_bounces_when_absent_from_diff() {
        let claim = Claim {
            kind: ClaimKind::Test,
            text: "test_never_written".to_string(),
        };
        let added = vec!["+    fn test_baz_works() {"];
        let result = ground_one(&claim, &[], &added, None);
        assert!(!result.grounded);
    }

    #[test]
    fn test_claim_bounces_when_log_shows_not_executed() {
        let claim = Claim {
            kind: ClaimKind::Test,
            text: "test_baz_works".to_string(),
        };
        let added = vec!["+    fn test_baz_works() {"];
        let log = "running 3 tests\ntest test_other_thing ... ok\n";
        let result = ground_one(&claim, &[], &added, Some(log));
        assert!(!result.grounded);
        assert!(result.reason.contains("did not appear as executed"));
    }

    #[test]
    fn test_claim_grounds_when_log_shows_executed() {
        let claim = Claim {
            kind: ClaimKind::Test,
            text: "test_baz_works".to_string(),
        };
        let added = vec!["+    fn test_baz_works() {"];
        let log = "running 3 tests\ntest test_baz_works ... ok\n";
        let result = ground_one(&claim, &[], &added, Some(log));
        assert!(result.grounded);
    }

    #[test]
    fn log_shows_test_executed_requires_running_n_tests_line() {
        // A log with only "test X ... ok" but no "running N tests" preamble
        // does not count as proof of execution (exit 0 is not assertions).
        let log = "test test_baz_works ... ok\n";
        assert!(!log_shows_test_executed(log, "test_baz_works"));
    }

    #[test]
    fn classify_nl_token_file_vs_symbol_vs_test() {
        assert_eq!(classify_nl_token("src/foo.rs").kind, ClaimKind::File);
        assert_eq!(classify_nl_token("test_foo").kind, ClaimKind::Test);
        assert_eq!(
            classify_nl_token("SomeStruct::method").kind,
            ClaimKind::Symbol
        );
    }
}
