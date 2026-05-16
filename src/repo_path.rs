//! Resolve paths relative to CHUMP_REPO or CHUMP_HOME or cwd; validate no escape.
//! When CHUMP_MULTI_REPO_ENABLED=1, set_working_repo() can override repo root for the session.

use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;

static WORKING_REPO_OVERRIDE: std::sync::OnceLock<Mutex<Option<PathBuf>>> =
    std::sync::OnceLock::new();

static WORKING_PROFILE_NAME: std::sync::OnceLock<Mutex<Option<String>>> =
    std::sync::OnceLock::new();

fn working_repo_override_cell() -> &'static Mutex<Option<PathBuf>> {
    WORKING_REPO_OVERRIDE.get_or_init(|| Mutex::new(None))
}

fn working_profile_name_cell() -> &'static Mutex<Option<String>> {
    WORKING_PROFILE_NAME.get_or_init(|| Mutex::new(None))
}

fn set_working_repo_impl(path: PathBuf, profile_label: Option<String>) -> Result<(), String> {
    let canonical = path
        .canonicalize()
        .map_err(|e| format!("path not found or not accessible: {}", e))?;
    if !canonical.is_dir() {
        return Err("path is not a directory".to_string());
    }
    if !canonical.join(".git").exists() {
        return Err("path is not a git repo (no .git)".to_string());
    }
    if let Ok(mut guard) = working_repo_override_cell().lock() {
        *guard = Some(canonical);
    } else {
        return Err("could not set working repo (lock)".to_string());
    }
    if let Ok(mut pg) = working_profile_name_cell().lock() {
        *pg = profile_label;
    }
    Ok(())
}

/// Set process-scoped working repo override (for multi-repo mode). Path must be a directory
/// with a `.git` subdirectory. Cleared on close_session().
pub fn set_working_repo(path: PathBuf) -> Result<(), String> {
    set_working_repo_impl(path, None)
}

/// Set working repo from a **`CHUMP_REPO_PROFILES`** entry (`name=/abs/path`).
pub fn set_working_repo_from_profile(profile_key: &str) -> Result<(), String> {
    let key = profile_key.trim();
    if key.is_empty() {
        return Err("profile name is empty".to_string());
    }
    let path = resolve_profile_repo_path(key)?;
    set_working_repo_impl(path, Some(key.to_string()))
}

/// When the working override was last set via profile (not raw path), the profile key.
pub fn active_working_profile_name() -> Option<String> {
    working_profile_name_cell()
        .lock()
        .ok()
        .and_then(|g| (*g).clone())
}

/// Comma-separated `name=/abs/path` pairs from **`CHUMP_REPO_PROFILES`**. Invalid segments are skipped.
pub fn repo_profiles_list() -> Vec<(String, String)> {
    let raw = std::env::var("CHUMP_REPO_PROFILES")
        .ok()
        .unwrap_or_default();
    if raw.trim().is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for part in raw.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let Some((name, path)) = part.split_once('=') else {
            eprintln!(
                "CHUMP_REPO_PROFILES: skipped segment (expected name=/path): {}",
                part
            );
            continue;
        };
        let name = name.trim();
        if name.is_empty() {
            continue;
        }
        let path = path.trim();
        if path.is_empty() {
            continue;
        }
        let pb = PathBuf::from(path);
        let Ok(canon) = pb.canonicalize() else {
            eprintln!(
                "CHUMP_REPO_PROFILES: skipped `{}` (path not found): {}",
                name, path
            );
            continue;
        };
        if !canon.join(".git").is_dir() {
            eprintln!(
                "CHUMP_REPO_PROFILES: skipped `{}` (not a git repo root): {}",
                name,
                canon.display()
            );
            continue;
        }
        out.push((name.to_string(), canon.display().to_string()));
    }
    out
}

fn resolve_profile_repo_path(profile_key: &str) -> Result<PathBuf, String> {
    let key = profile_key.trim();
    for (n, p) in repo_profiles_list() {
        if n == key {
            return Ok(PathBuf::from(p));
        }
    }
    Err(format!(
        "unknown repo profile `{key}` (not listed in CHUMP_REPO_PROFILES)"
    ))
}

