//! Integration smoke test for chump-ambient-cli (EFFECTIVE-023 AC #6).
//!
//! Verifies the library's public API: emit() writes a schema-valid line, and
//! locate_ambient() / file read recovers it with all fields intact.

use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_ambient_cli::ambient_stream::locate_ambient;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

fn unique_label(prefix: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("{prefix}-{nanos}")
}

#[test]
fn emit_then_read_recovers_all_base_and_extra_fields() {
    let tmp = TempDir::new().unwrap();
    let ambient = tmp.path().join("ambient.jsonl");

    let args = EmitArgs {
        kind: "roundtrip_test".into(),
        gap: Some("EFFECTIVE-023".into()),
        source: Some("integration-test".into()),
        harness: Some("cargo-test".into()),
        fields: vec![
            ("scenario".into(), "happy_path".into()),
            ("attempt".into(), "1".into()),
        ],
        ambient_override: Some(ambient.clone()),
        session_override: Some(unique_label("sess")),
    };
    let written_path = emit(&args).expect("emit should succeed");
    assert_eq!(written_path, ambient);

    let body = fs::read_to_string(&ambient).expect("ambient file should exist");
    let line = body.trim_end_matches('\n');
    assert!(!line.contains('\n'), "emit must write exactly one line");

    let parsed: serde_json::Value = serde_json::from_str(line).expect("valid JSON");
    assert_eq!(parsed["event"], "roundtrip_test");
    assert_eq!(parsed["gap_id"], "EFFECTIVE-023");
    assert_eq!(parsed["source"], "integration-test");
    assert_eq!(parsed["harness"], "cargo-test");
    assert_eq!(parsed["scenario"], "happy_path");
    assert_eq!(parsed["attempt"], "1");
    assert!(parsed["ts"].as_str().unwrap().ends_with('Z'));
    assert!(parsed["session"].as_str().unwrap().starts_with("sess-"));
}

#[test]
fn locate_ambient_walks_up_to_find_chump_locks() {
    let tmp = TempDir::new().unwrap();
    let chump_locks = tmp.path().join(".chump-locks");
    fs::create_dir_all(&chump_locks).unwrap();
    let ambient = chump_locks.join("ambient.jsonl");
    fs::write(&ambient, "{}\n").unwrap();

    let nested = tmp.path().join("a/b/c");
    fs::create_dir_all(&nested).unwrap();

    let found = locate_ambient(&nested).expect("locate_ambient should find the parent's log");
    assert_eq!(found, ambient);
}

#[test]
fn locate_ambient_returns_none_when_no_chump_locks_in_tree() {
    // Use a fresh tempdir with no .chump-locks anywhere.
    let tmp = TempDir::new().unwrap();
    let nested = tmp.path().join("deep/nested/dir");
    fs::create_dir_all(&nested).unwrap();

    // We can't assert None outright because the test harness's ancestors may
    // contain .chump-locks (e.g. when run inside the chump repo). Instead,
    // assert that whatever it returns is NOT inside our tempdir — that proves
    // it didn't fabricate a path.
    if let Some(found) = locate_ambient(&nested) {
        assert!(
            !found.starts_with(tmp.path()),
            "locate_ambient should not invent a path inside an empty tempdir"
        );
    }
}

#[test]
fn emit_appends_rather_than_truncates_on_repeat_calls() {
    let tmp = TempDir::new().unwrap();
    let ambient = tmp.path().join("ambient.jsonl");

    for i in 0..5 {
        let args = EmitArgs {
            kind: "tick".into(),
            fields: vec![("i".into(), i.to_string())],
            ambient_override: Some(ambient.clone()),
            session_override: Some("s".into()),
            harness: Some("test".into()),
            ..Default::default()
        };
        emit(&args).unwrap();
    }

    let body = fs::read_to_string(&ambient).unwrap();
    let lines: Vec<&str> = body.lines().collect();
    assert_eq!(lines.len(), 5, "five emits should produce five lines");
    for (n, line) in lines.iter().enumerate() {
        let v: serde_json::Value = serde_json::from_str(line).unwrap();
        assert_eq!(v["i"].as_str().unwrap(), n.to_string());
    }
}

#[test]
fn emit_with_special_chars_escapes_json_correctly() {
    let tmp = TempDir::new().unwrap();
    let ambient = tmp.path().join("ambient.jsonl");

    let args = EmitArgs {
        kind: "edge_case".into(),
        fields: vec![
            ("quoted".into(), r#"he said "hi""#.into()),
            ("multiline".into(), "line1\nline2".into()),
            ("tab".into(), "a\tb".into()),
        ],
        ambient_override: Some(ambient.clone()),
        session_override: Some("s".into()),
        harness: Some("test".into()),
        ..Default::default()
    };
    emit(&args).unwrap();

    let line = fs::read_to_string(&ambient).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).expect("valid JSON");
    assert_eq!(parsed["quoted"], r#"he said "hi""#);
    assert_eq!(parsed["multiline"], "line1\nline2");
    assert_eq!(parsed["tab"], "a\tb");
}

#[allow(dead_code)]
fn _ensure_pathbuf_use_is_alive() -> PathBuf {
    PathBuf::new()
}
