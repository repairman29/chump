// crates/chump-coord/tests/a2a_layer3d_seeds.rs — INFRA-1826
//
// Integration test for A2A Layer 3d (1/4 schema + 2/4 file-backend).
// Covers: seed-key schema contract, round-trip get/set/cas, CAS-conflict
// rejection, and TTL-expiry semantics.
//
// INFRA-1761 #2408 ships the schema; INFRA-1826 ships the real backend.

use chump_coord::scratchpad::{
    bucket_name, cas, get, key_to_filename, seed_key_lookup, seed_keys, set, ConflictPolicy,
    ScratchError,
};
use serde_json::json;
use serial_test::serial;

// ── Schema tests (from INFRA-1761 slice 1/4) ──────────────────────────────────

#[test]
fn bucket_name_pinned() {
    // If this fails, you're changing the NATS bucket name. Bump the
    // schema-version constant and migrate readers.
    assert_eq!(bucket_name(), "chump_scratch");
}

#[test]
fn exactly_five_seed_keys() {
    let keys = seed_keys();
    assert_eq!(keys.len(), 5, "v1 schema has exactly 5 seed keys");
}

#[test]
fn documented_keys_present() {
    let names: Vec<&str> = seed_keys().iter().map(|k| k.key).collect();
    let expected = [
        "main.head.sha",
        "fleet.size",
        "pillar.focus",
        "last_known_good.chump_binary",
        "red_letter.last_ts",
    ];
    for k in &expected {
        assert!(
            names.contains(k),
            "seed_keys should include {k} per A2A_SCRATCHPAD_KEYS.md"
        );
    }
}

#[test]
fn cas_required_keys_correct() {
    for key in ["main.head.sha", "last_known_good.chump_binary"] {
        let sk = seed_key_lookup(key).expect("key present");
        assert_eq!(
            sk.conflict_policy,
            ConflictPolicy::CASRequired,
            "{key} must be CASRequired per design doc"
        );
    }
}

#[test]
fn lww_keys_correct() {
    for key in ["fleet.size", "pillar.focus", "red_letter.last_ts"] {
        let sk = seed_key_lookup(key).expect("key present");
        assert_eq!(
            sk.conflict_policy,
            ConflictPolicy::LastWriterWins,
            "{key} must be LWW per design doc"
        );
    }
}

#[test]
fn all_seed_keys_prompt_inject() {
    for sk in seed_keys() {
        assert!(
            sk.prompt_inject,
            "{} should be prompt-injected (v1 keys all are)",
            sk.key
        );
    }
}

#[test]
fn ttl_values_match_design_doc() {
    // From A2A_SCRATCHPAD_KEYS.md table:
    //   main.head.sha = 86400, fleet.size = 300, pillar.focus = 3600,
    //   last_known_good.chump_binary = 86400, red_letter.last_ts = 86400
    let expectations: Vec<(&str, u32)> = vec![
        ("main.head.sha", 86_400),
        ("fleet.size", 300),
        ("pillar.focus", 3_600),
        ("last_known_good.chump_binary", 86_400),
        ("red_letter.last_ts", 86_400),
    ];
    for (key, expected_ttl) in expectations {
        let sk = seed_key_lookup(key).expect("key present");
        assert_eq!(
            sk.ttl_seconds, expected_ttl,
            "{key} TTL should match design doc"
        );
    }
}

#[test]
fn seed_key_lookup_unknown_returns_none() {
    assert!(seed_key_lookup("definitely-not-a-key").is_none());
}

// ── File-backend round-trip tests (INFRA-1826 slice 2/4) ─────────────────────
// #[serial] is required on every test that sets CHUMP_SCRATCH_DIR — the env
// var is process-global and tokio runs tests concurrently by default.

#[serial]
#[tokio::test]
async fn get_returns_none_for_absent_lww_key() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());
    let result = get("fleet.size").await.unwrap();
    assert!(result.is_none(), "absent key should return None");
    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn get_rejects_unknown_key_with_specific_error() {
    match get("nonexistent").await {
        Err(ScratchError::UnknownKey(k)) => assert_eq!(k, "nonexistent"),
        other => panic!("expected UnknownKey, got {:?}", other),
    }
}

