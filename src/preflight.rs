//! INFRA-1670: `chump preflight` — single-command local CI mirror.
//!
//! Runs the gates that catch the bulk of CI failures locally, in seconds
//! instead of the ~15-minute GitHub Actions round-trip. The gates are
//! exactly what CI runs:
//!
//!   1. `cargo fmt --all -- --check`              (fmt drift)
//!   2. `cargo clippy --workspace --all-targets -- -D warnings`
//!   3. `cargo check --workspace`
//!   4. (optional, `--with-tests`) selected `scripts/ci/test-*.sh`
//!
//! Each step prints its name + duration + status. Exits non-zero on the
//! first failure (unless `--keep-going`).
//!
//! Bypass: `CHUMP_PREFLIGHT_SKIP=1` short-circuits the whole thing (with
//! a warning). Audit-logged via `chump-commit.sh` per INFRA-1673.
//!
//! Smart scoping (run only gates relevant to the staged diff) is a
//! follow-up — INFRA-1672. This MVP runs everything.

use std::process::{Command, Stdio};
use std::time::Instant;

/// One gate the preflight runs.
#[derive(Debug, Clone)]
struct Step {
    /// Human-readable name printed in the status line.
    name: &'static str,
    /// Argv to run. First element is the binary; rest are args.
    argv: Vec<String>,
    /// If false, skip this step unless `--with-tests` is set. Used for
    /// scripts/ci/test-*.sh which are slower and not always necessary.
    fast: bool,
}

fn step(name: &'static str, argv: &[&str], fast: bool) -> Step {
    Step {
        name,
        argv: argv.iter().map(|s| s.to_string()).collect(),
        fast,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Pass,
    Fail,
    Skipped,
}

struct Outcome {
    status: Status,
    elapsed_ms: u128,
    /// stdout+stderr if Fail; None on Pass for terseness.
    captured: Option<String>,
}

fn run_step(s: &Step) -> Outcome {
    let started = Instant::now();
    let mut cmd = Command::new(&s.argv[0]);
    cmd.args(&s.argv[1..]).stdin(Stdio::null());
    let result = cmd.output();
    let elapsed_ms = started.elapsed().as_millis();
    match result {
        Ok(o) if o.status.success() => Outcome {
            status: Status::Pass,
            elapsed_ms,
            captured: None,
        },
        Ok(o) => {
            let mut captured = String::new();
            captured.push_str(&String::from_utf8_lossy(&o.stdout));
            captured.push_str(&String::from_utf8_lossy(&o.stderr));
            Outcome {
                status: Status::Fail,
                elapsed_ms,
                captured: Some(captured),
            }
        }
        Err(e) => Outcome {
            status: Status::Fail,
            elapsed_ms,
            captured: Some(format!("failed to spawn {:?}: {}", s.argv, e)),
        },
    }
}

/// CLI args parser — intentionally lightweight (no clap; this is a one-shot subcommand).
struct Args {
    with_tests: bool,
    keep_going: bool,
    json: bool,
    help: bool,
}

fn parse_args(argv: &[String]) -> Args {
    let mut a = Args {
        with_tests: false,
        keep_going: false,
        json: false,
        help: false,
    };
    for arg in argv {
        match arg.as_str() {
            "--with-tests" => a.with_tests = true,
            "--keep-going" => a.keep_going = true,
            "--json" => a.json = true,
            "-h" | "--help" => a.help = true,
            _ => {} // ignore unknowns for forward-compat
        }
    }
    a
}

fn print_help() {
    println!(
        "chump preflight — local CI mirror (INFRA-1670)

USAGE:
    chump preflight [OPTIONS]

OPTIONS:
    --with-tests    Also run scripts/ci/test-*.sh that match the staged diff
                    (slower; off by default to keep the fast path under 60s)
    --keep-going    Don't exit on the first failure; run all gates
    --json          Emit one JSON object per gate to stdout (machine-readable)
    -h, --help      This message

BYPASS:
    CHUMP_PREFLIGHT_SKIP=1   Skip everything (with audit warning).
                             Add 'Preflight-Skip-Reason: <why>' to commit body.

GATES (in order):
    1. cargo fmt --check
    2. cargo clippy -- -D warnings
    3. cargo check
    4. (with --with-tests) selected scripts/ci/test-*.sh

EXIT CODES:
    0   all gates passed
    1   one or more gates failed (see stdout)
    2   bad usage"
    );
}

/// Discover scripts/ci/test-*.sh files. The MVP returns a tight whitelist of
/// fast, broadly-useful tests; INFRA-1672 will widen this with diff scoping.
fn discover_test_scripts(repo_root: &std::path::Path) -> Vec<std::path::PathBuf> {
    // Conservative whitelist — these are the ones that have most often
    // failed-on-CI-but-would-have-passed-locally in the last 48h.
    let candidates = [
        "scripts/ci/test-event-registry-coverage.sh",
        "scripts/ci/test-no-raw-gh-in-hot-paths.sh",
        "scripts/ci/check-path-filter-coverage.sh",
        "scripts/ci/test-env-var-coverage.sh",
        "scripts/ci/test-merged-check-guard.sh",
    ];
    candidates
        .iter()
        .map(|p| repo_root.join(p))
        .filter(|p| p.is_file())
        .collect()
}

/// Entry point called from main.rs subcommand dispatch.
/// Returns the process exit code.
pub fn run(argv: &[String]) -> i32 {
    let args = parse_args(argv);
    if args.help {
        print_help();
        return 0;
    }
    if std::env::var("CHUMP_PREFLIGHT_SKIP").as_deref() == Ok("1") {
        eprintln!("⚠  chump preflight: CHUMP_PREFLIGHT_SKIP=1 — skipping");
        eprintln!("   Add 'Preflight-Skip-Reason: <why>' to your commit body for audit.");
        return 0;
    }

    let repo_root = match find_repo_root() {
        Some(p) => p,
        None => {
            eprintln!("chump preflight: not inside a git repo");
            return 2;
        }
    };

    // Set cwd to repo root so cargo + scripts pick up the right Cargo.toml.
    if std::env::set_current_dir(&repo_root).is_err() {
        eprintln!(
            "chump preflight: could not cd to repo root {}",
            repo_root.display()
        );
        return 2;
    }

    let mut steps = vec![
        step(
            "cargo fmt --check",
            &["cargo", "fmt", "--all", "--", "--check"],
            true,
        ),
        step(
            "cargo clippy -D warnings",
            &[
                "cargo",
                "clippy",
                "--workspace",
                "--all-targets",
                "--",
                "-D",
                "warnings",
            ],
            true,
        ),
        step("cargo check", &["cargo", "check", "--workspace"], true),
    ];

    if args.with_tests {
        for script in discover_test_scripts(&repo_root) {
            let path = script.to_string_lossy().into_owned();
            let name: &'static str = Box::leak(
                format!("script: {}", script.file_name().unwrap().to_string_lossy())
                    .into_boxed_str(),
            );
            steps.push(Step {
                name,
                argv: vec!["bash".to_string(), path],
                fast: false,
            });
        }
    }

    let started = Instant::now();
    let mut any_failed = false;
    let mut json_results: Vec<String> = vec![];

    for s in &steps {
        eprint!("[preflight] {} ... ", s.name);
        let out = run_step(s);
        let symbol = match out.status {
            Status::Pass => "✓",
            Status::Fail => "✗",
            Status::Skipped => "·",
        };
        eprintln!("{} ({}ms)", symbol, out.elapsed_ms);
        if args.json {
            json_results.push(format!(
                r#"{{"step":"{}","status":"{:?}","elapsed_ms":{}}}"#,
                s.name, out.status, out.elapsed_ms
            ));
        }
        if out.status == Status::Fail {
            any_failed = true;
            if let Some(cap) = &out.captured {
                eprintln!("---- {} output ----", s.name);
                // Truncate to first ~2KB to avoid swamping the terminal.
                let trunc = if cap.len() > 2048 {
                    format!(
                        "{}\n... [{} more bytes truncated]",
                        &cap[..2048],
                        cap.len() - 2048
                    )
                } else {
                    cap.clone()
                };
                eprintln!("{}", trunc);
                eprintln!("---- end ----");
            }
            if !args.keep_going {
                break;
            }
        }
    }

    let total_ms = started.elapsed().as_millis();
    if args.json {
        println!("[{}]", json_results.join(","));
    }
    if any_failed {
        eprintln!(
            "\n[preflight] FAIL — at least one gate did not pass (total {}ms)",
            total_ms
        );
        eprintln!("   Bypass: CHUMP_PREFLIGHT_SKIP=1 + 'Preflight-Skip-Reason: <why>' trailer");
        1
    } else {
        eprintln!("\n[preflight] PASS — all gates green ({}ms)", total_ms);
        0
    }
}

