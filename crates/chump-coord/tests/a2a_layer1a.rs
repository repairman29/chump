// crates/chump-coord/tests/a2a_layer1a.rs — INFRA-1758
//
// Integration test for the A2A Layer 1a foundation slice (1/4). Validates
// the wire-format contract that downstream slices (real NATS subscribe in
// slice 2, fallback in slice 3, chaos test in slice 4) all depend on:
//   - EventFilter exhaustive variants
//   - CoordEvent JSON round-trip (compat with ambient.jsonl line shape)
//   - subscribe_events stub returns NotImplemented (compile-time check that
//     the async signature exists with the right type)

use chump_coord::events::{
    subscribe_events, CoordEvent, EventFilter, SubscribeError,
};
use serde_json::json;

#[test]
fn event_filter_variants_exhaustive() {
    // If this fails to compile when slice 2 adds variants, downstream
    // match-sites need updating.
    let _ = EventFilter::All;
    let _ = EventFilter::Kind("k".to_string());
    let _ = EventFilter::Session("s".to_string());
    let _ = EventFilter::Kinds(vec![]);
}

#[test]
fn coord_event_round_trip() {
    let e = CoordEvent {
        ts: "2026-05-23T01:02:03Z".to_string(),
        kind: "gap_claimed".to_string(),
        session_id: Some("claim-infra-1758-82116-1779547274".to_string()),
        payload: json!({"gap_id": "INFRA-1758"}),
    };
    let j = serde_json::to_string(&e).expect("serialize");
    let back: CoordEvent = serde_json::from_str(&j).expect("deserialize");
    assert_eq!(e, back, "round-trip lossless");
    // Check the wire shape lines up with ambient.jsonl conventions
    assert!(j.contains("\"ts\":\""));
    assert!(j.contains("\"kind\":\"gap_claimed\""));
}

#[test]
fn coord_event_missing_session_id_omitted_in_json() {
    let e = CoordEvent {
        ts: "2026-05-23T00:00:00Z".to_string(),
        kind: "ambient_only_no_session".to_string(),
        session_id: None,
        payload: json!({}),
    };
    let j = serde_json::to_string(&e).expect("serialize");
    // skip_serializing_if drops the key entirely when None — matches the
    // ambient.jsonl convention of omitting absent fields.
    assert!(!j.contains("session_id"), "None session_id should be omitted in JSON: {j}");
}

#[test]
fn filter_matches_logic() {
    let e = CoordEvent {
        ts: "t".to_string(),
        kind: "gap_claimed".to_string(),
        session_id: Some("opus-1".to_string()),
        payload: json!({}),
    };
    assert!(EventFilter::All.matches(&e));
    assert!(EventFilter::Kind("gap_claimed".to_string()).matches(&e));
    assert!(!EventFilter::Kind("gap_resumed".to_string()).matches(&e));
    assert!(EventFilter::Session("opus-1".to_string()).matches(&e));
    assert!(!EventFilter::Session("opus-2".to_string()).matches(&e));
    assert!(EventFilter::Kinds(vec!["gap_claimed".to_string(), "x".to_string()]).matches(&e));
    assert!(!EventFilter::Kinds(vec!["x".to_string(), "y".to_string()]).matches(&e));
}

#[tokio::test]
async fn subscribe_events_stub_returns_not_implemented() {
    // Compile-time: async fn signature exists with the right shape.
    // Runtime: stub returns NotImplemented so downstream callers fail fast
    // until slice 2/4 lands the real impl.
    let res = subscribe_events(EventFilter::All).await;
    match res {
        Err(SubscribeError::NotImplemented) => {}
        Err(other) => panic!("expected NotImplemented, got: {}", other),
        Ok(_) => panic!("stub must not return Ok — slice 2/4 hasn't shipped"),
    }
}

#[test]
fn error_display_contains_marker() {
    let e = SubscribeError::NotImplemented;
    let s = format!("{e}");
    assert!(s.contains("INFRA-1118"), "error display should reference slice 2/4 (INFRA-1118)");
}
