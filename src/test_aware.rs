//! Test-aware editing: when CHUMP_TEST_AWARE=1, capture baseline before edit, re-run after,
//! detect regressions; after 3 fix attempts with new failures, auto-stash and signal task blocked.

use anyhow::Result;
use std::collections::HashSet;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::repo_path;
use crate::run_test_tool::parse_cargo_test;

const MAX_FIX_ATTEMPTS: u32 = 3;

static TEST_AWARE_ATTEMPTS: AtomicU32 = AtomicU32::new(0);

pub fn test_aware_enabled() -> bool {
    std::env::var("CHUMP_TEST_AWARE")
        .map(|v| v.trim() == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Run cargo test in repo root and return (passed, failed, failing test names).
fn run_cargo_test_capture(root: &std::path::Path) -> Result<(u32, u32, Vec<String>)> {
    let out = Command::new("cargo")
        .args(["test"])
        .current_dir(root)
        .output()?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let (passed, failed, _ignored, failing_tests) = parse_cargo_test(&stdout, &stderr);
    Ok((passed, failed, failing_tests))
}

/// Baseline before edit: (passed, failed, set of failing test names).
pub fn capture_baseline() -> Result<(u32, u32, HashSet<String>)> {
    let root = repo_path::repo_root();
    let (passed, failed, failing) = run_cargo_test_capture(&root)?;
    Ok((passed, failed, failing.into_iter().collect()))
}

/// After edit: re-run tests; if there are new failures (tests failing now that weren't in baseline),
/// return Err with message. If attempts >= 3, run git stash and tell agent to set task blocked.
pub fn check_regression(baseline_failing: &HashSet<String>) -> Result<()> {
    let root = repo_path::repo_root();
    let (_passed, _failed, current_failing) = run_cargo_test_capture(&root)?;
    let current_set: HashSet<String> = current_failing.into_iter().collect();
    let new_failures: Vec<String> = current_set.difference(baseline_failing).cloned().collect();
    if new_failures.is_empty() {
        TEST_AWARE_ATTEMPTS.store(0, Ordering::SeqCst);
        return Ok(());
    }
    let attempts = TEST_AWARE_ATTEMPTS.fetch_add(1, Ordering::SeqCst) + 1;
    if attempts >= MAX_FIX_ATTEMPTS {
        TEST_AWARE_ATTEMPTS.store(0, Ordering::SeqCst);
        let _ = Command::new("git")
            .args(["stash", "save", "chump/auto-stash: test regression"])
            .current_dir(&root)
            .output();
        return Err(anyhow::anyhow!(
            "Test regressions after {} fix attempts: {}. Auto-stashed. Set task blocked and notify.",
            MAX_FIX_ATTEMPTS,
            new_failures.join(", ")
        ));
    }
    Err(anyhow::anyhow!(
        "New test regressions: {}. Fix and retry (attempt {}/{}).",
        new_failures.join(", "),
        attempts,
        MAX_FIX_ATTEMPTS
    ))
}