fn find_repo_root() -> Option<std::path::PathBuf> {
    let out = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(std::path::PathBuf::from(path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_args_defaults() {
        let a = parse_args(&[]);
        assert!(!a.with_tests);
        assert!(!a.keep_going);
        assert!(!a.json);
        assert!(!a.help);
    }

    #[test]
    fn parse_args_flags() {
        let argv = vec![
            "--with-tests".to_string(),
            "--keep-going".to_string(),
            "--json".to_string(),
        ];
        let a = parse_args(&argv);
        assert!(a.with_tests);
        assert!(a.keep_going);
        assert!(a.json);
    }

    #[test]
    fn parse_args_help_short_and_long() {
        assert!(parse_args(&["-h".to_string()]).help);
        assert!(parse_args(&["--help".to_string()]).help);
    }

    #[test]
    fn parse_args_ignores_unknown() {
        let argv = vec!["--unknown".to_string(), "--with-tests".to_string()];
        let a = parse_args(&argv);
        assert!(a.with_tests);
    }

    #[test]
    fn run_step_passes_on_true() {
        let s = step("true probe", &["true"], true);
        let out = run_step(&s);
        assert_eq!(out.status, Status::Pass);
        assert!(out.captured.is_none());
    }

    #[test]
    fn run_step_fails_on_false() {
        let s = step("false probe", &["false"], true);
        let out = run_step(&s);
        assert_eq!(out.status, Status::Fail);
        assert!(out.captured.is_some());
    }

    #[test]
    fn skip_via_env_returns_zero() {
        // Set env, run, restore.
        std::env::set_var("CHUMP_PREFLIGHT_SKIP", "1");
        let code = run(&[]);
        std::env::remove_var("CHUMP_PREFLIGHT_SKIP");
        assert_eq!(code, 0);
    }
}
