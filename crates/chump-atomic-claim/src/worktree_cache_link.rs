//! INFRA-1733: symlink `.chump/github_cache.db` from a freshly-created
//! worktree back to the main checkout's cache instead of letting each
//! worktree start with a cold, empty cache.
//!
//! `chump claim` creates one linked worktree per gap under
//! `${CHUMP_WORKTREE_BASE:-/tmp}/chump-<gap>`. Any process that opens
//! `.chump/github_cache.db` there (rusqlite `CREATE TABLE IF NOT EXISTS`,
//! or a bare `sqlite3` invocation) will happily create a brand-new, empty
//! database file rather than erroring — so the loss of hit rate is silent.
//! Symlinking the worktree's cache path back to the main checkout's cache
//! means every worktree reads (and writes) the same webhook-fed cache.
//!
//! Fail-open: if the main checkout has no cache yet, an empty file is
//! created in its place (not a broken symlink) so downstream `sqlite3
//! .chump/github_cache.db` calls still work — they'll just be cache misses
//! until the webhook receiver populates the main checkout's cache.

use std::path::{Path, PathBuf};

/// Link (or, failing that, create) `<worktree_path>/.chump/github_cache.db`.
///
/// `repo_root`     — main checkout root (source of the shared cache)
/// `worktree_path` — the new worktree directory (destination)
///
/// Never panics; any I/O failure is logged and swallowed so the claim
/// proceeds regardless.
pub fn link_worktree_github_cache(repo_root: &Path, worktree_path: &Path) {
    let worktree_chump_dir = worktree_path.join(".chump");
    if let Err(e) = std::fs::create_dir_all(&worktree_chump_dir) {
        eprintln!(
            "[claim] worktree-cache-link: cannot create {}: {e}",
            worktree_chump_dir.display()
        );
        return;
    }

    let link_path = worktree_chump_dir.join("github_cache.db");
    // Idempotent: `chump claim --resume` can re-enter an existing worktree.
    if link_path.exists() || link_path.is_symlink() {
        return;
    }

    let main_cache = repo_root.join(".chump").join("github_cache.db");
    if !main_cache.exists() {
        if let Err(e) = std::fs::File::create(&link_path) {
            eprintln!(
                "[claim] worktree-cache-link: cannot create fallback {}: {e}",
                link_path.display()
            );
        } else {
            eprintln!(
                "[claim] WARN worktree-cache-link: main checkout has no {} yet — \
                 created an empty cache in the worktree instead of a symlink",
                main_cache.display()
            );
        }
        return;
    }

    let relative_target =
        relative_path(&worktree_chump_dir, &repo_root.join(".chump")).join("github_cache.db");

    #[cfg(unix)]
    {
        if let Err(e) = std::os::unix::fs::symlink(&relative_target, &link_path) {
            eprintln!(
                "[claim] worktree-cache-link: symlink {} -> {} failed: {e}",
                link_path.display(),
                relative_target.display()
            );
        }
    }
}

/// Build the relative path from `from_dir` to `to_dir`. On Unix, absolute
/// paths always share at least the root component, so this normally returns
/// a genuinely relative (if occasionally long) path; the `to_dir` fallback
/// only fires for non-absolute inputs that share no prefix at all.
fn relative_path(from_dir: &Path, to_dir: &Path) -> PathBuf {
    let from_components: Vec<_> = from_dir.components().collect();
    let to_components: Vec<_> = to_dir.components().collect();

    let common_len = from_components
        .iter()
        .zip(to_components.iter())
        .take_while(|(a, b)| a == b)
        .count();

    if common_len == 0 {
        return to_dir.to_path_buf();
    }

    let mut result = PathBuf::new();
    for _ in common_len..from_components.len() {
        result.push("..");
    }
    for component in &to_components[common_len..] {
        result.push(component.as_os_str());
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_path_sibling_worktree() {
        // Default `${CHUMP_WORKTREE_BASE:-/tmp}/chump-<gap>` layout: the
        // worktree's `.chump` and the main checkout's `.chump` are both
        // direct children of `/tmp`, two levels up from the symlink's own
        // directory.
        let from = Path::new("/tmp/chump-infra-1733/.chump");
        let to = Path::new("/tmp/.chump");
        assert_eq!(relative_path(from, to), PathBuf::from("../../.chump"));
    }

    #[test]
    fn relative_path_unrelated_trees_still_relative() {
        // Absolute unix paths always share at least the root component, so
        // this still produces a working (if longer) relative path rather
        // than falling back to an absolute one.
        let from = Path::new("/tmp/chump-infra-1733/.chump");
        let to = Path::new("/home/jeff/Projects/chump/.chump");
        assert_eq!(
            relative_path(from, to),
            PathBuf::from("../../../home/jeff/Projects/chump/.chump")
        );
    }

    #[test]
    fn links_when_main_cache_present() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().join("main");
        let worktree_path = tmp.path().join("chump-infra-1733");
        std::fs::create_dir_all(repo_root.join(".chump")).unwrap();
        std::fs::write(repo_root.join(".chump/github_cache.db"), b"sqlite").unwrap();
        std::fs::create_dir_all(&worktree_path).unwrap();

        link_worktree_github_cache(&repo_root, &worktree_path);

        let link_path = worktree_path.join(".chump/github_cache.db");
        let meta = std::fs::symlink_metadata(&link_path).unwrap();
        assert!(meta.file_type().is_symlink());
        // Follows through to the real content.
        assert_eq!(std::fs::read(&link_path).unwrap(), b"sqlite");
    }

    #[test]
    fn creates_empty_file_when_main_cache_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().join("main");
        let worktree_path = tmp.path().join("chump-infra-1733");
        std::fs::create_dir_all(&repo_root).unwrap();
        std::fs::create_dir_all(&worktree_path).unwrap();

        link_worktree_github_cache(&repo_root, &worktree_path);

        let link_path = worktree_path.join(".chump/github_cache.db");
        let meta = std::fs::symlink_metadata(&link_path).unwrap();
        assert!(!meta.file_type().is_symlink());
        assert!(meta.is_file());
    }
}
