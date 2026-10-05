//! META-208: integration test for the flake-import ingestion path.
//! Invokes `chump_atomic_claim::atomic_claim::run_flake_import` on the
//! checked-in `tests/fixtures/nextest-flaky.json` fixture and asserts
//! `flake_tracker.db` gets exactly the expected flaky rows — and no rows
//! for the fixture's non-flaky entries.

use std::path::Path;

#[test]
fn run_flake_import_ingests_only_flaky_outcomes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let repo_root = dir.path();

    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/nextest-flaky.json");
    assert!(fixture.exists(), "fixture missing at {}", fixture.display());

    let inserted = chump_atomic_claim::atomic_claim::run_flake_import(repo_root, &fixture).unwrap();
    assert_eq!(inserted, 2, "fixture has exactly 2 flaky entries");

    let db_path = repo_root.join(".chump/flake_tracker.db");
    let conn = rusqlite::Connection::open(&db_path).unwrap();

    let mut stmt = conn
        .prepare("SELECT test_name, outcome, run_timestamp FROM flake_outcomes ORDER BY test_name")
        .unwrap();
    let rows: Vec<(String, String, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();

    assert_eq!(rows.len(), 2);
    for (test_name, outcome, run_timestamp) in &rows {
        assert_eq!(outcome, "flaky");
        assert!(
            !run_timestamp.is_empty(),
            "run_timestamp must be non-null/non-empty"
        );
        assert!(test_name.starts_with("tests::flaky_"));
    }

    let non_flaky_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM flake_outcomes WHERE test_name IN ('tests::stable_pass', 'tests::stable_fail')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        non_flaky_count, 0,
        "non-flaky fixture entries must not be inserted"
    );
}
