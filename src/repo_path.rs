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

    #[test]
    #[serial_test::serial]
    fn repo_profiles_list_parses_git_root() {
        let dir =
            std::env::temp_dir().join(format!("chump-repo-prof-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let st = Command::new("git")
            .args(["init"])
            .current_dir(&dir)
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
}
