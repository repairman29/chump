//! INFRA-1670: `chump preflight` — single-command local CI mirror.
//! INFRA-1672: `--scope` flag — auto-detect docs/scripts/rust scopes from
//! the staged diff so a docs-only PR doesn't pay the full cargo bill.
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
//! Speed targets (INFRA-1672):
//!   `--scope docs`     <5s   (no cargo, no scripts gates)
//!   `--scope scripts` <15s   (no cargo; relevant scripts/ci/test-*.sh)
//!   `--scope rust`    <60s   (cargo fmt/clippy/check warm; no scripts)
//!   `--scope all`     same as INFRA-1670 (every gate)

use std::process::{Command, Stdio};
use std::time::Instant;

/// One gate the preflight runs.
#[derive(Debug, Clone)]
struct Step {
    /// Human-readable name printed in the status line.
    name: &'static str,
    /// Argv to run. First element is the binary; rest are args.
    argv: Vec<String>,
    /// Bucket this gate belongs to — used by `--scope` filtering.
    kind: GateKind,
}

/// Bucket each gate belongs to. `--scope` keeps only the buckets that match
/// the staged diff (or all, if explicitly forced).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GateKind {
    /// `cargo fmt|clippy|check` — runs only when rust files changed.
    Rust,
    /// `scripts/ci/test-*.sh` — runs when shell / workflow files changed.
    Scripts,
    /// Always-on cheap gates. Reserved for future use — runs on every scope.
    #[allow(dead_code)]
    AlwaysFast,
}

fn step(name: &'static str, argv: &[&str], kind: GateKind) -> Step {
    Step {
        name,
        argv: argv.iter().map(|s| s.to_string()).collect(),
        kind,
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

/// Resolved scope after parsing `--scope` and (if auto) reading the diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Scope {
    rust: bool,
    scripts: bool,
    /// Docs: no Rust gates and no scripts gates, just the always-fast ones.
    /// We track it explicitly so `--help` text / status line reads naturally.
    docs: bool,
}

impl Scope {
    fn all() -> Self {
        Self {
            rust: true,
            scripts: true,
            docs: true,
        }
    }
    fn none() -> Self {
        Self {
            rust: false,
            scripts: false,
            docs: false,
        }
    }
    /// Returns true if the gate's kind should run under this scope.
    fn includes(&self, kind: GateKind) -> bool {
        match kind {
            // AlwaysFast is universal — even docs-only scopes get it because
            // it's <2s and catches the most common cross-cutting issues.
            GateKind::AlwaysFast => true,
            GateKind::Rust => self.rust,
            GateKind::Scripts => self.scripts,
        }
    }
    fn label(&self) -> String {
        let mut parts = vec![];
        if self.rust {
            parts.push("rust");
        }
        if self.scripts {
            parts.push("scripts");
        }
        if self.docs && !self.rust && !self.scripts {
            parts.push("docs");
        }
        if parts.is_empty() {
            "none (always-fast only)".to_string()
        } else {
            parts.join("+")
        }
    }
}

/// `--scope` enum surface. `Auto` is the default and reads the diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScopeArg {
    Auto,
    All,
    Rust,
    Scripts,
    Docs,
}

impl ScopeArg {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(ScopeArg::Auto),
            "all" => Some(ScopeArg::All),
            "rust" => Some(ScopeArg::Rust),
            "scripts" => Some(ScopeArg::Scripts),
            "docs" => Some(ScopeArg::Docs),
            _ => None,
        }
    }
}

/// Given a list of staged file paths (relative to repo root), determine
/// which gate buckets should run. Mirrors the `changes:` path-filter section
/// of `.github/workflows/ci.yml`.
///
/// Mapping (kept deliberately simple for Phase 1 — full YAML parsing is a
/// follow-up if/when the path lists diverge from this snapshot):
///
///   *.rs, Cargo.toml, Cargo.lock, build.rs, crates/**, chump-tool-macro/**,
///   src/**, tests/**, wasm/**                    → rust
///   *.sh, scripts/**, .github/workflows/**,
///   bin/**, launchd/**, config/**, .release-plz.toml → scripts
///   *.md, docs/**, book/**, CHANGELOG.md, SECURITY.md, README.md → docs
///
/// Anything unrecognized falls back to `all` (conservative — better to do
/// extra work than skip a gate the diff actually needs).
fn scope_from_paths(paths: &[String]) -> Scope {
    if paths.is_empty() {
        // No staged diff → assume worst case (full scope). This matches the
        // INFRA-1670 behavior so `chump preflight` with no staged changes
        // still runs a full local-CI mirror.
        return Scope::all();
    }
    let mut s = Scope::none();
    let mut unrecognized = false;
    for p in paths {
        let lower = p.to_lowercase();
        let is_rust = lower.ends_with(".rs")
            || lower == "cargo.toml"
            || lower == "cargo.lock"
            || lower == "build.rs"
            || lower.starts_with("src/")
            || lower.starts_with("crates/")
            || lower.starts_with("chump-tool-macro/")
            || lower.starts_with("tests/")
            || lower.starts_with("wasm/");
        let is_scripts = lower.ends_with(".sh")
            || lower.starts_with("scripts/")
            || lower.starts_with(".github/workflows/")
            || lower.starts_with("bin/")
            || lower.starts_with("launchd/")
            || lower.starts_with("config/")
            || lower == ".release-plz.toml";
        let is_docs =
            lower.ends_with(".md") || lower.starts_with("docs/") || lower.starts_with("book/");
        if is_rust {
            s.rust = true;
        }
        if is_scripts {
            s.scripts = true;
        }
        if is_docs {
            s.docs = true;
        }
        if !is_rust && !is_scripts && !is_docs {
            unrecognized = true;
        }
    }
    if unrecognized {
        // Conservative: an unknown path means we don't know the impact; run
        // every bucket so we don't ship a regression.
        return Scope::all();
    }
    s
}

