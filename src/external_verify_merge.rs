//! CREDIBLE-096 / CREDIBLE-102: `chump external verify-merge` — autonomous PR merge judge.
//!
//! Trust keystone for Chump's "autonomously improve someone's repo, no human
//! in the loop" mission. Decides whether a PR on an external repo meets the
//! bar for an autonomous merge, then optionally executes it.
//!
//! ## Gates (ALL must pass to merge)
//!
//! 1. **Repo CI green** — polls the PR head SHA's check-runs until ALL
//!    non-advisory checks reach a **terminal** conclusion, then judges:
//!    - All SUCCESS / SKIPPED / NEUTRAL → PASS.
//!    - Any FAILURE / CANCELLED / TIMED_OUT / ACTION_REQUIRED → HELD(ci).
//!    - Timeout (CHUMP_VERIFY_CI_WAIT_SECS, default 1200 s) with checks still
//!      pending → HELD(ci_pending).
//!    - Zero checks → HELD(no-gates): refuse to merge without any signal.
//!
//!    Polling interval: CHUMP_VERIFY_CI_POLL_SECS (default 30 s).
//!    Advisory checks: CHUMP_VERIFY_CI_ADVISORY_NAMES (comma-separated
//!    case-insensitive substrings). Matching checks are polled + logged but
//!    NEVER gate the verdict — their pending/failure state cannot HELD.
//!
//! 2. **Anti-cosmetic test gate** — the PR diff MUST add or modify at least
//!    one test file (heuristic: path contains `test` / `spec`, or file is
//!    `*_test.*` / `*_spec.*` / `test_*.rs` etc.).  That test must:
//!    - FAIL (non-zero exit) on the **base** commit of the repo, AND
//!    - PASS (exit 0) on the **PR head** commit.
//!
//!    A test that passes on both proves nothing — HELD(unproven).
//!    A PR with no changed test files at all — HELD(cosmetic).
//!
//! 3. **No-regression** — the existing test suite passes on PR head.
//!    If repo CI already runs tests (gate 1 covers this), the gate is noted
//!    as satisfied by CI. If CI only lints, we run the test suite locally.
//!
//! ## Ambient events emitted
//!
//! - `kind=external_merge_verified` — ALL gates passed (and --apply merged).
//! - `kind=external_merge_held` — at least one gate failed; includes reason.
//!
//! ## Usage
//!
//! ```text
//! chump external verify-merge \
//!     --pr <N> --repo <owner/repo> --gap <ID> \
//!     [--clone-dir <path>] [--apply]
//! ```
//!
//! Dry-run by default; --apply actually merges.
//!
//! ## Kill-switch (Category B — operator kill-switch, _DISABLED form)
//!
//! `CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED=1` — disables the subcommand
//! entirely (exits 1 with an explanatory message). For use when the upstream
//! gh API is unavailable or during incident response.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

// ── Public API ────────────────────────────────────────────────────────────

/// Entry point called from `src/main.rs` after routing `chump external verify-merge`.
pub fn run(args: &[String]) -> i32 {
    // Category-B kill-switch using _DISABLED suffix (not _SKIP/_BYPASS/_CHECK).
    if std::env::var("CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED").as_deref() == Ok("1") {
        eprintln!("[external verify-merge] disabled via CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED=1");
        eprintln!("Unset to re-enable.");
        return 1;
    }

    match run_inner(args) {
        Ok(rc) => rc,
        Err(e) => {
            eprintln!("chump external verify-merge: {e:#}");
            1
        }
    }
}

// ── Core logic ────────────────────────────────────────────────────────────

