//! `TestSandbox` — the Rust equivalent of
//! `scripts/coord/lib/test-sandbox.sh`'s `chump_test_sandbox_setup` /
//! `chump_test_sandbox_cleanup` (INFRA-2088).
//!
//! A `TestSandbox` owns a fresh [`tempfile::TempDir`] and sets the full set
//! of env vars a `chump` invocation reads to locate its state — the same
//! list the shell primitive exports. When a `TestSandbox` is dropped, the
//! env vars are restored to whatever they were before `setup()` (not just
//! unset — a test that runs inside a session that legitimately had
//! `CHUMP_HOME` set gets that value back, not a missing var).
//!
//! Single source of truth: when `chump` grows a new env var that must be
//! set to fully isolate a test from the real `.chump/state.db`, add it to
//! [`ISOLATION_VARS`] once — every caller of `TestSandbox::setup()`
//! inherits the fix.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// The env vars that must be set for a `chump` invocation to be fully
/// isolated from the real repo's state.db, leases, and ambient stream.
/// Mirrors `chump_test_sandbox_env_vars()` in
/// `scripts/coord/lib/test-sandbox.sh` — keep the two lists in sync.
pub const ISOLATION_VARS: &[&str] = &[
    "CHUMP_HOME",
    "CHUMP_REPO",
    "CHUMP_REPO_ROOT",
    "CHUMP_STATE_DB",
    "CHUMP_LOCK_DIR",
];

/// An isolated sandbox directory with `.chump/` and `.chump-locks/`
/// created, and [`ISOLATION_VARS`] pointed at it for the lifetime of this
/// value.
///
/// # Thread safety
///
/// Like the rest of the codebase's `std::env::set_var` test patterns (see
/// `src/plugin.rs`, `src/doctor.rs`), this mutates process-global env vars.
/// Tests that use `TestSandbox` must not run concurrently with other tests
/// that read/write the same vars in the same process — run them
/// `#[serial]` or accept `cargo test -- --test-threads=1` for that module,
/// same discipline the existing `CHUMP_HOME`-mutating tests already need.
pub struct TestSandbox {
    dir: tempfile::TempDir,
    prev_env: HashMap<&'static str, Option<String>>,
}

impl TestSandbox {
    /// Create a fresh sandbox dir (with `.chump/` and `.chump-locks/`
    /// subdirs) and export [`ISOLATION_VARS`] to point at it, saving prior
    /// values so [`TestSandbox::drop`] can restore them.
    pub fn setup() -> std::io::Result<Self> {
        let dir = tempfile::TempDir::new()?;
        std::fs::create_dir_all(dir.path().join(".chump"))?;
        std::fs::create_dir_all(dir.path().join(".chump-locks"))?;

        let mut prev_env = HashMap::new();
        let values = Self::var_values(dir.path());
        for &var in ISOLATION_VARS {
            prev_env.insert(var, std::env::var(var).ok());
            std::env::set_var(var, values.get(var).expect("var in ISOLATION_VARS"));
        }

        Ok(Self { dir, prev_env })
    }

    /// The sandbox's root directory.
    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// The sandbox's `.chump/state.db` path (may not exist on disk until a
    /// `chump` command creates it).
    pub fn state_db_path(&self) -> PathBuf {
        self.dir.path().join(".chump").join("state.db")
    }

    fn var_values(sandbox: &Path) -> HashMap<&'static str, String> {
        let s = sandbox.display().to_string();
        HashMap::from([
            ("CHUMP_HOME", s.clone()),
            ("CHUMP_REPO", s.clone()),
            ("CHUMP_REPO_ROOT", s.clone()),
            (
                "CHUMP_STATE_DB",
                sandbox
                    .join(".chump")
                    .join("state.db")
                    .display()
                    .to_string(),
            ),
            (
                "CHUMP_LOCK_DIR",
                sandbox.join(".chump-locks").display().to_string(),
            ),
        ])
    }
}

impl Drop for TestSandbox {
    fn drop(&mut self) {
        for &var in ISOLATION_VARS {
            match self.prev_env.get(var) {
                Some(Some(v)) => std::env::set_var(var, v),
                Some(None) | None => std::env::remove_var(var),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_creates_dirs_and_sets_all_isolation_vars() {
        let sandbox = TestSandbox::setup().expect("setup");
        assert!(sandbox.path().join(".chump").is_dir());
        assert!(sandbox.path().join(".chump-locks").is_dir());
        for &var in ISOLATION_VARS {
            let val = std::env::var(var).unwrap_or_else(|_| panic!("{var} not set after setup"));
            assert!(
                val.starts_with(&sandbox.path().display().to_string()),
                "{var}={val} does not point into sandbox {}",
                sandbox.path().display()
            );
        }
        assert_eq!(
            sandbox.state_db_path(),
            sandbox.path().join(".chump").join("state.db")
        );
    }

    #[test]
    fn drop_restores_prior_env_value() {
        std::env::set_var("CHUMP_HOME", "/prior/value/infra-2088");
        {
            let sandbox = TestSandbox::setup().expect("setup");
            assert_eq!(
                std::env::var("CHUMP_HOME").unwrap(),
                sandbox.path().display().to_string()
            );
        }
        assert_eq!(
            std::env::var("CHUMP_HOME").unwrap(),
            "/prior/value/infra-2088"
        );
        std::env::remove_var("CHUMP_HOME");
    }

    #[test]
    fn drop_unsets_var_that_was_absent_before_setup() {
        std::env::remove_var("CHUMP_REPO_ROOT");
        {
            let _sandbox = TestSandbox::setup().expect("setup");
            assert!(std::env::var("CHUMP_REPO_ROOT").is_ok());
        }
        assert!(std::env::var("CHUMP_REPO_ROOT").is_err());
    }
}
