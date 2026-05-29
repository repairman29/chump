//! Integration test: CycleManifest dry_run_summary format.

use chump_integrator::cycle::{CycleManifest, GapCandidate};

fn make_candidate(gap_id: &str) -> GapCandidate {
    GapCandidate {
        gap_id: gap_id.to_string(),
        title: format!("Gap {}", gap_id),
        priority: "P1".to_string(),
        ready_at: chrono::Utc::now().to_rfc3339(),
        queue_age_s: 60,
        estimated_loc: 100,
        branch: format!("chump/{}", gap_id.to_lowercase()),
        author: None,
    }
}

#[test]
fn test_dry_run_summary_format() {
    let candidates = vec![
        make_candidate("INFRA-001"),
        make_candidate("INFRA-002"),
        make_candidate("INFRA-003"),
    ];
    let manifest = CycleManifest::new("abc12345".to_string(), candidates);
    let summary = manifest.dry_run_summary();

    assert!(
        summary.starts_with("WOULD HAVE SHIPPED 3 gaps:"),
        "unexpected summary: {summary}"
    );
    assert!(summary.contains("INFRA-001"), "missing INFRA-001: {summary}");
    assert!(summary.contains("INFRA-002"), "missing INFRA-002: {summary}");
    assert!(summary.contains("INFRA-003"), "missing INFRA-003: {summary}");
}

#[test]
fn test_manifest_total_loc() {
    let candidates = vec![
        {
            let mut c = make_candidate("INFRA-010");
            c.estimated_loc = 300;
            c
        },
        {
            let mut c = make_candidate("INFRA-011");
            c.estimated_loc = 450;
            c
        },
    ];
    let manifest = CycleManifest::new("xyz99999".to_string(), candidates);
    assert_eq!(manifest.total_loc, 750);
}

#[test]
fn test_manifest_empty_candidates() {
    let manifest = CycleManifest::new("empty0000".to_string(), vec![]);
    let summary = manifest.dry_run_summary();
    assert!(
        summary.starts_with("WOULD HAVE SHIPPED 0 gaps:"),
        "unexpected: {summary}"
    );
    assert_eq!(manifest.total_loc, 0);
}