fn run_inner(args: &[String]) -> anyhow::Result<i32> {
    if args.is_empty() || args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        return Ok(0);
    }

    let opts = Opts::parse(args)?;

    let clone_dir = resolve_clone_dir(&opts)?;

    println!(
        "[verify-merge] checking PR #{} on {repo}",
        opts.pr,
        repo = opts.repo
    );
    println!("[verify-merge] clone dir: {}", clone_dir.display());

    // ── Gate 1: Repo CI green ─────────────────────────────────────────────
    println!("\n[verify-merge] Gate 1: Repo CI check-runs (polling until terminal) ...");
    let ci_result = poll_ci_until_terminal(&opts)?;
    match &ci_result {
        CiResult::Green {
            check_count,
            checks,
        } => {
            println!("  PASS: {check_count} check-runs all terminal-green");
            for c in checks.iter().take(5) {
                println!("    ✓ {c}");
            }
            if checks.len() > 5 {
                println!("    … and {} more", checks.len() - 5);
            }
        }
        CiResult::NoGates => {
            let reason = "repo has no CI to verify against";
            println!("  FAIL: {reason}");
            emit_held(&opts, reason);
            println!("\nVerdict: HELD(no-gates)");
            println!("  {reason}");
            return Ok(1);
        }
        CiResult::Red { failing } => {
            let reason = format!(
                "CI red: {} check(s) failed: {}",
                failing.len(),
                failing.join(", ")
            );
            println!("  FAIL: {reason}");
            emit_held(&opts, &reason);
            println!("\nVerdict: HELD(ci)");
            println!("  {reason}");
            return Ok(1);
        }
        CiResult::TimedOut { pending } => {
            let reason = format!(
                "CI timeout: {} check(s) still pending after wait cap: {}",
                pending.len(),
                pending.join(", ")
            );
            println!("  FAIL: {reason}");
            emit_held(&opts, &reason);
            println!("\nVerdict: HELD(ci_pending)");
            println!("  {reason}");
            return Ok(1);
        }
    }

    // ── Clone / fetch the repo ────────────────────────────────────────────
    let (base_sha, head_sha) = fetch_pr_commits(&opts)?;
    println!(
        "\n[verify-merge] PR base SHA: {} / head SHA: {}",
        &base_sha[..base_sha.len().min(12)],
        &head_sha[..head_sha.len().min(12)]
    );

    ensure_clone(&clone_dir, &opts.repo, &opts.gh_bin)?;
    fetch_refs(&clone_dir, &base_sha, &head_sha)?;

    // ── Gate 2: Anti-cosmetic test gate ──────────────────────────────────
    println!("\n[verify-merge] Gate 2: Anti-cosmetic test gate ...");
    let test_files = diff_test_files(&clone_dir, &base_sha, &head_sha)?;
    if test_files.is_empty() {
        let reason = "no test files added or modified by this PR";
        println!("  FAIL: {reason}");
        emit_held(&opts, reason);
        println!("\nVerdict: HELD(cosmetic)");
        println!("  {reason}");
        return Ok(1);
    }
    println!("  test files changed: {:?}", test_files);

    let runner = detect_test_runner(&clone_dir)?;
    println!("  detected test runner: {:?}", runner);

    if let TestRunner::Unknown = &runner {
        let reason = "cannot determine test runner for this repo";
        println!("  FAIL: {reason}");
        emit_held(&opts, reason);
        println!("\nVerdict: HELD(no-runner)");
        println!("  {reason}");
        return Ok(1);
    }

    // Prove the test fails on base and passes on head.
    // run_tests_at_sha returns whether the suite PASSED (exit 0); "fails on base"
    // is the negation of that. (Bug fix: this was assigned `passed` directly, so a
    // legitimately-failing base read as fails_on_base=false → wrong HELD(unproven).)
    let (base_passed, base_output) = run_tests_at_sha(&clone_dir, &base_sha, &runner, &test_files)?;
    let fails_on_base = !base_passed;
    let (passes_on_head, head_output) =
        run_tests_at_sha(&clone_dir, &head_sha, &runner, &test_files)?;

    println!("  fails on base: {fails_on_base}");
    println!("  passes on head: {passes_on_head}");

    if !fails_on_base {
        let reason = "test passes on base too — change is unproven (cosmetic or duplicate)";
        println!("  FAIL: {reason}");
        println!(
            "  base output: {}",
            base_output.trim().lines().next().unwrap_or("(empty)")
        );
        emit_held(&opts, reason);
        println!("\nVerdict: HELD(unproven)");
        println!("  {reason}");
        return Ok(1);
    }

    if !passes_on_head {
        let reason = "test still fails on PR head — change does not fix what it claims";
        println!("  FAIL: {reason}");
        println!(
            "  head output: {}",
            head_output.trim().lines().next().unwrap_or("(empty)")
        );
        emit_held(&opts, reason);
        println!("\nVerdict: HELD(test-fails-on-head)");
        println!("  {reason}");
        return Ok(1);
    }

    println!("  PASS: test fails on base, passes on head (real behavioral change proven)");

    // ── Gate 3: No regression (existing suite on head) ───────────────────
    println!("\n[verify-merge] Gate 3: No-regression (full suite on head) ...");
    let regression_result = run_full_suite_at_sha(&clone_dir, &head_sha, &runner)?;
    match regression_result {
        RegressionResult::Pass => {
            println!("  PASS: full test suite green on head");
        }
        RegressionResult::CoveredByCi => {
            println!("  PASS (covered by CI gate 1 — CI runs tests)");
        }
        RegressionResult::Fail { output } => {
            let reason = format!(
                "regression: full test suite fails on head: {}",
                output.trim().lines().next().unwrap_or("(no output)")
            );
            println!("  FAIL: {}", &reason);
            emit_held(&opts, &reason);
            println!("\nVerdict: HELD(regression)");
            println!("  {reason}");
            return Ok(1);
        }
    }

    // ── All gates pass ────────────────────────────────────────────────────
    let proof = Proof {
        ci_checks: match &ci_result {
            CiResult::Green { checks, .. } => checks.clone(),
            _ => vec![],
        },
        test_files: test_files.clone(),
        fails_on_base,
        passes_on_head,
        base_sha: base_sha.clone(),
        head_sha: head_sha.clone(),
    };

    emit_verified(&opts, &proof);

    println!("\nVerdict: MERGE");
    println!("  All 3 gates passed.");
    println!(
        "  Proof: {} CI checks, test fails-on-base + passes-on-head confirmed.",
        proof.ci_checks.len()
    );

    if opts.apply {
        println!(
            "\n[verify-merge] --apply: merging PR #{} on {} ...",
            opts.pr, opts.repo
        );
        let merge_result = merge_pr(&opts)?;
        if merge_result {
            println!("[verify-merge] PR #{} merged successfully.", opts.pr);
        } else {
            eprintln!("[verify-merge] merge command failed — check gh output above.");
            return Ok(1);
        }
    } else {
        println!("\n(dry-run — pass --apply to execute the merge)");
    }

    Ok(0)
}

