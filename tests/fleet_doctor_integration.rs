//! RESILIENT-1359: Integration test for fleet-doctor synthetic FAIL payload → gap filing.
//!
//! Tests that when fleet-doctor processes a synthetic FAIL payload for a health check,
//! the gap filing dispatcher correctly creates a new gap with appropriate tagging,
//! and that running the test a second time does not create duplicate gaps (idempotent).
//!
//! Acceptance criteria:
//! 1. Test uses the synthetic FAIL generator for `gap-drift`
//! 2. After fleet-doctor processes the payload, query the gap store and assert a new gap with tag `gap-drift` exists
//! 3. Running the test a second time does not create a duplicate gap

use std::fs;
use std::path::Path;

#[test]
fn fleet_doctor_gap_drift_synthetic_fail_creates_gap() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let repo_root = temp_dir.path();

    // Setup: Initialize a minimal git repo and gap store
    git_init(repo_root);
    initialize_gap_store_dirs(repo_root);

    // Simulate fleet-doctor processing a synthetic FAIL for gap-drift
    let outcome = chump::fleet_doctor_dispatcher::dispatch_fail(repo_root, "gap-drift");

    // Assert: The dispatch was successful
    assert!(
        outcome.success,
        "dispatch_fail should succeed for gap-drift"
    );
    assert_eq!(outcome.check_id, "gap-drift");

    // Assert: Verify that a gap was created in the gap store with the appropriate tag
    let store = chump_gap_store::GapStore::open(repo_root)
        .expect("open gap store after fleet-doctor dispatch");
    let all_gaps = store.list(Some("open")).expect("list open gaps");

    let gap_with_tag = all_gaps
        .iter()
        .find(|g| g.notes.contains("health-check:gap-drift"))
        .expect("should find a gap with health-check:gap-drift tag");

    assert!(!gap_with_tag.id.is_empty());
    assert!(gap_with_tag.notes.contains("health-check:gap-drift"));
    let initial_gap_id = gap_with_tag.id.clone();

    // AC 3: Running the dispatcher a second time should not create a duplicate gap
    let outcome2 = chump::fleet_doctor_dispatcher::dispatch_fail(repo_root, "gap-drift");

    assert!(outcome2.success, "second dispatch should also succeed");

    // Query the store again and verify the gap count hasn't increased
    let all_gaps_after = store
        .list(Some("open"))
        .expect("list open gaps after second dispatch");
    let gaps_with_tag = all_gaps_after
        .iter()
        .filter(|g| g.notes.contains("health-check:gap-drift"))
        .collect::<Vec<_>>();

    assert_eq!(
        gaps_with_tag.len(),
        1,
        "should still have exactly one gap-drift gap"
    );
    assert_eq!(
        gaps_with_tag[0].id, initial_gap_id,
        "gap ID should be the same (idempotent)"
    );
}

#[test]
fn fleet_doctor_multiple_different_checks_create_separate_gaps() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let repo_root = temp_dir.path();

    // Setup
    git_init(repo_root);
    initialize_gap_store_dirs(repo_root);

    // Dispatch two different health check failures
    let outcome1 = chump::fleet_doctor_dispatcher::dispatch_fail(repo_root, "gap-drift");
    let outcome2 = chump::fleet_doctor_dispatcher::dispatch_fail(repo_root, "p0-budget");

    assert!(outcome1.success);
    assert!(outcome2.success);

    // Verify both gaps exist with their respective tags
    let store = chump_gap_store::GapStore::open(repo_root).expect("open gap store");
    let all_gaps = store.list(Some("open")).expect("list open gaps");

    let gap_drift_count = all_gaps
        .iter()
        .filter(|g| g.notes.contains("health-check:gap-drift"))
        .count();
    let p0_budget_count = all_gaps
        .iter()
        .filter(|g| g.notes.contains("health-check:p0-budget"))
        .count();

    assert_eq!(gap_drift_count, 1, "should have exactly one gap-drift gap");
    assert_eq!(p0_budget_count, 1, "should have exactly one p0-budget gap");
}

/// Initialize a minimal git repository in the given directory.
fn git_init(dir: &Path) {
    std::process::Command::new("git")
        .args(["init", "--quiet"])
        .current_dir(dir)
        .status()
        .expect("git init failed");
}

/// Create the necessary directories for the gap store.
fn initialize_gap_store_dirs(dir: &Path) {
    fs::create_dir_all(dir.join("docs/gaps")).expect("create docs/gaps dir");
    fs::create_dir_all(dir.join(".chump-locks")).expect("create .chump-locks dir");
    fs::create_dir_all(dir.join(".chump")).expect("create .chump dir");
}