#[serial]
#[tokio::test]
async fn set_and_get_roundtrip_fleet_size() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    set("fleet.size", json!(4)).await.unwrap();
    let val = get("fleet.size").await.unwrap();
    assert_eq!(val, Some(json!(4)));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn set_and_get_roundtrip_pillar_focus() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    set("pillar.focus", json!("EFFECTIVE")).await.unwrap();
    let val = get("pillar.focus").await.unwrap();
    assert_eq!(val, Some(json!("EFFECTIVE")));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn set_and_get_roundtrip_red_letter_last_ts() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    set("red_letter.last_ts", json!("2026-05-29T12:00:00Z"))
        .await
        .unwrap();
    let val = get("red_letter.last_ts").await.unwrap();
    assert_eq!(val, Some(json!("2026-05-29T12:00:00Z")));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn set_rejects_cas_required_key() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    match set("main.head.sha", json!("abc")).await {
        Err(ScratchError::CASRequiredOnBareSet(k)) => assert_eq!(k, "main.head.sha"),
        other => panic!("expected CASRequiredOnBareSet, got {:?}", other),
    }

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn cas_from_null_roundtrip_main_head_sha() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    // CAS from None (null) to first value
    cas(
        "main.head.sha",
        serde_json::Value::Null,
        json!("sha_abc123"),
    )
    .await
    .unwrap();

    let val = get("main.head.sha").await.unwrap();
    assert_eq!(val, Some(json!("sha_abc123")));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn cas_from_null_roundtrip_last_known_good_chump_binary() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    cas(
        "last_known_good.chump_binary",
        serde_json::Value::Null,
        json!("build_v1"),
    )
    .await
    .unwrap();

    let val = get("last_known_good.chump_binary").await.unwrap();
    assert_eq!(val, Some(json!("build_v1")));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn cas_sequential_update_succeeds() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    cas("main.head.sha", serde_json::Value::Null, json!("sha_v1"))
        .await
        .unwrap();

    // Second CAS: expected = "sha_v1", new = "sha_v2"
    cas("main.head.sha", json!("sha_v1"), json!("sha_v2"))
        .await
        .unwrap();

    let val = get("main.head.sha").await.unwrap();
    assert_eq!(val, Some(json!("sha_v2")));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn cas_conflict_returns_error_and_preserves_value() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    cas("main.head.sha", serde_json::Value::Null, json!("sha_v1"))
        .await
        .unwrap();

    // CAS with wrong expected → conflict
    match cas("main.head.sha", json!("sha_wrong"), json!("sha_v2")).await {
        Err(ScratchError::CASConflict {
            key,
            expected,
            actual,
        }) => {
            assert_eq!(key, "main.head.sha");
            assert!(expected.contains("sha_wrong"), "expected={expected}");
            assert!(actual.contains("sha_v1"), "actual={actual}");
        }
        other => panic!("expected CASConflict, got {:?}", other),
    }

    // Value must remain sha_v1
    let val = get("main.head.sha").await.unwrap();
    assert_eq!(val, Some(json!("sha_v1")));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn ttl_expiry_returns_none() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    // Write an envelope with an already-expired TTL directly to the file
    let path = dir
        .path()
        .join(format!("{}.json", key_to_filename("fleet.size")));
    let expired_json = serde_json::json!({
        "key": "fleet.size",
        "value": 99,
        "written_at": "2020-01-01T00:00:00Z",
        "ttl_expires_at": "2020-01-01T00:00:01Z"
    });
    std::fs::write(&path, serde_json::to_string_pretty(&expired_json).unwrap()).unwrap();

    let result = get("fleet.size").await.unwrap();
    assert!(
        result.is_none(),
        "expired entry should return None, got {:?}",
        result
    );

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn lww_set_overwrites_previous_value() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    set("fleet.size", json!(3)).await.unwrap();
    set("fleet.size", json!(5)).await.unwrap();
    let val = get("fleet.size").await.unwrap();
    assert_eq!(val, Some(json!(5)));

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

#[serial]
#[tokio::test]
async fn all_five_seed_keys_writable() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());

    // LWW keys via set()
    set("fleet.size", json!(2)).await.unwrap();
    set("pillar.focus", json!("CREDIBLE")).await.unwrap();
    set("red_letter.last_ts", json!("2026-05-29T00:00:00Z"))
        .await
        .unwrap();

    // CAS-required keys via cas()
    cas("main.head.sha", serde_json::Value::Null, json!("sha_seed"))
        .await
        .unwrap();
    cas(
        "last_known_good.chump_binary",
        serde_json::Value::Null,
        json!("build_seed"),
    )
    .await
    .unwrap();

    // Verify all five are readable
    assert_eq!(get("fleet.size").await.unwrap(), Some(json!(2)));
    assert_eq!(get("pillar.focus").await.unwrap(), Some(json!("CREDIBLE")));
    assert_eq!(
        get("red_letter.last_ts").await.unwrap(),
        Some(json!("2026-05-29T00:00:00Z"))
    );
    assert_eq!(get("main.head.sha").await.unwrap(), Some(json!("sha_seed")));
    assert_eq!(
        get("last_known_good.chump_binary").await.unwrap(),
        Some(json!("build_seed"))
    );

    std::env::remove_var("CHUMP_SCRATCH_DIR");
}
