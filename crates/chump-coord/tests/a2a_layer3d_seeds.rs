// crates/chump-coord/tests/a2a_layer3d_seeds.rs — INFRA-1761
//
// Integration test for the A2A Layer 3d foundation slice (1/4) — seed
// key schema. Validates the documented contract from
// docs/design/A2A_SCRATCHPAD_KEYS.md: 5 keys, conflict policies per key,
// bucket name, stub behaviour for get/set/cas.

use chump_coord::scratchpad::{
    bucket_name, cas, get, seed_key_lookup, seed_keys, set, ConflictPolicy,
    ScratchError,
};
use serde_json::json;

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

#[tokio::test]
async fn get_stub_returns_not_implemented_for_known_key() {
    match get("fleet.size").await {
        Err(ScratchError::NotImplemented) => {}
        other => panic!("expected NotImplemented, got {:?}", other),
    }
}

#[tokio::test]
async fn get_rejects_unknown_key_with_specific_error() {
    match get("nonexistent").await {
        Err(ScratchError::UnknownKey(k)) => assert_eq!(k, "nonexistent"),
        other => panic!("expected UnknownKey, got {:?}", other),
    }
}

#[tokio::test]
async fn set_stub_returns_not_implemented() {
    match set("fleet.size", json!(8)).await {
        Err(ScratchError::NotImplemented) => {}
        other => panic!("expected NotImplemented, got {:?}", other),
    }
}

#[tokio::test]
async fn cas_stub_returns_not_implemented_for_known_key() {
    match cas("main.head.sha", json!("old"), json!("new")).await {
        Err(ScratchError::NotImplemented) => {}
        other => panic!("expected NotImplemented, got {:?}", other),
    }
}

#[tokio::test]
async fn cas_rejects_unknown_key() {
    match cas("bogus", json!("a"), json!("b")).await {
        Err(ScratchError::UnknownKey(k)) => assert_eq!(k, "bogus"),
        other => panic!("expected UnknownKey, got {:?}", other),
    }
}

#[test]
fn error_display_mentions_slice() {
    let e = ScratchError::NotImplemented;
    let s = format!("{e}");
    assert!(s.contains("INFRA-1121"), "error Display should reference slice 2/4 (INFRA-1121)");
}
