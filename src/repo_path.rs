//! Resolve paths relative to CHUMP_REPO or CHUMP_HOME or cwd; validate no escape.
//! When CHUMP_MULTI_REPO_ENABLED=1, set_working_repo() can override repo root for the session.

use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;

static WORKING_REPO_OVERRIDE: std::sync::OnceLock<Mutex<Option<PathBuf>>> =
    std::sync::OnceLock::new();

fn working_repo_override_cell() -> &'static Mutex<Option<PathBuf>> {
    WORKING_REPO_OVERRIDE.get_or_init(|| Mutex::new(None))
}

/// Set process-scoped working repo override (for multi-repo mode). Path must be a directory
/// with a `.git` subdirectory. Cleared on close_session().
pub fn set_working_repo(path: PathBuf) -> Result<(), String> {
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
        Ok(())
    } else {
        Err("could not set working repo (lock)".to_string())
    }
}

/// Clear the working repo override. Called from close_session().
pub fn clear_working_repo() {
    if let Ok(mut guard) = working_repo_override_cell().lock() {
        *guard = None;
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