/// One line for the system prompt when multi-repo, profiles, or an override applies.
pub fn active_tool_repo_context_line() -> Option<String> {
    let profiles = repo_profiles_list();
    let multi = crate::set_working_repo_tool::set_working_repo_enabled();
    let show = multi || has_working_repo_override() || !profiles.is_empty();
    if !show {
        return None;
    }
    let root = repo_root();
    let mut s = format!("Tool repo root (file/git tools): {}", root.display());
    if let Some(ref name) = active_working_profile_name() {
        s.push_str(" · Active profile: ");
        s.push_str(name);
    } else if has_working_repo_override() {
        s.push_str(" · Working override (path, not a named profile)");
    }
    Some(s)
}

/// Clear the working repo override. Called from close_session().
pub fn clear_working_repo() {
    if let Ok(mut guard) = working_repo_override_cell().lock() {
        *guard = None;
    }
    if let Ok(mut pg) = working_profile_name_cell().lock() {
        *pg = None;
    }
}

/// True when a working repo override is set (multi-repo mode).
pub fn has_working_repo_override() -> bool {
    working_repo_override_cell()
        .lock()
        .ok()
        .map(|g| g.is_some())
        .unwrap_or(false)
}

/// Base directory for runtime files (sessions, logs). Use this so paths work when the process
/// is started with a different CWD (e.g. ChumpMenu). Prefer CHUMP_HOME/CHUMP_REPO so the repo
/// root is used; create_dir_all the subpaths as needed.
pub fn runtime_base() -> PathBuf {
    std::env::var("CHUMP_HOME")
        .or_else(|_| std::env::var("CHUMP_REPO"))
        .ok()
        .map(|p| PathBuf::from(p.trim().to_string()))
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

/// Base directory for repo-scoped tools: override if set (multi-repo), else CHUMP_REPO, or CHUMP_HOME, or current dir.
pub fn repo_root() -> PathBuf {
    if let Ok(guard) = working_repo_override_cell().lock() {
        if let Some(ref p) = *guard {
            if p.is_dir() {
                return p.clone();
            }
        }
    }
    std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .ok()
        .map(|p| PathBuf::from(p.trim().to_string()))
        .filter(|p| p.is_dir())
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

/// Returns the main repository root (the checkout that owns the shared `.git`
/// directory), which differs from `repo_root()` when running from a linked
/// worktree.  Useful for locating fleet-wide shared state such as
/// `.chump-locks/` and `ambient.jsonl` that live only in the main checkout.
///
/// Algorithm: run `git rev-parse --git-common-dir` from the current
/// `repo_root()`.  For both the main checkout and linked worktrees, this
/// returns the same shared `.git` directory — its parent is always the main
/// checkout root.  Falls back to `repo_root()` if the git invocation fails.
pub fn main_checkout_root() -> PathBuf {
    let rr = repo_root();
    if let Some(common) = git_common_dir(&rr) {
        // For the main checkout:    common = <root>/.git          → parent = <root>
        // For a linked worktree:    common = <root>/.git  (abs.)  → parent = <root>
        // Edge: nested .git (rare but possible) — parent still resolves correctly.
        if let Some(parent) = common.parent() {
            let candidate = parent.to_path_buf();
            if candidate.is_dir() {
                return candidate;
            }
        }
    }
    rr
}

/// Returns the canonical path to the shared git common dir for `repo` (the `.git`
/// directory shared across all linked worktrees). Returns `None` if `repo` is not
/// inside a git tree or if the git invocation fails.
fn git_common_dir(repo: &Path) -> Option<PathBuf> {
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--git-common-dir"])
        .current_dir(repo)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        return None;
    }
    let p = PathBuf::from(&s);
    // --git-common-dir may return a relative path; resolve from repo dir.
    if p.is_absolute() {
        p.canonicalize().ok()
    } else {
        repo.join(p).canonicalize().ok()
    }
}

/// INFRA-969 corruption guard. `git rev-parse --show-toplevel` honours
/// `core.worktree` in `.git/config`. A stale `core.worktree` setting (set
/// by a long-gone linked worktree, or a manual `git -c` invocation that
/// leaked) makes git return a path that has no ancestor relationship to
/// the CWD. Blindly trusting it routes every per-file YAML write to the
/// ghost path. Observed today: cwd=/Users/jeffadkins/Projects/Chump,
/// toplevel=/private/tmp/chump-infra-508 → 1,200+ YAMLs misrouted.
///
/// Sanity rule: a legitimate toplevel either contains CWD (CWD is in a
/// subdirectory of the repo) or equals CWD (CWD is the repo root).
/// If neither holds, fall through to repo_root() instead of trusting git.
fn cwd_is_ancestor_or_equal_of_toplevel(cwd: &Path, toplevel: &Path) -> bool {
    // Canonicalize both — necessary on macOS where /tmp ↔ /private/tmp
    // and on systems with symlinked checkouts. Canonicalize is the only
    // way to reliably compare paths that may share a prefix lexically
    // (e.g. /Users vs /private/Users on some macOS setups).
    let cwd_c = match cwd.canonicalize() {
        Ok(p) => p,
        Err(_) => return false, // can't verify; treat as corrupted, fall through
    };
    let top_c = match toplevel.canonicalize() {
        Ok(p) => p,
        Err(_) => return false,
    };
    cwd_c == top_c || cwd_c.starts_with(&top_c)
}

/// Worktree root for per-worktree write paths (per-file `docs/gaps/<ID>.yaml`,
/// `.chump/.last-yaml-op` freshness marker).
///
/// INFRA-247: `repo_root()` resolves to `CHUMP_REPO` / `CHUMP_HOME` (typically the
/// **main checkout** because the .env in the main checkout sets those) — fine for
/// shared state like `.chump/state.db`, but wrong for per-file YAMLs which must
/// land in the operator's branch (i.e. the *linked worktree* they're cd'd into).
///
/// INFRA-474: when `CHUMP_REPO`/`CHUMP_HOME` is explicitly set for **hermetic
/// isolation** (a script points Chump at a completely separate repo), the CWD's
/// git root may belong to a different git repository — in that case using it
/// would leak writes into the wrong tree. We detect this by comparing the git
/// common-dir of both paths: if they differ, the CWD is in an unrelated repo and
/// `repo_root()` (= `CHUMP_REPO`) is the correct write target.
///
/// Resolution order (first non-empty wins):
///   1. `CHUMP_WORKTREE_ROOT` — explicit override (tests, scripts that cd around).
///   2. `git rev-parse --show-toplevel` from CWD — but only when `CHUMP_REPO` is
///      unset, OR when the CWD and `CHUMP_REPO` share the same git common-dir
///      (i.e. the CWD is a linked worktree of the same repo). This resolves a
///      linked worktree to itself rather than to the main checkout.
///   3. Falls back to `repo_root()` when CWD isn't a git repo, or when CWD belongs
///      to a different repo than `CHUMP_REPO` (hermetic isolation case).
///
/// Always falls back gracefully — never panics. The git invocations are O(1)
/// fork+exec calls per `chump gap` command.
pub fn worktree_root() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_WORKTREE_ROOT") {
        let p = p.trim();
        if !p.is_empty() {
            let pb = PathBuf::from(p);
            if pb.is_dir() {
                return pb;
            }
        }
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if let Ok(out) = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(&cwd)
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() {
                let pb = PathBuf::from(s);
                if pb.is_dir() && cwd_is_ancestor_or_equal_of_toplevel(&cwd, &pb) {
                    // INFRA-474: if CHUMP_REPO/CHUMP_HOME is explicitly set,
                    // confirm the CWD's git repo is the *same* repo (possibly a
                    // linked worktree). If they share the same git common-dir,
                    // use the CWD's root (correct linked-worktree behaviour).
                    // If they differ, the CWD is in an unrelated repo; fall
                    // through to repo_root() so writes land in CHUMP_REPO.
                    let explicit_repo = std::env::var("CHUMP_REPO")
                        .or_else(|_| std::env::var("CHUMP_HOME"))
                        .ok()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .map(PathBuf::from)
                        .filter(|p| p.is_dir());
                    if let Some(ref er) = explicit_repo {
                        let same_repo = git_common_dir(&pb)
                            .zip(git_common_dir(er))
                            .map(|(a, b)| a == b)
                            .unwrap_or(false);
                        if same_repo {
                            return pb;
                        }
                        // Different repo — CHUMP_REPO wins; fall through.
                    } else {
                        return pb;
                    }
                }
            }
        }
    }
    // INFRA-1064: before trusting repo_root(), check if CWD itself is a linked
    // worktree root that belongs to the same repo. When INFRA-779 gitdir
    // back-reference corruption makes `git rev-parse --show-toplevel` return a
    // sibling path, `cwd_is_ancestor_or_equal_of_toplevel` correctly rejects it,
    // but repo_root() can still return that sibling via CHUMP_REPO. A linked
    // worktree root always has a `.git` file (never a directory), so we use that
    // as a lightweight proof that CWD is the worktree root. If CWD's git
    // common-dir matches repo_root()'s, CWD is a valid worktree of the same repo.
    let rr = repo_root();
    if cwd.join(".git").is_file() {
        let cwd_common = git_common_dir(&cwd);
        let rr_common = git_common_dir(&rr);
        if cwd_common.is_some() && cwd_common == rr_common {
            return cwd;
        }
    }
    rr
}

