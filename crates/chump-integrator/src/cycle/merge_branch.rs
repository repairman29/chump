//! # cycle::merge_branch — INFRA-2172 / C2b
//!
//! Git fetch + `merge --no-ff` per candidate, with Batched-Under trailer.
//!
//! ## Per-candidate steps
//!
//! 1. `git fetch origin chump/<gap-branch>`
//! 2. `git merge --no-ff origin/chump/<gap-branch> -m "Batched: <gap-id> — <gap-title>" --no-edit`
//! 3. Amend the merge commit to add trailers:
//!    - `Batched-Under: <branch-name>`
//!    - `Co-Authored-By: <original author>` (if known)
//!
//! ## Conflict handling
//!
//! On any merge conflict, the cycle **aborts immediately** (no auto-resolve).
//! The function calls `git merge --abort`, emits
//! `kind=integration_merge_conflict`, and returns `Err`. Partial merges
//! already applied in this cycle are left on the integration branch for the
//! caller to reset.
//!
//! ## Cross-references
//!
//! - INFRA-2172 — this gap's AC
//! - INFRA-2130 — parent C2 (lifecycle skeleton)
//! - INFRA-2135 — Batched-Under trailer spec

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::process::Command;

use super::GapCandidate;

/// Result of building one integration branch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntegrationBranchOutcome {
    /// Gaps successfully merged into the integration branch.
    pub merged_gaps: Vec<MergedGap>,
    /// Gaps that caused a conflict (at most one — we abort on first conflict).
    pub conflicts: Vec<ConflictRecord>,
}

/// Metadata for one successfully merged gap.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MergedGap {
    pub gap_id: String,
    /// HEAD SHA before this merge.
    pub parent_sha: String,
    /// Merge commit SHA.
    pub merge_sha: String,
}

/// Record of a conflict that aborted the cycle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConflictRecord {
    pub gap_id: String,
    /// Files reported as conflicted by `git diff --name-only --diff-filter=U`.
    pub conflicted_files: Vec<String>,
}

/// Build an integration branch by merging each candidate in order.
///
/// Runs in `repo_root`; caller is responsible for checking out the integration
/// branch before calling this function.
///
/// Returns `Ok(outcome)` even if some gaps were skipped due to conflict — the
/// `conflicts` field will be non-empty and `merged_gaps` will contain only
/// the gaps merged before the conflict.
pub async fn build_integration_branch(
    candidates: &[GapCandidate],
    branch_name: &str,
    repo_root: &Path,
) -> Result<IntegrationBranchOutcome> {
    let mut merged_gaps: Vec<MergedGap> = Vec::new();
    let mut conflicts: Vec<ConflictRecord> = Vec::new();

    for candidate in candidates {
        let remote_ref = format!("origin/{}", candidate.branch);

        // 1. Fetch the candidate branch.
        let fetch_status = Command::new("git")
            .args(["fetch", "origin", &candidate.branch])
            .current_dir(repo_root)
            .status()
            .await
            .with_context(|| format!("git fetch failed for {}", candidate.gap_id))?;

        if !fetch_status.success() {
            bail!(
                "git fetch origin {} failed (exit {})",
                candidate.branch,
                fetch_status
            );
        }

        // 2. Record pre-merge HEAD.
        let parent_sha = git_rev_parse("HEAD", repo_root).await?;

        // 3. Attempt merge --no-ff.
        let commit_msg = format!("Batched: {} — {}", candidate.gap_id, candidate.title);
        let merge_status = Command::new("git")
            .args([
                "merge",
                "--no-ff",
                "--no-edit",
                "-m",
                &commit_msg,
                &remote_ref,
            ])
            .current_dir(repo_root)
            .status()
            .await
            .with_context(|| format!("git merge failed for {}", candidate.gap_id))?;

        if !merge_status.success() {
            // Conflict — collect conflicted files then abort.
            let conflicted_files = list_conflicted_files(repo_root).await.unwrap_or_default();

            let _ = Command::new("git")
                .args(["merge", "--abort"])
                .current_dir(repo_root)
                .status()
                .await;

            conflicts.push(ConflictRecord {
                gap_id: candidate.gap_id.clone(),
                conflicted_files,
            });

            // Abort the whole cycle on first conflict.
            return Ok(IntegrationBranchOutcome {
                merged_gaps,
                conflicts,
            });
        }

        // 4. Amend commit to add trailers.
        let merge_sha_pre_amend = git_rev_parse("HEAD", repo_root).await?;
        let mut trailer_args = vec![
            "commit".to_string(),
            "--amend".to_string(),
            "--no-edit".to_string(),
            "--trailer".to_string(),
            format!("Batched-Under: {}", branch_name),
        ];
        if let Some(author) = &candidate.author {
            trailer_args.push("--trailer".to_string());
            trailer_args.push(format!("Co-Authored-By: {}", author));
        }

        let amend_status = Command::new("git")
            .args(&trailer_args)
            .current_dir(repo_root)
            .status()
            .await
            .with_context(|| {
                format!("git commit --amend trailer failed for {}", candidate.gap_id)
            })?;

        if !amend_status.success() {
            bail!(
                "git commit --amend failed for {} (pre-amend sha={})",
                candidate.gap_id,
                merge_sha_pre_amend
            );
        }

        let merge_sha = git_rev_parse("HEAD", repo_root).await?;
        merged_gaps.push(MergedGap {
            gap_id: candidate.gap_id.clone(),
            parent_sha,
            merge_sha,
        });
    }

    Ok(IntegrationBranchOutcome {
        merged_gaps,
        conflicts,
    })
}

