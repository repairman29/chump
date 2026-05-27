//! Worktree management for the Rust worker (INFRA-2002).
//!
//! ## Design note: subprocess to `git`, not `git2`
//!
//! Original scope-doc favored `git2::Worktree` for "env-immunity". Phase 1
//! ships with `tokio::process::Command` invoking the `git` CLI because:
//!
//! 1. Adding `git2` pulls in libgit2 + libssh2 + openssl C deps, blowing the
//!    chump-coord build budget and the 60s preflight target.
//! 2. The env-immunity concern that motivated INFRA-1997 (chump-git-hooks)
//!    was about HOOKS running outside the harness PATH — the worker runs
//!    inside the harness, so PATH is fine.
//! 3. Explicit absolute paths (worktree dir + branch name) are sufficient
//!    to neutralize the `linked worktree gitdir confusion` class (INFRA-779);
//!    we set `cwd` explicitly on every Command invocation.
//!
//! A follow-up gap can migrate to `git2` once that crate is justified for
//! other callers in chump-coord. Phase 1 keeps the diff small.
//!
//! ## Phase 1 surface
//!
//! - [`create_worktree`] — `git worktree add -B <branch> <path> origin/main`
//! - [`remove_worktree`] — `git worktree remove --force <path>`
//! - [`worktree_dir_for`] — canonical `/tmp/chump-<gap-id>` path scheme
//!
//! Errors are returned as `anyhow::Error` so callers can decide whether to
//! emit `worker_stuck` (existing registered kind, reason=`worktree_create_fail`)
//! and skip the cycle.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use tokio::process::Command;

/// Canonical worktree directory for a gap.
///
/// Mirrors `scripts/dispatch/worker.sh`'s scheme: `/tmp/chump-<lowercased-gap-id>`.
/// Lower-cased to match the bash side so the parallel-run window doesn't
/// produce two worktrees for the same gap.
pub fn worktree_dir_for(gap_id: &str) -> PathBuf {
    PathBuf::from("/tmp").join(format!("chump-{}", gap_id.to_lowercase()))
}

/// Create a linked worktree at `dest` for `gap_id`, branching from origin/main.
///
/// The branch name is `chump/<lowercased-gap-id>-claim` — matches existing
/// claim-branch naming so bot-merge.sh recognizes it.
///
/// Idempotent: if `dest` already exists and is a valid worktree, returns Ok.
pub async fn create_worktree(repo_root: &Path, gap_id: &str, dest: &Path) -> Result<()> {
    if dest.join(".git").exists() {
        // Already a worktree (file or dir form). Treat as success — the
        // caller is mid-cycle reusing a prior claim's tree.
        return Ok(());
    }
    if dest.exists() {
        bail!(
            "worktree path {} exists but is not a git worktree",
            dest.display()
        );
    }
    let branch = format!("chump/{}-claim", gap_id.to_lowercase());
    let status = Command::new("git")
        .current_dir(repo_root)
        .args([
            "worktree",
            "add",
            "-B",
            &branch,
            dest.to_str()
                .context("worktree dest path is not valid UTF-8")?,
            "origin/main",
        ])
        .status()
        .await
        .context("spawning `git worktree add`")?;
    if !status.success() {
        bail!(
            "`git worktree add` exited non-zero (code={:?}) for gap {}",
            status.code(),
            gap_id
        );
    }
    Ok(())
}

/// Remove a worktree at `path` (`git worktree remove --force`).
///
/// Returns Ok even if the path is gone — best-effort cleanup. Returns Err
/// only if the `git` invocation itself fails.
pub async fn remove_worktree(repo_root: &Path, path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let path_str = path
        .to_str()
        .context("worktree remove path is not valid UTF-8")?;
    let status = Command::new("git")
        .current_dir(repo_root)
        .args(["worktree", "remove", "--force", path_str])
        .status()
        .await
        .context("spawning `git worktree remove`")?;
    // Don't fail hard — `worktree remove` can return non-zero if the dir
    // was already pruned by a sibling. Caller treats this as best-effort.
    let _ = status;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worktree_dir_scheme_is_lowercase() {
        let p = worktree_dir_for("INFRA-2002");
        assert_eq!(p, PathBuf::from("/tmp/chump-infra-2002"));
    }

    #[test]
    fn worktree_dir_handles_mixed_case_domain() {
        let p = worktree_dir_for("Meta-107");
        assert_eq!(p, PathBuf::from("/tmp/chump-meta-107"));
    }
}