/// Normalize path: remove . and .. components so we can check it stays under root.
fn normalize_relative(path: &str) -> Result<PathBuf, String> {
    let p = Path::new(path.trim());
    if p.is_absolute() {
        return Err("path must be relative".to_string());
    }
    let mut buf = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => return Err("path must not contain ..".to_string()),
            Component::CurDir => {}
            other => buf.push(other),
        }
    }
    Ok(buf)
}

/// Resolve path relative to repo root. Returns canonical path if it is under root; else Err.
/// Path must exist (for read/list). Rejects ".." escape.
pub fn resolve_under_root(path: &str) -> Result<PathBuf, String> {
    let path = path.trim();
    if path.is_empty() {
        return Err("path is empty".to_string());
    }
    let normalized = normalize_relative(path)?;
    let root = repo_root();
    let root_canonical = root.canonicalize().map_err(|e| {
        format!(
            "repo root not accessible: {} (CHUMP_REPO/CHUMP_HOME or cwd: {:?})",
            e, root
        )
    })?;
    let joined = root_canonical.join(&normalized);
    let canonical = joined.canonicalize().map_err(|e| {
        format!(
            "path not found or not accessible: {} — tried {:?} (repo root: {:?})",
            e, joined, root_canonical
        )
    })?;
    if !canonical.starts_with(&root_canonical) {
        return Err("path must be under repo root".to_string());
    }
    Ok(canonical)
}

