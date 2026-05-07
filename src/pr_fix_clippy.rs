//! INFRA-618: `chump pr fix-clippy <PR#>`
//!
//! Auto-fix obvious clippy lints on a PR branch without operator intervention.
//! Targets: manual_split_once, unused_variables, redundant_clone, single_match.
//!
//! Safety gates:
//!   - Refuses if `cargo clippy --fix` touches > MAX_FILES files.
//!   - Refuses if total diff looks non-trivial (> MAX_LINES_PER_FILE lines/file).
//!
//! Testability:
//!   - `CHUMP_GH` env var overrides the `gh` binary path (for mock injection).
//!   - `CHUMP_FIX_CLIPPY_REPO` env var overrides the repo root used for cloning.

use std::path::{Path, PathBuf};
use std::process::Command;

const MAX_FILES: usize = 3;
const MAX_LINES_PER_FILE: usize = 20;

pub struct FixResult {
    pub pr_number: u64,
    pub branch: String,
    pub files_changed: usize,
    pub lines_changed: usize,
    pub dry_run: bool,
}

fn gh_cmd() -> String {
    std::env::var("CHUMP_GH").unwrap_or_else(|_| "gh".to_string())
}

/// Fetch the PR's head branch name via `gh pr view`.
pub fn get_pr_branch(pr_number: u64) -> Result<String, String> {
    let out = Command::new(gh_cmd())
        .args([
            "pr",
            "view",
            &pr_number.to_string(),
            "--json",
            "headRefName",
            "--jq",
            ".headRefName",
        ])
        .output()
        .map_err(|e| format!("gh not found: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "gh pr view failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let branch = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if branch.is_empty() {
        return Err(format!("PR #{pr_number} not found or no head branch"));
    }
    Ok(branch)
}

/// Clone the repo into a temp dir, checkout the branch, run clippy --fix,
/// validate the diff, commit, and force-push back.
pub fn fix_clippy(pr_number: u64, repo_root: &Path, dry_run: bool) -> Result<FixResult, String> {
    let branch = get_pr_branch(pr_number)?;
    eprintln!("chump pr fix-clippy: PR #{pr_number} → branch {branch}");

    // Allow env override for test scenarios.
    let clone_source = std::env::var("CHUMP_FIX_CLIPPY_REPO")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.to_path_buf());

    let work_dir = std::env::temp_dir().join(format!("chump-fix-clippy-{pr_number}"));
    if work_dir.exists() {
        std::fs::remove_dir_all(&work_dir)
            .map_err(|e| format!("failed to remove old work dir: {e}"))?;
    }

    // Clone the repo (local clone is fast — uses hardlinks).
    run(
        Command::new("git")
            .args(["clone", "--local", "--no-hardlinks"])
            .arg(&clone_source)
            .arg(&work_dir),
        "git clone",
    )?;

    // Fetch and checkout the PR branch.
    run(
        Command::new("git")
            .args(["fetch", "origin", &branch])
            .current_dir(&work_dir),
        "git fetch",
    )?;
    run(
        Command::new("git")
            .args(["checkout", &branch])
            .current_dir(&work_dir),
        "git checkout",
    )?;

    // Run cargo clippy --fix for the targeted lint categories.
    let clippy_out = Command::new("cargo")
        .args([
            "clippy",
            "--fix",
            "--allow-dirty",
            "--allow-staged",
            "--",
            "-W",
            "clippy::manual_split_once",
            "-W",
            "clippy::unused_variables",
            "-W",
            "clippy::redundant_clone",
            "-W",
            "clippy::single_match",
        ])
        .current_dir(&work_dir)
        .output()
        .map_err(|e| format!("cargo clippy --fix failed: {e}"))?;
    // clippy --fix exits non-zero when there are unfixable warnings — that's fine;
    // we check the diff, not the exit code.
    if !clippy_out.status.success() {
        eprintln!(
            "chump pr fix-clippy: cargo clippy --fix stderr (informational):\n{}",
            String::from_utf8_lossy(&clippy_out.stderr)
                .lines()
                .take(10)
                .collect::<Vec<_>>()
                .join("\n")
        );
    }

    // Count changed files from `git diff --stat`.
    let stat = run_output(
        Command::new("git")
            .args(["diff", "--stat", "HEAD"])
            .current_dir(&work_dir),
        "git diff --stat",
    )?;

    let files_changed = stat.lines().filter(|l| l.contains('|')).count();

    if files_changed == 0 {
        cleanup(&work_dir);
        return Err(format!(
            "No clippy fixes needed on PR #{pr_number} — branch is already clean."
        ));
    }

    // Safety gate 1: too many files.
    if files_changed > MAX_FILES {
        cleanup(&work_dir);
        return Err(format!(
            "Refusing: clippy --fix would touch {files_changed} files (limit {MAX_FILES}). \
             Manual review required.\n{stat}"
        ));
    }

    // Safety gate 2: diff size heuristic — catch suspiciously large changes.
    let diff_text = run_output(
        Command::new("git")
            .args(["diff", "HEAD"])
            .current_dir(&work_dir),
        "git diff",
    )?;
    let additions = diff_text
        .lines()
        .filter(|l| l.starts_with('+') && !l.starts_with("+++"))
        .count();
    let deletions = diff_text
        .lines()
        .filter(|l| l.starts_with('-') && !l.starts_with("---"))
        .count();
    let lines_changed = additions + deletions;

    if lines_changed > files_changed * MAX_LINES_PER_FILE {
        cleanup(&work_dir);
        return Err(format!(
            "Refusing: diff looks non-trivial ({lines_changed} lines across {files_changed} \
             files, limit {MAX_LINES_PER_FILE}/file). Manual review required."
        ));
    }

    println!("Files to fix ({files_changed}):");
    for l in stat.lines().filter(|l| l.contains('|')) {
        println!("  {l}");
    }

    if dry_run {
        println!(
            "Dry-run: would commit {lines_changed} lines across {files_changed} files \
             and force-push to {branch}."
        );
        cleanup(&work_dir);
        return Ok(FixResult {
            pr_number,
            branch,
            files_changed,
            lines_changed,
            dry_run: true,
        });
    }

    // Stage and commit.
    run(
        Command::new("git")
            .args(["add", "-u"])
            .current_dir(&work_dir),
        "git add -u",
    )?;
    let commit_msg = format!("chore: auto-fix clippy lints (INFRA-618)\n\nPR #{pr_number} — {lines_changed} lines across {files_changed} files.");
    run(
        Command::new("git")
            .args(["commit", "-m", &commit_msg])
            .current_dir(&work_dir),
        "git commit",
    )?;

    // Force-push back to the PR branch on origin.
    run(
        Command::new("git")
            .args([
                "push",
                "--force-with-lease",
                "origin",
                &format!("HEAD:{branch}"),
            ])
            .current_dir(&work_dir),
        "git push",
    )?;

    println!("✓ Pushed clippy fixes to {branch} ({files_changed} files, {lines_changed} lines).");
    cleanup(&work_dir);

    Ok(FixResult {
        pr_number,
        branch,
        files_changed,
        lines_changed,
        dry_run: false,
    })
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn run(cmd: &mut Command, label: &str) -> Result<(), String> {
    let out = cmd
        .output()
        .map_err(|e| format!("{label} failed to spawn: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{label} failed (exit {}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

fn run_output(cmd: &mut Command, label: &str) -> Result<String, String> {
    let out = cmd
        .output()
        .map_err(|e| format!("{label} failed to spawn: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{label} failed (exit {}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

fn cleanup(dir: &Path) {
    let _ = std::fs::remove_dir_all(dir);
}
