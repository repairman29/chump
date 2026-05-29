//! Integration test: dry-run log write path.
//!
//! Tests exercise the dry-run decision path directly — constructing a
//! CycleManifest and verifying the log file format — without needing a live
//! git remote for the MERGE step (which is covered by cycle::merge_branch unit
//! tests that use a local git fixture).

use chump_integrator::cycle::{CycleManifest, GapCandidate};
use serial_test::serial;

fn make_candidate(gap_id: &str) -> GapCandidate {
    GapCandidate {
        gap_id: gap_id.to_string(),
        title: format!("Test gap {}", gap_id),
        priority: "P1".to_string(),
        ready_at: chrono::Utc::now().to_rfc3339(),
        queue_age_s: 120,
        estimated_loc: 150,
        branch: format!("chump/{}", gap_id.to_lowercase()),
        author: None,
    }
}

/// Mirror of IntegratorDaemon::write_dry_run_log — exercised here directly so
/// these tests don't require a live git remote.
fn write_manifest_to_log(manifest: &CycleManifest, log_path: &std::path::Path) {
    use std::io::Write as _;
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
        .unwrap();
    let entry = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339(),
        "cycle_id": manifest.cycle_id,
        "summary": manifest.dry_run_summary(),
        "total_loc": manifest.total_loc,
        "candidates": manifest.candidates.iter().map(|c| &c.gap_id).collect::<Vec<_>>(),
    });
    writeln!(file, "{}", serde_json::to_string(&entry).unwrap()).unwrap();
}

#[test]
#[serial]
fn test_dry_run_log_contains_would_have_shipped() {
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("dry-run.log");

    let candidates = vec![
        make_candidate("INFRA-001"),
        make_candidate("INFRA-002"),
        make_candidate("INFRA-003"),
    ];
    let manifest = CycleManifest::new("abc12345".to_string(), candidates);
    write_manifest_to_log(&manifest, &log_path);

    assert!(log_path.exists(), "dry-run log was not created");
    let contents = std::fs::read_to_string(&log_path).unwrap();
    assert!(
        contents.contains("WOULD HAVE SHIPPED"),
        "expected 'WOULD HAVE SHIPPED' in log:\n{contents}"
    );
}

#[test]
#[serial]
fn test_dry_run_log_contains_gap_ids() {
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("dry-run-ids.log");

    let candidates = vec![
        make_candidate("INFRA-101"),
        make_candidate("INFRA-102"),
    ];
    let manifest = CycleManifest::new("deadbeef".to_string(), candidates);
    write_manifest_to_log(&manifest, &log_path);

    let contents = std::fs::read_to_string(&log_path).unwrap();
    assert!(
        contents.contains("INFRA-101"),
        "expected INFRA-101 in log:\n{contents}"
    );
    assert!(
        contents.contains("INFRA-102"),
        "expected INFRA-102 in log:\n{contents}"
    );
}

#[test]
#[serial]
fn test_dry_run_log_is_valid_jsonl() {
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("dry-run-json.log");

    let candidates = vec![make_candidate("INFRA-200")];
    let manifest = CycleManifest::new("cafebabe".to_string(), candidates);
    write_manifest_to_log(&manifest, &log_path);

    let contents = std::fs::read_to_string(&log_path).unwrap();
    for line in contents.lines() {
        let parsed: serde_json::Value = serde_json::from_str(line)
            .unwrap_or_else(|e| panic!("invalid JSON line: {e}\nline={line}"));
        assert!(parsed["ts"].is_string(), "ts field should be a string");
        assert!(
            parsed["cycle_id"].is_string(),
            "cycle_id should be a string"
        );
        assert!(parsed["summary"].is_string(), "summary should be a string");
    }
}

#[test]
#[serial]
fn test_dry_run_log_appends_multiple_cycles() {
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("dry-run-append.log");

    for i in 0..3u32 {
        let candidates = vec![make_candidate(&format!("INFRA-{:03}", 300 + i))];
        let manifest = CycleManifest::new(format!("cycle{:04}", i), candidates);
        write_manifest_to_log(&manifest, &log_path);
    }

    let contents = std::fs::read_to_string(&log_path).unwrap();
    assert_eq!(
        contents.lines().count(),
        3,
        "expected 3 lines (one per cycle), got:\n{contents}"
    );
}