/// Resolve path for write: file may not exist yet. Same guard (under root, no ..).
pub fn resolve_under_root_for_write(path: &str) -> Result<PathBuf, String> {
    let path = path.trim();
    if path.is_empty() {
        return Err("path is empty".to_string());
    }
    let normalized = normalize_relative(path)?;
    let root = repo_root();
    let root_canonical = root
        .canonicalize()
        .map_err(|e| format!("repo root not accessible: {}", e))?;
    let full = root_canonical.join(&normalized);
    if !full.starts_with(&root_canonical) {
        return Err("path must be under repo root".to_string());
    }
    Ok(full)
}

/// True when CHUMP_REPO or CHUMP_HOME is set (writes allowed only in that case).
pub fn repo_root_is_explicit() -> bool {
    std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .ok()
        .map(|p| !p.trim().is_empty())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    /// INFRA-474: when CHUMP_REPO points to repo A and the process CWD is inside
    /// repo B (a completely different git tree), worktree_root() must return repo A
    /// (via repo_root()), not repo B's root.
    #[test]
    #[serial_test::serial]
    fn worktree_root_respects_chump_repo_across_different_git_trees() {
        let tmp = std::env::temp_dir();
        let repo_a = tmp.join(format!("chump-474-a-{}", uuid::Uuid::new_v4().simple()));
        let repo_b = tmp.join(format!("chump-474-b-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&repo_a).unwrap();
        std::fs::create_dir_all(&repo_b).unwrap();
        for r in [&repo_a, &repo_b] {
            // INFRA-1057: clear inherited git env so init targets the tempdir.
            assert!(Command::new("git")
                .args(["init"])
                .current_dir(r)
                .env_remove("GIT_DIR")
                .env_remove("GIT_WORK_TREE")
                .env_remove("GIT_COMMON_DIR")
                .env_remove("GIT_INDEX_FILE")
                .status()
                .expect("git")
                .success());
        }

        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_wt = std::env::var("CHUMP_WORKTREE_ROOT").ok();
        // Point CHUMP_REPO at repo_a; process is running from repo_b's tree.
        std::env::set_var("CHUMP_REPO", repo_a.display().to_string());
        std::env::remove_var("CHUMP_HOME");
        std::env::remove_var("CHUMP_WORKTREE_ROOT");
        // Change CWD to repo_b so git rev-parse returns repo_b.
        let orig_cwd = std::env::current_dir().ok();
        std::env::set_current_dir(&repo_b).unwrap();

        let result = worktree_root();
        let canon_a = repo_a.canonicalize().unwrap();
        assert_eq!(
            result.canonicalize().unwrap_or(result.clone()),
            canon_a,
            "worktree_root() should return CHUMP_REPO (repo_a) when CWD is in a different git tree (repo_b)"
        );

        // Restore env and cwd.
        if let Some(ref cwd) = orig_cwd {
            let _ = std::env::set_current_dir(cwd);
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        match prev_home {
            Some(ref s) => std::env::set_var("CHUMP_HOME", s),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_wt {
            Some(ref s) => std::env::set_var("CHUMP_WORKTREE_ROOT", s),
            None => std::env::remove_var("CHUMP_WORKTREE_ROOT"),
        }
        let _ = std::fs::remove_dir_all(&repo_a);
        let _ = std::fs::remove_dir_all(&repo_b);
    }

    #[test]
    #[serial_test::serial]
    fn repo_profiles_list_parses_git_root() {
        let dir =
            std::env::temp_dir().join(format!("chump-repo-prof-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let st = Command::new("git")
            .args(["init"])
            .current_dir(&dir)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .status()
            .expect("git exists for test");
        assert!(st.success(), "git init");
        let prev = std::env::var("CHUMP_REPO_PROFILES").ok();
        std::env::set_var("CHUMP_REPO_PROFILES", format!("fixture={}", dir.display()));
        let list = repo_profiles_list();
        match prev {
            Some(ref s) => std::env::set_var("CHUMP_REPO_PROFILES", s),
            None => std::env::remove_var("CHUMP_REPO_PROFILES"),
        }
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].0, "fixture");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial_test::serial]
    fn set_working_repo_from_profile_roundtrip() {
        let dir = std::env::temp_dir().join(format!(
            "chump-repo-prof2-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).expect("mkdir");
        assert!(Command::new("git")
            .args(["init"])
            .current_dir(&dir)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .status()
            .expect("git")
            .success());
        let prev = std::env::var("CHUMP_REPO_PROFILES").ok();
        std::env::set_var("CHUMP_REPO_PROFILES", format!("myrepo={}", dir.display()));
        let prev_multi = std::env::var("CHUMP_MULTI_REPO_ENABLED").ok();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_MULTI_REPO_ENABLED", "1");
        std::env::set_var("CHUMP_REPO", dir.display().to_string());
        clear_working_repo();
        set_working_repo_from_profile("myrepo").expect("set profile");
        assert_eq!(active_working_profile_name().as_deref(), Some("myrepo"));
        assert_eq!(repo_root(), dir.canonicalize().unwrap());
        clear_working_repo();
        assert!(active_working_profile_name().is_none());
        match prev {
            Some(ref s) => std::env::set_var("CHUMP_REPO_PROFILES", s),
            None => std::env::remove_var("CHUMP_REPO_PROFILES"),
        }
        match prev_multi {
            Some(ref s) => std::env::set_var("CHUMP_MULTI_REPO_ENABLED", s),
            None => std::env::remove_var("CHUMP_MULTI_REPO_ENABLED"),
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// INFRA-969 corruption guard. If a repo's .git/config has a stale
    /// `core.worktree` setting pointing at a path that no longer relates
    /// to CWD, `git rev-parse --show-toplevel` returns the ghost path.
    /// worktree_root() must NOT trust that — it should fall through to
    /// repo_root() instead of misrouting every per-file YAML write.
    #[test]
    #[serial_test::serial]
    fn worktree_root_rejects_corrupted_core_worktree() {
        let tmp = std::env::temp_dir();
        let real_repo = tmp.join(format!("chump-969-real-{}", uuid::Uuid::new_v4().simple()));
        let ghost = tmp.join(format!("chump-969-ghost-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&real_repo).unwrap();
        std::fs::create_dir_all(&ghost).unwrap();
        // INFRA-1057: clear inherited git env vars for all fixture git commands.
        assert!(Command::new("git")
            .args(["init"])
            .current_dir(&real_repo)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .status()
            .expect("git")
            .success());

        // Corrupt: point core.worktree at the ghost dir which has no
        // ancestor relationship to real_repo.
        assert!(Command::new("git")
            .args([
                "-C",
                &real_repo.display().to_string(),
                "config",
                "core.worktree",
                &ghost.display().to_string()
            ])
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .status()
            .expect("git")
            .success());

        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_wt = std::env::var("CHUMP_WORKTREE_ROOT").ok();
        std::env::set_var("CHUMP_REPO", real_repo.display().to_string());
        std::env::remove_var("CHUMP_HOME");
        std::env::remove_var("CHUMP_WORKTREE_ROOT");

        let orig_cwd = std::env::current_dir().ok();
        std::env::set_current_dir(&real_repo).unwrap();

        // git rev-parse --show-toplevel from real_repo now returns ghost
        // (because of the corrupted core.worktree). worktree_root() must
        // detect this and fall through to repo_root() = real_repo.
        let result = worktree_root();
        let canon_real = real_repo.canonicalize().unwrap();
        let result_canon = result.canonicalize().unwrap_or(result.clone());
        assert_eq!(
            result_canon, canon_real,
            "worktree_root() returned {result_canon:?} but real_repo is {canon_real:?} — \
             corrupted core.worktree should NOT route writes to the ghost path"
        );

        // Restore env and cwd.
        if let Some(ref cwd) = orig_cwd {
            let _ = std::env::set_current_dir(cwd);
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        match prev_home {
            Some(ref s) => std::env::set_var("CHUMP_HOME", s),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_wt {
            Some(ref s) => std::env::set_var("CHUMP_WORKTREE_ROOT", s),
            None => std::env::remove_var("CHUMP_WORKTREE_ROOT"),
        }
        let _ = std::fs::remove_dir_all(&real_repo);
        let _ = std::fs::remove_dir_all(&ghost);
    }

    /// INFRA-1064: When CHUMP_REPO points at a sibling linked worktree (wt_b) but
    /// the process CWD is a different linked worktree of the same repo (wt_a), and
    /// INFRA-779 corruption makes git rev-parse --show-toplevel return wt_b's path,
    /// worktree_root() must detect that CWD has a .git file (= wt root), confirm
    /// the same git common-dir, and return CWD rather than CHUMP_REPO's path.
    ///
    /// Without corruption git already handles this via the INFRA-474 path; this
    /// test validates the end-to-end contract (correct worktree wins) whether the
    /// fix fires via INFRA-474 or INFRA-1064 code paths.
    #[test]
    #[serial_test::serial]
    fn worktree_root_cwd_wins_over_sibling_chump_repo() {
        let tmp = std::env::temp_dir();
        let main_repo = tmp.join(format!("chump-1064-main-{}", uuid::Uuid::new_v4().simple()));
        let wt_a = tmp.join(format!("chump-1064-wt-a-{}", uuid::Uuid::new_v4().simple()));
        let wt_b = tmp.join(format!("chump-1064-wt-b-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&main_repo).unwrap();
        // Helper: build a git Command with all GIT env vars cleared so the
        // pre-push hook's inherited GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/
        // GIT_INDEX_FILE doesn't bleed into the subprocess (INFRA-1372, AC-1).
        macro_rules! git_cmd {
            () => {
                Command::new("git")
                    .env_remove("GIT_DIR")
                    .env_remove("GIT_WORK_TREE")
                    .env_remove("GIT_COMMON_DIR")
                    .env_remove("GIT_INDEX_FILE")
            };
        }
        // git init + initial commit (needed for worktree add).
        assert!(git_cmd!()
            .args(["init"])
            .current_dir(&main_repo)
            .status()
            .expect("git")
            .success());
        // Configure identity so commit works in any CI environment.
        for (k, v) in [("user.email", "test@test.local"), ("user.name", "Test")] {
            assert!(git_cmd!()
                .args(["-C", &main_repo.display().to_string(), "config", k, v])
                .status()
                .expect("git")
                .success());
        }
        assert!(git_cmd!()
            .args(["commit", "--allow-empty", "-m", "init"])
            .current_dir(&main_repo)
            .status()
            .expect("git")
            .success());
        // Add two linked worktrees.
        assert!(git_cmd!()
            .args(["worktree", "add", "--detach", &wt_a.display().to_string()])
            .current_dir(&main_repo)
            .status()
            .expect("git")
            .success());
        assert!(git_cmd!()
            .args(["worktree", "add", "--detach", &wt_b.display().to_string()])
            .current_dir(&main_repo)
            .status()
            .expect("git")
            .success());

        // Sanity: wt_a and wt_b have .git files (linked worktree markers).
        assert!(
            wt_a.join(".git").is_file(),
            "wt_a should have a .git file (linked worktree)"
        );
        assert!(
            wt_b.join(".git").is_file(),
            "wt_b should have a .git file (linked worktree)"
        );

        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_wt = std::env::var("CHUMP_WORKTREE_ROOT").ok();
        // Simulate INFRA-1064: CHUMP_REPO points at wt_b (sibling).
        std::env::set_var("CHUMP_REPO", wt_b.display().to_string());
        std::env::remove_var("CHUMP_HOME");
        std::env::remove_var("CHUMP_WORKTREE_ROOT");
        let orig_cwd = std::env::current_dir().ok();
        // CWD is wt_a — the operator's actual worktree.
        std::env::set_current_dir(&wt_a).unwrap();

        let result = worktree_root();
        let canon_a = wt_a.canonicalize().unwrap();
        let result_canon = result.canonicalize().unwrap_or(result.clone());
        assert_eq!(
            result_canon, canon_a,
            "worktree_root() should return CWD (wt_a={canon_a:?}) when CHUMP_REPO points at sibling wt_b; got {result_canon:?}"
        );

        // Restore.
        if let Some(ref cwd) = orig_cwd {
            let _ = std::env::set_current_dir(cwd);
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        match prev_home {
            Some(ref s) => std::env::set_var("CHUMP_HOME", s),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_wt {
            Some(ref s) => std::env::set_var("CHUMP_WORKTREE_ROOT", s),
            None => std::env::remove_var("CHUMP_WORKTREE_ROOT"),
        }
        // Prune worktrees before removing dirs (also clears GIT env vars — INFRA-1372).
        let _ = git_cmd!()
            .args(["worktree", "prune"])
            .current_dir(&main_repo)
            .status();
        let _ = std::fs::remove_dir_all(&wt_a);
        let _ = std::fs::remove_dir_all(&wt_b);
        let _ = std::fs::remove_dir_all(&main_repo);
    }
}
