//! Periodic `gap_prs` merged-PR reconciler inside `chumpd` (`CREDIBLE-1550`, `ZERO-WASTE-056`).
//!
//! When `chump ship` (`ManualShipPath` / `BotMergePath`) opens a PR, it records a
//! typed `(gap_id, pr_number, head_sha)` link in `<repo>/.chump/state.db` (`gap_prs`)
//! and arms GitHub auto-merge. Once GitHub squash-merges the PR and the local
//! webhook cache (`<repo>/.chump/github_cache.db`) observes `merged_at IS NOT NULL`,
//! this background organ invokes `chump gap reconcile-merged` to route each
//! merged link through the single receipt-gated `GapStore::ship` path.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

/// Default periodic reconciliation cadence (3 minutes).
pub const DEFAULT_MERGED_PR_RECONCILE_INTERVAL_SECS: u64 = 180;

/// Resolve the sibling `chump` CLI binary adjacent to `current_exe`, falling back to `"chump"`.
pub fn resolve_sibling_chump_bin(current_exe: Option<&Path>) -> PathBuf {
    let bin_name = if cfg!(windows) { "chump.exe" } else { "chump" };
    if let Some(exe) = current_exe {
        if let Some(parent) = exe.parent() {
            let candidate = parent.join(bin_name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    PathBuf::from(bin_name)
}

/// Return true only when both canonical `state.db` and webhook `github_cache.db` exist
/// and no `.noncanonical` / `NONCANONICAL` / `CHUMP_STORE_ARCHIVED` marker is present.
pub fn should_run_reconciler(repo_root: &Path) -> bool {
    let chump_dir = repo_root.join(".chump");
    if !chump_dir.join("state.db").is_file() || !chump_dir.join("github_cache.db").is_file() {
        return false;
    }
    for marker in [".noncanonical", "NONCANONICAL", "CHUMP_STORE_ARCHIVED"] {
        if chump_dir.join(marker).exists() {
            return false;
        }
    }
    true
}

/// Execute one `chump gap reconcile-merged` pass if preconditions hold.
pub fn run_once(repo_root: &Path) -> bool {
    if !should_run_reconciler(repo_root) {
        return false;
    }
    let cur = std::env::current_exe().ok();
    let chump_bin = resolve_sibling_chump_bin(cur.as_deref());
    Command::new(chump_bin)
        .current_dir(repo_root)
        .args(["gap", "reconcile-merged"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Spawn the periodic background merged-PR reconciler inside `chumpd`.
pub fn spawn_background_reconciler(repo_root: PathBuf, interval_secs: u64) {
    let cadence = interval_secs.max(30);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(15)).await;
        loop {
            let repo = repo_root.clone();
            let _ = tokio::task::spawn_blocking(move || run_once(&repo)).await;
            tokio::time::sleep(Duration::from_secs(cadence)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn resolves_sibling_chump_when_present_else_path_fallback() {
        let tmp = TempDir::new().unwrap();
        let bin_name = if cfg!(windows) { "chump.exe" } else { "chump" };
        let chumpd_name = if cfg!(windows) {
            "chumpd.exe"
        } else {
            "chumpd"
        };
        let fake_chumpd = tmp.path().join(chumpd_name);
        fs::write(&fake_chumpd, b"stub").unwrap();

        // Without sibling chump -> falls back to bare binary name.
        assert_eq!(
            resolve_sibling_chump_bin(Some(&fake_chumpd)),
            PathBuf::from(bin_name)
        );

        // With sibling chump -> resolves sibling path.
        let sibling = tmp.path().join(bin_name);
        fs::write(&sibling, b"stub").unwrap();
        assert_eq!(resolve_sibling_chump_bin(Some(&fake_chumpd)), sibling);
    }

    #[test]
    fn preconditions_require_both_dbs_and_reject_noncanonical_markers() {
        let tmp = TempDir::new().unwrap();
        let chump_dir = tmp.path().join(".chump");
        fs::create_dir_all(&chump_dir).unwrap();

        assert!(!should_run_reconciler(tmp.path()));
        fs::write(chump_dir.join("state.db"), b"sqlite").unwrap();
        assert!(!should_run_reconciler(tmp.path()));
        fs::write(chump_dir.join("github_cache.db"), b"sqlite").unwrap();
        assert!(should_run_reconciler(tmp.path()));

        let marker = chump_dir.join("NONCANONICAL");
        fs::write(&marker, b"1").unwrap();
        assert!(!should_run_reconciler(tmp.path()));
        fs::remove_file(&marker).unwrap();
        assert!(should_run_reconciler(tmp.path()));
    }
}
