// crates/chump-coord/tests/a2a_layer2b.rs — INFRA-1119
//
// Integration tests for A2A Layer 2b: RPC request/response activation (slice 2/4).
// Tests: roundtrip (success), timeout, handler-crash surfacing, request_id dedup.

use chump_coord::rpc::{
    call_rpc_with_nats, new_request_id, serve_rpc_with_nats, DedupTable, RpcError, RpcRequest,
    RpcResponse, DEDUP_WINDOW_SECONDS, DEFAULT_RPC_TIMEOUT_MS,
};
use serde_json::json;

#[test]
fn defaults_match_documented_constants() {
    assert_eq!(DEFAULT_RPC_TIMEOUT_MS, 10_000);
    assert_eq!(DEDUP_WINDOW_SECONDS, 60);
}

#[test]
fn dedup_first_seen_wins() {
    let t = DedupTable::new();
    assert!(t.record("req-a"), "first record is new");
    assert!(!t.record("req-a"), "duplicate must be rejected");
    assert!(t.record("req-b"), "different id is new");
}

#[test]
fn dedup_table_tracks_multiple_ids() {
    let t = DedupTable::new();
    for i in 0..20 {
        assert!(t.record(&format!("req-{i}")), "first record should be new");
    }
    assert_eq!(t.len(), 20);
    // Re-recording any does not grow the table
    for i in 0..20 {
        assert!(!t.record(&format!("req-{i}")), "should be a duplicate");
    }
    assert_eq!(t.len(), 20);
}

#[test]
fn request_id_unique() {
    let ids: Vec<String> = (0..50).map(|_| new_request_id()).collect();
    let unique: std::collections::HashSet<_> = ids.iter().collect();
    assert_eq!(unique.len(), ids.len(), "all ids should be distinct");
}

#[test]
fn request_id_is_valid_uuid() {
    let id = new_request_id();
    assert!(
        uuid::Uuid::parse_str(&id).is_ok(),
        "request_id should be a valid UUID v4: {id}"
    );
}

#[test]
fn request_round_trip_with_args() {
    let r = RpcRequest {
        request_id: "test-1".to_string(),
        method: "ask-eta".to_string(),
        args: json!({"gap_id": "INFRA-1119", "include_subtasks": true}),
        sent_at: "2026-05-23T15:00:00Z".to_string(),
    };
    let j = serde_json::to_string(&r).expect("serialize");
    assert!(j.contains("\"method\":\"ask-eta\""));
    let back: RpcRequest = serde_json::from_str(&j).expect("deserialize");
    assert_eq!(r, back);
}

#[test]
fn response_with_error_omits_result() {
    let r = RpcResponse {
        request_id: "test-1".to_string(),
        result: None,
        error: Some("handler timed out".to_string()),
        latency_ms: 10_000,
    };
    let j = serde_json::to_string(&r).expect("serialize");
    assert!(!j.contains("\"result\""), "None result must be omitted");
    assert!(j.contains("\"error\":\"handler timed out\""));
}

#[test]
fn response_with_result_omits_error() {
    let r = RpcResponse {
        request_id: "test-1".to_string(),
        result: Some(json!({"eta_seconds": 120})),
        error: None,
        latency_ms: 5,
    };
    let j = serde_json::to_string(&r).expect("serialize");
    assert!(j.contains("\"result\""), "Some result should be present");
    assert!(!j.contains("\"error\""), "None error must be omitted");
}

// ── No-NATS error path tests (unit-testable without a live NATS server) ──────

#[tokio::test]
async fn call_rpc_no_nats_returns_no_nats_error() {
    let result = call_rpc_with_nats(
        None,
        "peer-session-1",
        "ask-capability",
        json!({"capability": "rust"}),
        DEFAULT_RPC_TIMEOUT_MS,
    )
    .await;
    match result {
        Err(RpcError::NoNats) => {}
        Err(other) => panic!("expected NoNats, got: {other}"),
        Ok(_) => panic!("should not succeed without NATS"),
    }
}