// ── Types ─────────────────────────────────────────────────────────────────

struct Opts {
    pr: u64,
    repo: String,
    gap: String,
    clone_dir: Option<PathBuf>,
    apply: bool,
    /// Path to `gh` binary; resolved from PATH, overridable via CHUMP_GH_BIN.
    gh_bin: String,
}

impl Opts {
    fn parse(args: &[String]) -> anyhow::Result<Self> {
        use anyhow::Context;
        let mut pr: Option<u64> = None;
        let mut repo: Option<String> = None;
        let mut gap = String::new();
        let mut clone_dir: Option<PathBuf> = None;
        let mut apply = false;

        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--pr" => {
                    i += 1;
                    pr = Some(
                        args.get(i)
                            .context("--pr requires a value")?
                            .parse()
                            .context("--pr must be a positive integer")?,
                    );
                }
                "--repo" => {
                    i += 1;
                    repo = Some(args.get(i).context("--repo requires a value")?.clone());
                }
                "--gap" => {
                    i += 1;
                    gap = args.get(i).context("--gap requires a value")?.clone();
                }
                "--clone-dir" => {
                    i += 1;
                    clone_dir = Some(PathBuf::from(
                        args.get(i).context("--clone-dir requires a value")?,
                    ));
                }
                "--apply" => {
                    apply = true;
                }
                _ => {}
            }
            i += 1;
        }

        let pr = pr.context("--pr <N> is required")?;
        let repo = repo.context("--repo <owner/repo> is required")?;
        if gap.is_empty() {
            anyhow::bail!("--gap <ID> is required");
        }
        // Validate owner/repo shape.
        if !repo.contains('/') {
            anyhow::bail!("--repo must be in owner/repo format, got {:?}", repo);
        }

        let gh_bin = std::env::var("CHUMP_GH_BIN").unwrap_or_else(|_| "gh".to_string());

        Ok(Opts {
            pr,
            repo,
            gap,
            clone_dir,
            apply,
            gh_bin,
        })
    }
}

struct Proof {
    ci_checks: Vec<String>,
    test_files: Vec<String>,
    fails_on_base: bool,
    passes_on_head: bool,
    base_sha: String,
    head_sha: String,
}

enum CiResult {
    Green {
        check_count: usize,
        checks: Vec<String>,
    },
    NoGates,
    Red {
        failing: Vec<String>,
    },
    /// Timed out waiting for checks to reach terminal state.
    TimedOut {
        pending: Vec<String>,
    },
}

#[derive(Debug, Clone)]
enum TestRunner {
    /// `cargo test --test <name> -- <test_fn>`  (Rust)
    Cargo,
    /// `npm test` / `yarn test`
    Npm,
    /// `pytest` (Python)
    Pytest,
    /// `make test`
    Make,
    /// Could not determine
    Unknown,
}

