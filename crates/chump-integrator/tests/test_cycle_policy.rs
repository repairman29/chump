//! Integration test: policy gate skips cycles below volume threshold.

use chump_integrator::{IntegratorConfig, IntegratorDaemon};
use serial_test::serial;
use std::path::PathBuf;
use tempfile::TempDir;

async fn make_empty_repo() -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_path_buf();
    for args in [
        vec!["init"],
        vec!["config", "user.email", "test@test.com"],
        vec!["config", "user.name", "Test"],
    ] {
        tokio::process::Command::new("git")
            .args(&args)
            .current_dir(&path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await
            .unwrap();
    }
    tokio::fs::write(path.join("README.md"), "# test\n")
        .await
        .unwrap();
    tokio::process::Command::new("git")
        .args(["add", "README.md"])
        .current_dir(&path)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .unwrap();
    tokio::process::Command::new("git")
        .args(["commit", "-m", "init"])
        .current_dir(&path)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .unwrap();
    // No gaps — GapStore::open creates a fresh empty DB.
    let _ = chump_gap_store::GapStore::open(&path).unwrap();
    (dir, path)
}

#[tokio::test]
#[serial]
async fn test_empty_queue_skips_without_error() {
    let (_dir, repo) = make_empty_repo().await;
    let log_path = repo.join("no-cycle.log");

    let mut daemon = IntegratorDaemon::new(repo.clone()).await.unwrap();
    daemon.config = IntegratorConfig {
        dry_run: true,
        volume_threshold: 5,
        ..IntegratorConfig::default()
    };
    daemon.dry_run_log = log_path.clone();
    daemon.coord = None;

    // Should return Ok(()) and NOT create a dry-run log.
    daemon.run_cycle().await.unwrap();
    assert!(
        !log_path.exists(),
        "dry-run log should not be created when queue is empty"
    );
}

#[tokio::test]
#[serial]
async fn test_below_threshold_skips_without_log() {
    let (_dir, repo) = make_empty_repo().await;

    // Add 2 ready_to_ship gaps but set threshold to 5.
    let store = chump_gap_store::GapStore::open(&repo).unwrap();
    std::env::set_var("CHUMP_RESERVE_VERIFY", "0");
    for i in 0..2u32 {
        let gap_id = store
            .reserve(
                "INFRA",
                &format!("EFFECTIVE P1: policy test gap {i}"),
                "P1",
                "s",
            )
            .unwrap();
        store
            .set_fields(
                &gap_id,
                chump_gap_store::GapFieldUpdate {
                    status: Some("ready_to_ship".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
    }
    std::env::remove_var("CHUMP_RESERVE_VERIFY");

    let log_path = repo.join("below-threshold.log");
    let mut daemon = IntegratorDaemon::new(repo.clone()).await.unwrap();
    daemon.config = IntegratorConfig {
        dry_run: true,
        volume_threshold: 5, // 2 gaps < 5 threshold
        max_batch: 10,
        loc_budget: 10_000,
        ..IntegratorConfig::default()
    };
    daemon.dry_run_log = log_path.clone();
    daemon.coord = None;

    daemon.run_cycle().await.unwrap();
    assert!(
        !log_path.exists(),
        "dry-run log should not be created when below threshold"
    );
}