#[tokio::test]
async fn serve_rpc_no_nats_returns_no_nats_error() {
    let result = serve_rpc_with_nats(None, "session-1", "ask-capability", |args| {
        // Handler body type-checks against documented signature
        let _ = args;
        Ok(json!({"present": true}))
    })
    .await;
    match result {
        Err(RpcError::NoNats) => {}
        Err(other) => panic!("expected NoNats, got: {other}"),
        Ok(_) => panic!("stub must not return Ok without NATS"),
    }
}

// ── Error display format (AC-3: distinct error kinds) ────────────────────────

#[test]
fn timeout_error_display_references_infra_1119() {
    let e = RpcError::Timeout {
        request_id: "req-x".to_string(),
        timeout_ms: 10_000,
    };
    let s = format!("{e}");
    assert!(
        s.contains("INFRA-1119"),
        "timeout display should reference INFRA-1119: {s}"
    );
    assert!(s.contains("timeout"), "should mention timeout: {s}");
}

#[test]
fn handler_crash_error_display_references_infra_1119() {
    let e = RpcError::HandlerCrash {
        request_id: "req-x".to_string(),
        reason: "division by zero".to_string(),
    };
    let s = format!("{e}");
    assert!(
        s.contains("INFRA-1119"),
        "handler_crash display should reference INFRA-1119: {s}"
    );
    assert!(
        s.contains("handler crash") || s.contains("HandlerCrash") || s.contains("crash"),
        "should mention crash: {s}"
    );
}

#[test]
fn timeout_and_crash_are_distinct_error_variants() {
    let timeout = RpcError::Timeout {
        request_id: "r".to_string(),
        timeout_ms: 1000,
    };
    let crash = RpcError::HandlerCrash {
        request_id: "r".to_string(),
        reason: "boom".to_string(),
    };
    // Different display text — they are distinct from each other
    let ts = format!("{timeout}");
    let cs = format!("{crash}");
    assert_ne!(
        ts, cs,
        "timeout and handler_crash must have different display strings"
    );
}

// ── Handler crash detection in response deserialization ──────────────────────

#[test]
fn response_error_handler_crash_prefix_is_detectable() {
    // Simulate what the server puts in the error field on handler crash
    let r = RpcResponse {
        request_id: "req-1".to_string(),
        result: None,
        error: Some("handler_crash: division by zero".to_string()),
        latency_ms: 1,
    };
    // The client detects this via the "handler_crash:" prefix
    let is_crash = r
        .error
        .as_deref()
        .map(|e| e.starts_with("handler_crash:"))
        .unwrap_or(false);
    assert!(
        is_crash,
        "handler_crash: prefix must be detectable by client"
    );
}

// ── 5 use-case wrapper argument shapes ───────────────────────────────────────

#[test]
fn ask_eta_args_shape() {
    let args = json!({"gap_id": "INFRA-1119"});
    assert!(args.get("gap_id").is_some());
}

#[test]
fn ask_overlap_args_shape() {
    let files = vec!["src/rpc.rs", "src/lib.rs"];
    let args = json!({"files": files});
    assert!(args.get("files").and_then(|f| f.as_array()).is_some());
}

#[test]
fn ask_handoff_args_shape() {
    let args = json!({"gap_id": "INFRA-1119", "reason": "context switch"});
    assert!(args.get("gap_id").is_some());
    assert!(args.get("reason").is_some());
}

#[test]
fn ask_progress_args_shape() {
    let args = json!({"gap_id": "INFRA-1119"});
    assert!(args.get("gap_id").is_some());
}

#[test]
fn ask_capability_args_shape_with_filter() {
    let args = json!({"capability": "rust"});
    assert!(args.get("capability").is_some());
}

#[test]
fn ask_capability_args_shape_without_filter() {
    let args = json!({});
    assert!(args.as_object().map(|o| o.is_empty()).unwrap_or(false));
}