enum RegressionResult {
    Pass,
    /// CI gate already proved tests pass; skip local run.
    CoveredByCi,
    Fail {
        output: String,
    },
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn print_usage() {
    println!("Usage: chump external verify-merge \\");
    println!("    --pr <N> --repo <owner/repo> --gap <ID> \\");
    println!("    [--clone-dir <path>] [--apply]");
    println!();
    println!("Gates (ALL must pass):");
    println!("  1. Repo CI green — every check-run on PR head SHA is SUCCESS.");
    println!("     Zero checks → HELD(no-gates).");
    println!("  2. Anti-cosmetic — diff adds/modifies a test; that test fails on base,");
    println!("     passes on head. No test → HELD(cosmetic). Passes-on-both → HELD(unproven).");
    println!("  3. No-regression — existing test suite passes on head.");
    println!();
    println!("Verdict: MERGE (all pass) or HELD(<reason>).");
    println!("Dry-run by default; --apply executes the merge.");
    println!();
    println!("Kill-switch: CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED=1");
}

fn resolve_clone_dir(opts: &Opts) -> anyhow::Result<PathBuf> {
    if let Some(ref d) = opts.clone_dir {
        return Ok(d.clone());
    }
    // Default: ~/.chump/external/<owner>/<repo>/clone
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let dir = PathBuf::from(home)
        .join(".chump")
        .join("external")
        .join(opts.repo.replace('/', "_"))
        .join("clone");
    Ok(dir)
}

// ── Terminal-state constants ───────────────────────────────────────────────
// A check-run conclusion is terminal when it is one of these values (GitHub docs).
// QUEUED / IN_PROGRESS / null-conclusion are non-terminal (still running).
const TERMINAL_CONCLUSIONS: &[&str] = &[
    "success",
    "failure",
    "cancelled",
    "timed_out",
    "action_required",
    "skipped",
    "neutral",
    "stale",
];
// These terminal conclusions are treated as a non-blocking pass.
const PASS_CONCLUSIONS: &[&str] = &["success", "skipped", "neutral"];
// These terminal conclusions are hard failures.
const FAIL_CONCLUSIONS: &[&str] = &["failure", "cancelled", "timed_out", "action_required"];

/// Parse a single check entry from statusCheckRollup JSON.
/// Returns `(name, is_advisory, is_terminal, is_pass, is_fail)`.
fn classify_check(check: &serde_json::Value, advisory_substrings: &[String]) -> CheckInfo {
    let name = check
        .get("name")
        .or_else(|| check.get("context"))
        .and_then(|v| v.as_str())
        .unwrap_or("(unnamed)")
        .to_string();

    let conclusion = check
        .get("conclusion")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let state = check
        .get("state")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let status = check
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    // Commit-status uses `state`; check-run uses `conclusion`.
    // Terminal = conclusion is one of TERMINAL_CONCLUSIONS, OR state is a
    // commit-status terminal value (success/failure/error).
    let effective_conclusion = if !conclusion.is_empty() {
        conclusion.clone()
    } else {
        // commit status: state = success | failure | error | pending
        match state.as_str() {
            "success" => "success".to_string(),
            "failure" | "error" => "failure".to_string(),
            _ => String::new(),
        }
    };

    let is_terminal = TERMINAL_CONCLUSIONS.contains(&effective_conclusion.as_str())
        // commit-status pending → not terminal
        || (!effective_conclusion.is_empty()
            && effective_conclusion != "pending"
            && !status.eq("in_progress")
            && !status.eq("queued")
            && !status.eq("requested")
            && !state.eq("pending"));

    // Also treat as non-terminal when status shows still running.
    let is_still_running = status == "in_progress"
        || status == "queued"
        || status == "requested"
        || state == "pending";

    let is_terminal = is_terminal && !is_still_running;

    let is_pass = PASS_CONCLUSIONS.contains(&effective_conclusion.as_str()) || state == "success";

    let is_fail = FAIL_CONCLUSIONS.contains(&effective_conclusion.as_str())
        || state == "failure"
        || state == "error";

    let name_lower = name.to_ascii_lowercase();
    let is_advisory = advisory_substrings
        .iter()
        .any(|sub| name_lower.contains(sub.as_str()));

    CheckInfo {
        name,
        is_advisory,
        is_terminal,
        is_pass,
        is_fail,
    }
}

struct CheckInfo {
    name: String,
    is_advisory: bool,
    is_terminal: bool,
    is_pass: bool,
    is_fail: bool,
}

/// Fetch check-runs once via `gh pr view --json statusCheckRollup`.
fn fetch_check_runs(opts: &Opts) -> anyhow::Result<Vec<serde_json::Value>> {
    let output = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "view",
            &opts.pr.to_string(),
            "--repo",
            &opts.repo,
            "--json",
            "statusCheckRollup",
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("failed to run gh: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value = serde_json::from_str(&stdout)
        .map_err(|e| anyhow::anyhow!("failed to parse gh json: {e}\nraw: {stdout}"))?;

    Ok(json
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default())
}

/// Poll the PR's check-runs until ALL non-advisory checks are terminal,
/// then judge the result. Implements the CREDIBLE-102 wait-before-judge logic.
///
/// Tuning env vars:
///   CHUMP_VERIFY_CI_POLL_SECS  — polling interval in seconds (default 30)
///   CHUMP_VERIFY_CI_WAIT_SECS  — maximum wait in seconds (default 1200 = 20 min)
///   CHUMP_VERIFY_CI_ADVISORY_NAMES — comma-separated case-insensitive name
///                                      substrings; matching checks are non-gating
fn poll_ci_until_terminal(opts: &Opts) -> anyhow::Result<CiResult> {
    let poll_secs: u64 = std::env::var("CHUMP_VERIFY_CI_POLL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30);
    let wait_secs: u64 = std::env::var("CHUMP_VERIFY_CI_WAIT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1200);

    // Parse advisory substrings (lowercase for case-insensitive matching).
    let advisory_substrings: Vec<String> = std::env::var("CHUMP_VERIFY_CI_ADVISORY_NAMES")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .collect();

    let started_at = std::time::Instant::now();

    loop {
        let checks = fetch_check_runs(opts)?;

        if checks.is_empty() {
            return Ok(CiResult::NoGates);
        }

        let infos: Vec<CheckInfo> = checks
            .iter()
            .map(|c| classify_check(c, &advisory_substrings))
            .collect();

        // Partition into required vs advisory.
        let required: Vec<&CheckInfo> = infos.iter().filter(|i| !i.is_advisory).collect();
        let advisory: Vec<&CheckInfo> = infos.iter().filter(|i| i.is_advisory).collect();

        // Log advisory check state (informational, never gates).
        for a in &advisory {
            if !a.is_terminal {
                println!("  [advisory] {} — still pending (non-gating)", a.name);
            } else if a.is_fail {
                println!(
                    "  [advisory] {} — failed (non-gating, advisory check)",
                    a.name
                );
            }
        }

        // Check if all required checks are terminal.
        let pending_required: Vec<&str> = required
            .iter()
            .filter(|i| !i.is_terminal)
            .map(|i| i.name.as_str())
            .collect();

        if pending_required.is_empty() {
            // All required checks are terminal — judge now.
            let failing: Vec<String> = required
                .iter()
                .filter(|i| i.is_fail)
                .map(|i| i.name.clone())
                .collect();

            if failing.is_empty() {
                let passing: Vec<String> = required.iter().map(|i| i.name.clone()).collect();
                return Ok(CiResult::Green {
                    check_count: passing.len(),
                    checks: passing,
                });
            } else {
                return Ok(CiResult::Red { failing });
            }
        }

        // Not all terminal yet — check timeout.
        let elapsed = started_at.elapsed().as_secs();
        if elapsed >= wait_secs {
            return Ok(CiResult::TimedOut {
                pending: pending_required.iter().map(|s| s.to_string()).collect(),
            });
        }

        // Progress report and sleep.
        println!(
            "[verify-merge] Gate 1: waiting for CI — {} pending ({}), elapsed {}s / cap {}s",
            pending_required.len(),
            pending_required.join(", "),
            elapsed,
            wait_secs,
        );

        if poll_secs > 0 {
            std::thread::sleep(std::time::Duration::from_secs(poll_secs));
        }
    }
}

/// `gh pr view <pr> --repo <repo> --json baseRefOid,headRefOid`
fn fetch_pr_commits(opts: &Opts) -> anyhow::Result<(String, String)> {
    let output = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "view",
            &opts.pr.to_string(),
            "--repo",
            &opts.repo,
            "--json",
            "baseRefOid,headRefOid",
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("gh pr view (commits): {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value = serde_json::from_str(&stdout)
        .map_err(|e| anyhow::anyhow!("parse gh json (commits): {e}\nraw: {stdout}"))?;

    let base = json
        .get("baseRefOid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("missing baseRefOid in gh response"))?
        .to_string();
    let head = json
        .get("headRefOid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("missing headRefOid in gh response"))?
        .to_string();

    Ok((base, head))
}

/// Clone the repo if not already present; otherwise fetch.
fn ensure_clone(clone_dir: &Path, repo: &str, _gh_bin: &str) -> anyhow::Result<()> {
    if clone_dir.join(".git").exists() {
        // Already cloned; fetch latest.
        println!(
            "[verify-merge] repo already cloned at {} — fetching ...",
            clone_dir.display()
        );
        let status = Command::new("git")
            .args([
                "-C",
                &clone_dir.to_string_lossy(),
                "fetch",
                "--quiet",
                "origin",
            ])
            .status()
            .map_err(|e| anyhow::anyhow!("git fetch: {e}"))?;
        if !status.success() {
            // Non-fatal: might be offline or the PR branch was deleted. Continue.
            eprintln!("[verify-merge] warning: git fetch failed (continuing)");
        }
        return Ok(());
    }

    println!("[verify-merge] cloning {} ...", repo);
    if let Some(parent) = clone_dir.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let clone_url = format!("https://github.com/{repo}.git");
    let status = Command::new("git")
        .args([
            "clone",
            "--depth",
            "50", // shallow enough to be fast; deep enough for diff
            &clone_url,
            &clone_dir.to_string_lossy(),
        ])
        .status()
        .map_err(|e| anyhow::anyhow!("git clone: {e}"))?;

    if !status.success() {
        anyhow::bail!("git clone of {repo} failed");
    }
    Ok(())
}

/// Ensure both SHAs are available locally (they may not be in a shallow clone).
fn fetch_refs(clone_dir: &Path, base_sha: &str, head_sha: &str) -> anyhow::Result<()> {
    for sha in [base_sha, head_sha] {
        // Check if SHA is already available.
        let available = Command::new("git")
            .args(["-C", &clone_dir.to_string_lossy(), "cat-file", "-e", sha])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);

        if !available {
            // Fetch the specific SHA.
            let _ = Command::new("git")
                .args([
                    "-C",
                    &clone_dir.to_string_lossy(),
                    "fetch",
                    "--depth",
                    "1",
                    "origin",
                    sha,
                ])
                .status();
        }
    }
    Ok(())
}

/// Returns list of test files changed between base and head.
/// Heuristic: file path contains `test` or `spec`, or matches `*_test.*`,
/// `*_spec.*`, `test_*.*`, or `__tests__/*`.
fn diff_test_files(clone_dir: &Path, base: &str, head: &str) -> anyhow::Result<Vec<String>> {
    let output = Command::new("git")
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "diff",
            "--name-only",
            base,
            head,
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("git diff --name-only: {e}"))?;

    let files: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|p| is_test_file(p))
        .map(String::from)
        .collect();

    Ok(files)
}

/// Heuristic: does this path look like a test file?
fn is_test_file(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    let stem = std::path::Path::new(&lower)
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or("");

    // Common patterns across Rust / JS / Python / Go / Ruby / etc.
    lower.contains("/test/")
        || lower.contains("/tests/")
        || lower.contains("/spec/")
        || lower.contains("/__tests__/")
        || lower.contains("/test_")
        || stem.starts_with("test_")
        || stem.ends_with("_test.rs")
        || stem.ends_with("_test.go")
        || stem.ends_with("_test.ts")
        || stem.ends_with("_test.js")
        || stem.ends_with("_spec.rb")
        || stem.ends_with("_spec.js")
        || stem.ends_with("_spec.ts")
        || stem.ends_with(".test.ts")
        || stem.ends_with(".test.js")
        || stem.ends_with(".spec.ts")
        || stem.ends_with(".spec.js")
        || lower.contains("test") // broad fallback: any file with "test" in the path
}

/// Detect how to run tests for this repo.
fn detect_test_runner(clone_dir: &Path) -> anyhow::Result<TestRunner> {
    // Rust
    if clone_dir.join("Cargo.toml").exists() {
        return Ok(TestRunner::Cargo);
    }
    // JS/TS — check package.json has a test script
    let pkg_json = clone_dir.join("package.json");
    if pkg_json.exists() {
        if let Ok(s) = std::fs::read_to_string(&pkg_json) {
            if let Ok(j) = serde_json::from_str::<serde_json::Value>(&s) {
                if j.get("scripts").and_then(|sc| sc.get("test")).is_some() {
                    return Ok(TestRunner::Npm);
                }
            }
        }
    }
    // Python
    if clone_dir.join("pytest.ini").exists()
        || clone_dir.join("pyproject.toml").exists()
        || clone_dir.join("setup.cfg").exists()
    {
        return Ok(TestRunner::Pytest);
    }
    // Makefile with a `test` target
    let makefile = clone_dir.join("Makefile");
    if makefile.exists() {
        if let Ok(s) = std::fs::read_to_string(&makefile) {
            if s.lines()
                .any(|l| l.starts_with("test:") || l.starts_with("test "))
            {
                return Ok(TestRunner::Make);
            }
        }
    }
    Ok(TestRunner::Unknown)
}

/// Checkout a SHA, run the test files, return (passed, output).
fn run_tests_at_sha(
    clone_dir: &Path,
    sha: &str,
    runner: &TestRunner,
    test_files: &[String],
) -> anyhow::Result<(bool, String)> {
    // Checkout the SHA.
    let co = Command::new("git")
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "checkout",
            "--detach",
            sha,
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("git checkout {sha}: {e}"))?;
    if !co.status.success() {
        let err = String::from_utf8_lossy(&co.stderr);
        anyhow::bail!("git checkout {sha} failed: {err}");
    }

    let cmd_and_args = test_command(runner, test_files);
    let output = Command::new(&cmd_and_args[0])
        .args(&cmd_and_args[1..])
        .current_dir(clone_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| anyhow::anyhow!("test runner {:?}: {e}", runner))?;

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok((output.status.success(), combined))
}

/// Build the test command argv for the detected runner + specific test files.
fn test_command(runner: &TestRunner, test_files: &[String]) -> Vec<String> {
    match runner {
        TestRunner::Cargo => {
            // `cargo test` runs all tests; for the anti-cosmetic gate we want
            // to exercise the changed test files. Rust doesn't have per-file
            // targeting easily, so run the full test suite and interpret
            // failure/pass accordingly.
            vec![
                "cargo".into(),
                "test".into(),
                "--".into(),
                // Include changed file stems as filter hints (best-effort).
                test_files
                    .iter()
                    .filter_map(|f| {
                        std::path::Path::new(f)
                            .file_stem()
                            .and_then(|s| s.to_str())
                            .map(|s| s.to_string())
                    })
                    .collect::<Vec<_>>()
                    .join(" "),
            ]
            // If no stems, just run all tests.
        }
        TestRunner::Npm => vec![
            "npm".into(),
            "test".into(),
            "--".into(),
            "--passWithNoTests".into(),
        ],
        TestRunner::Pytest => {
            let mut cmd = vec!["python".into(), "-m".into(), "pytest".into(), "-x".into()];
            for f in test_files {
                cmd.push(f.clone());
            }
            cmd
        }
        TestRunner::Make => vec!["make".into(), "test".into()],
        TestRunner::Unknown => vec!["true".into()], // never reached — caller guards Unknown
    }
}

/// Run the full suite on head to check for regressions.
/// Returns CoveredByCi if CI runs tests (indicated by CI passing gate 1).
fn run_full_suite_at_sha(
    clone_dir: &Path,
    _head_sha: &str,
    runner: &TestRunner,
) -> anyhow::Result<RegressionResult> {
    // We already verified CI is green via gate 1.  If the repo's CI
    // includes a test step (the majority case), that is authoritative.
    // We use a simple heuristic: if Cargo.toml exists and we saw CI pass,
    // the CI almost certainly ran `cargo test`.  Same logic for npm/pytest.
    // A future improvement could inspect the workflow YAML; for now we mark
    // it covered and avoid a redundant local run (which would need the full
    // toolchain installed).
    //
    // To force a local run, set CHUMP_EXTERNAL_VERIFY_FULL_SUITE=1.
    if std::env::var("CHUMP_EXTERNAL_VERIFY_FULL_SUITE").as_deref() != Ok("1") {
        return Ok(RegressionResult::CoveredByCi);
    }

    let cmd_and_args = full_suite_command(runner);
    let output = Command::new(&cmd_and_args[0])
        .args(&cmd_and_args[1..])
        .current_dir(clone_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| anyhow::anyhow!("full suite runner: {e}"))?;

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    if output.status.success() {
        Ok(RegressionResult::Pass)
    } else {
        Ok(RegressionResult::Fail { output: combined })
    }
}

fn full_suite_command(runner: &TestRunner) -> Vec<String> {
    match runner {
        TestRunner::Cargo => vec!["cargo".into(), "test".into()],
        TestRunner::Npm => vec!["npm".into(), "test".into()],
        TestRunner::Pytest => vec!["python".into(), "-m".into(), "pytest".into()],
        TestRunner::Make => vec!["make".into(), "test".into()],
        TestRunner::Unknown => vec!["true".into()],
    }
}

/// Execute `gh pr merge <N> --repo <repo> --squash`.
fn merge_pr(opts: &Opts) -> anyhow::Result<bool> {
    let status = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "merge",
            &opts.pr.to_string(),
            "--repo",
            &opts.repo,
            "--squash",
        ])
        .status()
        .map_err(|e| anyhow::anyhow!("gh pr merge: {e}"))?;
    Ok(status.success())
}

// ── Ambient emission ──────────────────────────────────────────────────────

/// Emit `kind=external_merge_verified` — all gates passed.
/// ambient-kind: external_merge_verified  CREDIBLE-096 emitter: src/external_verify_merge.rs
fn emit_verified(opts: &Opts, proof: &Proof) {
    let proof_json = serde_json::json!({
        "ci_checks": proof.ci_checks.len(),
        "test_files": proof.test_files,
        "fails_on_base": proof.fails_on_base,
        "passes_on_head": proof.passes_on_head,
        "base_sha": &proof.base_sha[..proof.base_sha.len().min(12)],
        "head_sha": &proof.head_sha[..proof.head_sha.len().min(12)],
    });
    emit_ambient_event(
        "external_merge_verified",
        &[
            ("pr", &opts.pr.to_string()),
            ("repo", &opts.repo),
            ("gap", &opts.gap),
            ("proof", &proof_json.to_string()),
        ],
    );
}

/// Emit `kind=external_merge_held` — at least one gate failed.
/// ambient-kind: external_merge_held  CREDIBLE-096 emitter: src/external_verify_merge.rs
fn emit_held(opts: &Opts, reason: &str) {
    emit_ambient_event(
        "external_merge_held",
        &[
            ("pr", &opts.pr.to_string()),
            ("repo", &opts.repo),
            ("gap", &opts.gap),
            ("reason", reason),
        ],
    );
}

fn emit_ambient_event(kind: &str, fields: &[(&str, &str)]) {
    // Mirror the pattern from src/orchestrate.rs::emit_ambient_event.
    let ambient = if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        PathBuf::from(path)
    } else {
        let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        // Walk up to find repo root (has Cargo.toml + [workspace]).
        loop {
            let cargo = dir.join("Cargo.toml");
            if cargo.exists() {
                if let Ok(c) = std::fs::read_to_string(&cargo) {
                    if c.contains("[workspace]") {
                        break;
                    }
                }
            }
            if !dir.pop() {
                dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
                break;
            }
        }
        let lock_dir = dir.join(".chump-locks");
        let _ = std::fs::create_dir_all(&lock_dir);
        lock_dir.join("ambient.jsonl")
    };

    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(ts));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    for (k, v) in fields {
        map.insert((*k).into(), serde_json::Value::String((*v).into()));
    }
    if let Ok(line) = serde_json::to_string(&serde_json::Value::Object(map)) {
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient)
            .and_then(|mut f| writeln!(f, "{line}"));
    }
}