/// Read `git diff --cached --name-only` from the repo root. Returns an empty
/// vec on any error (so callers can fall back to "all scope").
fn staged_paths(repo_root: &std::path::Path) -> Vec<String> {
    let out = Command::new("git")
        .args(["diff", "--cached", "--name-only"])
        .current_dir(repo_root)
        .output();
    let Ok(o) = out else { return vec![] };
    if !o.status.success() {
        return vec![];
    }
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Resolve the user's `--scope` argument into a concrete `Scope`. `Auto`
/// consults the staged diff via `git diff --cached --name-only`.
fn resolve_scope(arg: ScopeArg, repo_root: &std::path::Path) -> Scope {
    match arg {
        ScopeArg::All => Scope::all(),
        ScopeArg::Rust => Scope {
            rust: true,
            scripts: false,
            docs: false,
        },
        ScopeArg::Scripts => Scope {
            rust: false,
            scripts: true,
            docs: false,
        },
        ScopeArg::Docs => Scope {
            rust: false,
            scripts: false,
            docs: true,
        },
        ScopeArg::Auto => {
            let paths = staged_paths(repo_root);
            scope_from_paths(&paths)
        }
    }
}

/// CLI args parser — intentionally lightweight (no clap; this is a one-shot subcommand).
struct Args {
    with_tests: bool,
    keep_going: bool,
    json: bool,
    help: bool,
    scope: ScopeArg,
    /// True if `--scope <bad>` was passed; main loop errors out.
    bad_scope: Option<String>,
}

fn parse_args(argv: &[String]) -> Args {
    let mut a = Args {
        with_tests: false,
        keep_going: false,
        json: false,
        help: false,
        scope: ScopeArg::Auto,
        bad_scope: None,
    };
    let mut i = 0;
    while i < argv.len() {
        let arg = &argv[i];
        match arg.as_str() {
            "--with-tests" => a.with_tests = true,
            "--keep-going" => a.keep_going = true,
            "--json" => a.json = true,
            "-h" | "--help" => a.help = true,
            "--scope" => {
                if i + 1 >= argv.len() {
                    a.bad_scope = Some("(missing value)".to_string());
                } else {
                    let v = &argv[i + 1];
                    match ScopeArg::parse(v) {
                        Some(s) => a.scope = s,
                        None => a.bad_scope = Some(v.clone()),
                    }
                    i += 1;
                }
            }
            s if s.starts_with("--scope=") => {
                let v = &s["--scope=".len()..];
                match ScopeArg::parse(v) {
                    Some(s) => a.scope = s,
                    None => a.bad_scope = Some(v.to_string()),
                }
            }
            _ => {} // ignore unknowns for forward-compat
        }
        i += 1;
    }
    a
}

fn print_help() {
    println!(
        "chump preflight — local CI mirror (INFRA-1670, INFRA-1672)

USAGE:
    chump preflight [OPTIONS]

OPTIONS:
    --scope <S>     Limit gates to a scope. S = auto|all|rust|scripts|docs.
                    Default 'auto' reads `git diff --cached --name-only`
                    and runs only the buckets the diff touches.
                    Speed targets:
                       docs    <5s   (no cargo, no scripts gates)
                       scripts <15s  (no cargo; relevant scripts/ci/test-*.sh)
                       rust    <60s  (cargo fmt/clippy/check warm; no scripts)
                       all     same as the full INFRA-1670 set
    --with-tests    Also run scripts/ci/test-*.sh that match the staged diff
                    (slower; off by default to keep the fast path under 60s)
    --keep-going    Don't exit on the first failure; run all gates
    --json          Emit one JSON object per gate to stdout (machine-readable)
    -h, --help      This message

BYPASS:
    CHUMP_PREFLIGHT_SKIP=1   Skip everything (with audit warning).
                             Add 'Preflight-Skip-Reason: <why>' to commit body.

GATES (in order):
    1. cargo fmt --check               (scope: rust)
    2. cargo clippy -- -D warnings     (scope: rust)
    3. cargo check                     (scope: rust)
    4. (with --with-tests) selected scripts/ci/test-*.sh  (scope: scripts)

EXIT CODES:
    0   all gates passed
    1   one or more gates failed (see stdout)
    2   bad usage"
    );
}

/// Discover scripts/ci/test-*.sh files. The MVP returns a tight whitelist of
/// fast, broadly-useful tests; INFRA-1672 wires diff scoping above the gate
/// itself rather than per-script.
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
    if let Some(bad) = &args.bad_scope {
        eprintln!(
            "chump preflight: bad --scope value '{}' (want auto|all|rust|scripts|docs)",
            bad
        );
        return 2;
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

    let scope = resolve_scope(args.scope, &repo_root);
    eprintln!(
        "[preflight] scope={} (--scope {:?})",
        scope.label(),
        args.scope
    );
    // Print which heavy buckets are being skipped — useful operator signal.
    if !scope.rust {
        eprintln!("[preflight] skipping cargo gates (no rust files in scope)");
    }
    if !scope.scripts && args.with_tests {
        eprintln!("[preflight] skipping scripts gates (no scripts files in scope)");
    }

    let mut steps: Vec<Step> = vec![];
    if scope.includes(GateKind::Rust) {
        steps.push(step(
            "cargo fmt --check",
            &["cargo", "fmt", "--all", "--", "--check"],
            GateKind::Rust,
        ));
        steps.push(step(
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
            GateKind::Rust,
        ));
        steps.push(step(
            "cargo check",
            &["cargo", "check", "--workspace"],
            GateKind::Rust,
        ));
        // INFRA-1731: event-registry-audit local gate. Catches
        // register-without-emit (orphan) failures BEFORE push so operators
        // don't burn a CI round-trip on an audit fail. The audit script
        // itself respects CHUMP_REGISTRY_GATE_MODE; gate-specific skip is
        // CHUMP_PREFLIGHT_SKIP_REGISTRY=1 (with audit-trail emit).
        if std::env::var("CHUMP_PREFLIGHT_SKIP_REGISTRY").as_deref() == Ok("1") {
            eprintln!(
                "[preflight] skipping event-registry-audit (CHUMP_PREFLIGHT_SKIP_REGISTRY=1)"
            );
            let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                kind: "preflight_registry_bypassed".to_string(),
                source: Some("chump-preflight".to_string()),
                fields: vec![(
                    "reason".to_string(),
                    "CHUMP_PREFLIGHT_SKIP_REGISTRY=1".to_string(),
                )],
                ..Default::default()
            });
        } else {
            steps.push(step(
                "event-registry-audit",
                &["bash", "scripts/ci/test-event-registry-coverage.sh"],
                GateKind::Rust,
            ));
        }
        // INFRA-1787: env-var-coverage local gate. Catches CHUMP_* env vars
        // referenced in Rust/scripts but not documented in
        // scripts/ci/env-vars-internal.txt — the #1 most-frequent CI audit
        // fail class (5+ failures/week pre-mirror). Skip via
        // CHUMP_PREFLIGHT_SKIP_ENVVARS=1 with audit-trail emit (mirrors the
        // INFRA-1731 pattern shipped at #2377).
        if std::env::var("CHUMP_PREFLIGHT_SKIP_ENVVARS").as_deref() == Ok("1") {
            eprintln!(
                "[preflight] skipping env-var-coverage (CHUMP_PREFLIGHT_SKIP_ENVVARS=1)"
            );
            let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                kind: "preflight_envvars_bypassed".to_string(),
                source: Some("chump-preflight".to_string()),
                fields: vec![(
                    "reason".to_string(),
                    "CHUMP_PREFLIGHT_SKIP_ENVVARS=1".to_string(),
                )],
                ..Default::default()
            });
        } else {
            steps.push(step(
                "env-var-coverage",
                &["bash", "scripts/ci/test-env-var-coverage.sh"],
                GateKind::Rust,
            ));
        }
    }

    if args.with_tests && scope.includes(GateKind::Scripts) {
        for script in discover_test_scripts(&repo_root) {
            let path = script.to_string_lossy().into_owned();
            let name: &'static str = Box::leak(
                format!("script: {}", script.file_name().unwrap().to_string_lossy())
                    .into_boxed_str(),
            );
            steps.push(Step {
                name,
                argv: vec!["bash".to_string(), path],
                kind: GateKind::Scripts,
            });
        }
    }

    let started = Instant::now();
    let mut any_failed = false;
    let mut json_results: Vec<String> = vec![];

    if steps.is_empty() {
        eprintln!(
            "[preflight] no gates selected for this scope — nothing to do (normal for docs-only)"
        );
    }

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
        assert_eq!(a.scope, ScopeArg::Auto);
        assert!(a.bad_scope.is_none());
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
    fn parse_args_scope_separate() {
        let a = parse_args(&["--scope".to_string(), "rust".to_string()]);
        assert_eq!(a.scope, ScopeArg::Rust);
        assert!(a.bad_scope.is_none());
    }

    #[test]
    fn parse_args_scope_equals() {
        let a = parse_args(&["--scope=docs".to_string()]);
        assert_eq!(a.scope, ScopeArg::Docs);
    }

    #[test]
    fn parse_args_scope_all_variants() {
        for (lit, expected) in [
            ("auto", ScopeArg::Auto),
            ("all", ScopeArg::All),
            ("rust", ScopeArg::Rust),
            ("scripts", ScopeArg::Scripts),
            ("docs", ScopeArg::Docs),
        ] {
            let a = parse_args(&["--scope".to_string(), lit.to_string()]);
            assert_eq!(a.scope, expected, "scope literal {lit}");
        }
    }

    #[test]
    fn parse_args_scope_bad_value() {
        let a = parse_args(&["--scope".to_string(), "frontend".to_string()]);
        assert!(a.bad_scope.is_some());
    }

    #[test]
    fn parse_args_scope_missing_value() {
        let a = parse_args(&["--scope".to_string()]);
        assert!(a.bad_scope.is_some());
    }

    #[test]
    fn run_step_passes_on_true() {
        let s = step("true probe", &["true"], GateKind::Rust);
        let out = run_step(&s);
        assert_eq!(out.status, Status::Pass);
        assert!(out.captured.is_none());
    }

    #[test]
    fn run_step_fails_on_false() {
        let s = step("false probe", &["false"], GateKind::Rust);
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

    // ── INFRA-1672: scope_from_paths matrix ────────────────────────────────

    #[test]
    fn scope_from_paths_docs_only() {
        let paths = vec![
            "docs/process/CLAUDE_GOTCHAS.md".to_string(),
            "README.md".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(!s.rust, "docs-only must skip rust");
        assert!(!s.scripts, "docs-only must skip scripts");
        assert!(s.docs, "docs-only must record docs");
    }

    #[test]
    fn scope_from_paths_rust_only() {
        let paths = vec![
            "src/preflight.rs".to_string(),
            "Cargo.toml".to_string(),
            "crates/chump-tool-macro/src/lib.rs".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(s.rust);
        assert!(!s.scripts);
        assert!(!s.docs);
    }

    #[test]
    fn scope_from_paths_scripts_only() {
        let paths = vec![
            "scripts/ci/test-foo.sh".to_string(),
            ".github/workflows/ci.yml".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(!s.rust);
        assert!(s.scripts);
        assert!(!s.docs);
    }

    #[test]
    fn scope_from_paths_mixed_rust_and_docs() {
        let paths = vec![
            "src/lib.rs".to_string(),
            "docs/process/CLAUDE_GOTCHAS.md".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(s.rust);
        assert!(!s.scripts);
        assert!(s.docs);
    }

    #[test]
    fn scope_from_paths_unrecognized_falls_back_to_all() {
        // An exotic path we don't classify → conservative: run everything.
        let paths = vec!["weird/unknown-thing.xyz".to_string()];
        let s = scope_from_paths(&paths);
        assert!(s.rust && s.scripts && s.docs, "unknown path → all scope");
    }

    #[test]
    fn scope_from_paths_empty_means_all() {
        let s = scope_from_paths(&[]);
        assert!(s.rust && s.scripts && s.docs, "empty diff → all scope");
    }

    #[test]
    fn scope_includes_respects_always_fast() {
        let s = Scope::none();
        assert!(
            s.includes(GateKind::AlwaysFast),
            "AlwaysFast must run on any scope"
        );
        assert!(!s.includes(GateKind::Rust));
        assert!(!s.includes(GateKind::Scripts));
    }

    #[test]
    fn scope_label_human_readable() {
        assert_eq!(Scope::all().label(), "rust+scripts");
        assert_eq!(
            Scope {
                rust: false,
                scripts: false,
                docs: true,
            }
            .label(),
            "docs"
        );
        assert_eq!(Scope::none().label(), "none (always-fast only)");
    }
}
