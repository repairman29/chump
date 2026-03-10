//! Resolve paths relative to CHUMP_REPO or CHUMP_HOME or cwd; validate no escape.

use std::path::{Component, Path, PathBuf};

/// Base directory for repo-scoped tools: CHUMP_REPO, or CHUMP_HOME, or current dir.
pub fn repo_root() -> PathBuf {
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
    let root_canonical = root
        .canonicalize()
        .map_err(|e| format!("repo root not accessible: {}", e))?;
    let joined = root_canonical.join(&normalized);
    let canonical = joined
        .canonicalize()
        .map_err(|e| format!("path not found or not accessible: {}", e))?;
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
