use std::path::{Path, PathBuf};
use tempfile::TempDir;

const ISOLATION_VARS: &[&str] = &[
    "CHUMP_HOME",
    "CHUMP_REPO",
    "CHUMP_REPO_ROOT",
    "CHUMP_STATE_DB",
    "CHUMP_LOCK_DIR",
];

/// RAII sandbox: creates a `TempDir`, points every CHUMP isolation env var at
/// it, and restores the previous values (or unsets them) on drop.
///
/// CRITICAL (INFRA-2080 class): [`ISOLATION_VARS`] is the single source of
/// truth for "which env vars must be set to fully isolate a test from the
/// real `.chump/state.db`". Add a new var here once; every caller inherits
/// the fix.
///
/// Mutates process-wide env state — tests using this MUST be annotated
/// `#[serial]` (the same convention already used across this codebase for
/// env-mutating tests, e.g. `src/doctor.rs::repo_env_missing_is_warn_not_fail`).
pub struct TestSandbox {
    dir: TempDir,
    prev: Vec<(&'static str, Option<String>)>,
}

impl TestSandbox {
    /// Create a new sandbox, exporting the isolation env vars to point at it.
    pub fn new() -> std::io::Result<Self> {
        let dir = TempDir::new()?;
        std::fs::create_dir_all(dir.path().join(".chump"))?;
        std::fs::create_dir_all(dir.path().join(".chump-locks"))?;

        let prev: Vec<(&'static str, Option<String>)> = ISOLATION_VARS
            .iter()
            .map(|name| (*name, std::env::var(name).ok()))
            .collect();

        let root = dir.path().to_string_lossy().to_string();
        std::env::set_var("CHUMP_HOME", &root);
        std::env::set_var("CHUMP_REPO", &root);
        std::env::set_var("CHUMP_REPO_ROOT", &root);
        std::env::set_var("CHUMP_STATE_DB", dir.path().join(".chump").join("state.db"));
        std::env::set_var("CHUMP_LOCK_DIR", dir.path().join(".chump-locks"));

        Ok(Self { dir, prev })
    }

    /// Path to the sandbox root.
    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// Path to the sandbox's state.db (may not exist until something writes it).
    pub fn state_db_path(&self) -> PathBuf {
        self.dir.path().join(".chump").join("state.db")
    }
}

impl Drop for TestSandbox {
    fn drop(&mut self) {
        for (name, value) in &self.prev {
            match value {
                Some(v) => std::env::set_var(name, v),
                None => std::env::remove_var(name),
            }
        }
        // `self.dir` (TempDir) removes the directory tree on its own drop.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn sandbox_exports_all_isolation_vars() {
        let sandbox = TestSandbox::new().unwrap();
        for name in ISOLATION_VARS {
            let v = std::env::var(name).unwrap();
            assert!(
                v.starts_with(sandbox.path().to_string_lossy().as_ref())
                    || v == sandbox.path().to_string_lossy(),
                "{name} should be rooted at the sandbox dir, got {v}"
            );
        }
    }

    #[test]
    #[serial]
    fn sandbox_restores_previous_env_on_drop() {
        std::env::set_var("CHUMP_HOME", "/was/here/before");
        std::env::remove_var("CHUMP_REPO");
        {
            let _sandbox = TestSandbox::new().unwrap();
            assert_ne!(std::env::var("CHUMP_HOME").unwrap(), "/was/here/before");
        }
        assert_eq!(std::env::var("CHUMP_HOME").unwrap(), "/was/here/before");
        assert!(std::env::var("CHUMP_REPO").is_err());
        std::env::remove_var("CHUMP_HOME");
    }

    #[test]
    #[serial]
    fn sandbox_dir_removed_after_drop() {
        let path = {
            let sandbox = TestSandbox::new().unwrap();
            sandbox.path().to_path_buf()
        };
        assert!(!path.exists());
    }
}