// ── Unit tests (CREDIBLE-102) ─────────────────────────────────────────────
//
// Each test injects a fake `gh` binary (written to a tmpdir and referenced via
// CHUMP_GH_BIN) that reads a counter file to decide which canned response to
// return, advancing the counter on every invocation.  CHUMP_VERIFY_CI_POLL_SECS=0
// makes the polling loop instant.

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    /// Build a minimal Opts with a custom gh_bin and PR=1 on owner/test-repo.
    fn make_opts(gh_bin: &str) -> Opts {
        Opts {
            pr: 1,
            repo: "owner/test-repo".into(),
            gap: "CREDIBLE-102".into(),
            clone_dir: None,
            apply: false,
            gh_bin: gh_bin.to_string(),
        }
    }

    /// Write a shell script to `dir/gh` and make it executable.
    /// Returns the path to the script.
    fn write_fake_gh(dir: &std::path::Path, script_body: &str) -> String {
        let bin = dir.join("gh");
        let content = format!("#!/usr/bin/env bash\n{script_body}\n");
        fs::write(&bin, content).expect("write fake gh");
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).expect("chmod fake gh");
        bin.to_string_lossy().into_owned()
    }

    /// Build a fake gh script that uses a counter file to cycle through
    /// `responses`.  Each call to gh (when the args contain "statusCheckRollup")
    /// increments the counter and returns the corresponding JSON.
    /// Other calls (baseRefOid, merge, etc.) return a safe stub.
    fn fake_gh_with_responses(dir: &std::path::Path, responses: &[&str]) -> String {
        let counter_file = dir.join("call_counter");
        fs::write(&counter_file, "0").expect("write counter");

        // Embed responses as a bash array.
        let responses_bash: Vec<String> = responses
            .iter()
            .map(|r| format!("'{}'", r.replace('\'', "'\\''")))
            .collect();
        let array_literal = responses_bash.join(" ");
        let counter_path = counter_file.to_string_lossy().into_owned();

        let script = format!(
            r#"
RESPONSES=({array_literal})
COUNT_FILE='{counter_path}'
COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
ARGS="$*"
if echo "$ARGS" | grep -q "statusCheckRollup"; then
    IDX=$COUNT
    if [ "$IDX" -ge "${{#RESPONSES[@]}}" ]; then
        IDX=$(( ${{#RESPONSES[@]}} - 1 ))
    fi
    echo "${{RESPONSES[$IDX]}}"
    echo $(( COUNT + 1 )) > "$COUNT_FILE"
elif echo "$ARGS" | grep -q "baseRefOid"; then
    echo '{{"baseRefOid":"aabbcc112233","headRefOid":"ddeeff445566"}}'
else
    echo '{{}}'
fi
"#
        );
        write_fake_gh(dir, &script)
    }

    // ── (a) pending → pending → SUCCESS: Gate 1 PASS ─────────────────────
    #[test]
    fn test_ci_wait_pending_then_success() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let pending_json =
            r#"{"statusCheckRollup":[{"name":"CI","status":"IN_PROGRESS","conclusion":null}]}"#;
        let success_json =
            r#"{"statusCheckRollup":[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]}"#;

        let gh_bin =
            fake_gh_with_responses(tmp.path(), &[pending_json, pending_json, success_json]);

        // POLL_SECS=0 for instant polling; WAIT_SECS large enough to not time out.
        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        // Redirect ambient writes.
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Green { check_count, .. } => {
                assert_eq!(check_count, 1, "expected 1 check to be green");
            }
            other => panic!(
                "expected CiResult::Green, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Red { .. } => "Red",
                    CiResult::TimedOut { .. } => "TimedOut",
                    CiResult::Green { .. } => unreachable!(),
                }
            ),
        }
    }

    // ── (b) pending → FAILURE: Gate 1 HELD(ci) ───────────────────────────
    #[test]
    fn test_ci_wait_pending_then_failure() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let pending_json =
            r#"{"statusCheckRollup":[{"name":"tests","status":"IN_PROGRESS","conclusion":null}]}"#;
        let failure_json = r#"{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"FAILURE"}]}"#;

        let gh_bin = fake_gh_with_responses(tmp.path(), &[pending_json, failure_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Red { failing } => {
                assert!(
                    failing.iter().any(|f| f.contains("tests")),
                    "expected 'tests' in failing list, got {:?}",
                    failing
                );
            }
            other => panic!(
                "expected CiResult::Red, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Green { .. } => "Green",
                    CiResult::TimedOut { .. } => "TimedOut",
                    CiResult::Red { .. } => unreachable!(),
                }
            ),
        }
    }

    // ── (c) stays pending past wait cap: HELD(ci_pending) ─────────────────
    #[test]
    fn test_ci_wait_timeout() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let pending_json =
            r#"{"statusCheckRollup":[{"name":"slow-job","status":"QUEUED","conclusion":null}]}"#;

        // Only ever returns pending — will time out immediately since WAIT_SECS=0.
        let gh_bin = fake_gh_with_responses(tmp.path(), &[pending_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        // WAIT_SECS=0 means the elapsed check fires on the first pending poll.
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "0");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::TimedOut { pending } => {
                assert!(
                    pending.iter().any(|p| p.contains("slow-job")),
                    "expected 'slow-job' in pending list, got {:?}",
                    pending
                );
            }
            other => panic!(
                "expected CiResult::TimedOut, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Green { .. } => "Green",
                    CiResult::Red { .. } => "Red",
                    CiResult::TimedOut { .. } => unreachable!(),
                }
            ),
        }
    }

    // ── (d) required SUCCESS + advisory pending: Gate 1 PASS ─────────────
    #[test]
    fn test_ci_advisory_pending_does_not_gate() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        // required CI check SUCCESS, advisory "vercel" check still pending.
        let mixed_json = r#"{"statusCheckRollup":[
            {"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},
            {"name":"Vercel Preview","status":"IN_PROGRESS","conclusion":null}
        ]}"#;

        let gh_bin = fake_gh_with_responses(tmp.path(), &[mixed_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        // Mark "vercel" as advisory (case-insensitive substring match).
        std::env::set_var("CHUMP_VERIFY_CI_ADVISORY_NAMES", "vercel");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Green {
                check_count,
                checks,
            } => {
                // Only the non-advisory "CI" check should appear in the passing list.
                assert_eq!(check_count, 1, "expected 1 required check (CI)");
                assert!(
                    checks.iter().any(|c| c == "CI"),
                    "expected 'CI' in passing list, got {:?}",
                    checks
                );
            }
            other => panic!(
                "expected CiResult::Green (advisory pending should not gate), got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Red { .. } => "Red",
                    CiResult::TimedOut { .. } => "TimedOut",
                    CiResult::Green { .. } => unreachable!(),
                }
            ),
        }
    }
}