// ─── helpers ─────────────────────────────────────────────────────────────────

async fn git_rev_parse(refname: &str, repo_root: &Path) -> Result<String> {
    let out = Command::new("git")
        .args(["rev-parse", refname])
        .current_dir(repo_root)
        .output()
        .await
        .with_context(|| format!("git rev-parse {refname} failed"))?;
    if !out.status.success() {
        bail!("git rev-parse {refname} returned non-zero");
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

async fn list_conflicted_files(repo_root: &Path) -> Result<Vec<String>> {
    let out = Command::new("git")
        .args(["diff", "--name-only", "--diff-filter=U"])
        .current_dir(repo_root)
        .output()
        .await?;
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_string)
        .collect())
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Stdio;
    use tempfile::TempDir;

    async fn init_repo_with_commits() -> (TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_path_buf();

        // Initialise a bare repo with an initial commit.
        for args in [
            vec!["init"],
            vec!["config", "user.email", "test@test.com"],
            vec!["config", "user.name", "Test"],
        ] {
            tokio::process::Command::new("git")
                .args(&args)
                .current_dir(&path)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await
                .unwrap();
        }

        // Create initial commit on main.
        tokio::fs::write(path.join("README.md"), "# test\n")
            .await
            .unwrap();
        for args in [vec!["add", "README.md"], vec!["commit", "-m", "init"]] {
            tokio::process::Command::new("git")
                .args(&args)
                .current_dir(&path)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await
                .unwrap();
        }

        (dir, path)
    }

    /// Create a branch off HEAD, add a file, commit it, return to previous branch.
    async fn create_side_branch(repo: &Path, branch: &str, filename: &str, content: &str) {
        // Determine current branch name.
        let head = tokio::process::Command::new("git")
            .args(["rev-parse", "--abbrev-ref", "HEAD"])
            .current_dir(repo)
            .output()
            .await
            .unwrap();
        let orig_branch = String::from_utf8_lossy(&head.stdout).trim().to_string();

        for args in [vec!["checkout", "-b", branch]] {
            tokio::process::Command::new("git")
                .args(&args)
                .current_dir(repo)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await
                .unwrap();
        }
        tokio::fs::write(repo.join(filename), content)
            .await
            .unwrap();
        for args in [
            vec!["add", filename],
            vec!["commit", "-m", &format!("add {}", filename)],
        ] {
            tokio::process::Command::new("git")
                .args(&args)
                .current_dir(repo)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await
                .unwrap();
        }

        // Return to original branch.
        tokio::process::Command::new("git")
            .args(["checkout", &orig_branch])
            .current_dir(repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
    }

    fn make_candidate(gap_id: &str, branch: &str, author: Option<&str>) -> GapCandidate {
        GapCandidate {
            gap_id: gap_id.to_string(),
            title: format!("Gap {}", gap_id),
            priority: "P1".to_string(),
            ready_at: chrono::Utc::now().to_rfc3339(),
            queue_age_s: 100,
            estimated_loc: 50,
            branch: branch.to_string(),
            author: author.map(str::to_string),
        }
    }

    #[tokio::test]
    async fn test_clean_merge_succeeds() {
        let (_dir, repo) = init_repo_with_commits().await;

        // Create a side branch that adds a new file (no conflict).
        create_side_branch(&repo, "chump/infra-0001", "feature_a.rs", "// feature a\n").await;

        // Create integration branch.
        tokio::process::Command::new("git")
            .args(["checkout", "-b", "integration/test-001"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();

        // Fake "origin" by adding local as remote pointing to itself.
        tokio::process::Command::new("git")
            .args(["remote", "add", "origin", repo.to_str().unwrap()])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();

        let candidate =
            make_candidate("INFRA-0001", "chump/infra-0001", Some("Dev <dev@test.com>"));
        let outcome = build_integration_branch(&[candidate], "integration/test-001", &repo)
            .await
            .unwrap();

        assert_eq!(outcome.merged_gaps.len(), 1);
        assert!(outcome.conflicts.is_empty());
        assert_eq!(outcome.merged_gaps[0].gap_id, "INFRA-0001");
        assert_ne!(
            outcome.merged_gaps[0].parent_sha,
            outcome.merged_gaps[0].merge_sha
        );
    }

    #[tokio::test]
    async fn test_batched_under_trailer_present() {
        let (_dir, repo) = init_repo_with_commits().await;
        create_side_branch(&repo, "chump/infra-0002", "feature_b.rs", "// feature b\n").await;

        tokio::process::Command::new("git")
            .args(["checkout", "-b", "integration/test-002"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
        tokio::process::Command::new("git")
            .args(["remote", "add", "origin", repo.to_str().unwrap()])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();

        let candidate = make_candidate("INFRA-0002", "chump/infra-0002", None);
        build_integration_branch(&[candidate], "integration/test-002", &repo)
            .await
            .unwrap();

        // Inspect the last commit message for the Batched-Under trailer.
        let log = tokio::process::Command::new("git")
            .args(["log", "-1", "--format=%B"])
            .current_dir(&repo)
            .output()
            .await
            .unwrap();
        let msg = String::from_utf8_lossy(&log.stdout);
        assert!(
            msg.contains("Batched-Under: integration/test-002"),
            "expected Batched-Under trailer in commit message, got: {msg}"
        );
    }

    #[tokio::test]
    async fn test_co_authored_by_preserved() {
        let (_dir, repo) = init_repo_with_commits().await;
        create_side_branch(&repo, "chump/infra-0003", "feature_c.rs", "// feature c\n").await;

        tokio::process::Command::new("git")
            .args(["checkout", "-b", "integration/test-003"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
        tokio::process::Command::new("git")
            .args(["remote", "add", "origin", repo.to_str().unwrap()])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();

        let candidate = make_candidate(
            "INFRA-0003",
            "chump/infra-0003",
            Some("Alice <alice@test.com>"),
        );
        build_integration_branch(&[candidate], "integration/test-003", &repo)
            .await
            .unwrap();

        let log = tokio::process::Command::new("git")
            .args(["log", "-1", "--format=%B"])
            .current_dir(&repo)
            .output()
            .await
            .unwrap();
        let msg = String::from_utf8_lossy(&log.stdout);
        assert!(
            msg.contains("Co-Authored-By: Alice <alice@test.com>"),
            "expected Co-Authored-By trailer, got: {msg}"
        );
    }

    #[tokio::test]
    async fn test_conflict_aborts_with_structured_error() {
        let (_dir, repo) = init_repo_with_commits().await;

        // Both branches edit the same line in README.md → guaranteed conflict.
        // Branch A.
        tokio::process::Command::new("git")
            .args(["checkout", "-b", "chump/infra-0004a"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
        tokio::fs::write(repo.join("README.md"), "# branch-a\n")
            .await
            .unwrap();
        for args in [
            vec!["add", "README.md"],
            vec!["commit", "-m", "a"],
        ] {
            tokio::process::Command::new("git")
                .args(&args)
                .current_dir(&repo)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await
                .unwrap();
        }
        // Branch B (off main, not off A).
        tokio::process::Command::new("git")
            .args(["checkout", "main"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
        tokio::process::Command::new("git")
            .args(["checkout", "-b", "chump/infra-0004b"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
        tokio::fs::write(repo.join("README.md"), "# branch-b\n")
            .await
            .unwrap();
        for args in [vec!["add", "README.md"], vec!["commit", "-m", "b"]] {
            tokio::process::Command::new("git")
                .args(&args)
                .current_dir(&repo)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await
                .unwrap();
        }

        // Integration branch off main.
        tokio::process::Command::new("git")
            .args(["checkout", "main"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
        tokio::process::Command::new("git")
            .args(["checkout", "-b", "integration/test-004"])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();
        tokio::process::Command::new("git")
            .args(["remote", "add", "origin", repo.to_str().unwrap()])
            .current_dir(&repo)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .unwrap();

        let candidates = vec![
            make_candidate("INFRA-0004A", "chump/infra-0004a", None),
            make_candidate("INFRA-0004B", "chump/infra-0004b", None),
        ];
        let outcome = build_integration_branch(&candidates, "integration/test-004", &repo)
            .await
            .unwrap();

        // First merge (A) should succeed; second (B) should conflict.
        assert_eq!(
            outcome.merged_gaps.len(),
            1,
            "first merge should have succeeded"
        );
        assert_eq!(
            outcome.conflicts.len(),
            1,
            "second merge should have conflicted"
        );
        assert_eq!(outcome.conflicts[0].gap_id, "INFRA-0004B");
    }
}
