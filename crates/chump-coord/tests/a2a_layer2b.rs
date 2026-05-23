// crates/chump-coord/tests/a2a_layer2b.rs — INFRA-1759
//
// Integration test for the A2A Layer 2b foundation slice (1/4) — RPC.

use chump_coord::rpc::{
    call_rpc, new_request_id, serve_rpc, DedupTable, RpcError, RpcRequest, RpcResponse,
    DEDUP_WINDOW_SECONDS, DEFAULT_RPC_TIMEOUT_MS,
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
fn request_id_unique() {
    let ids: Vec<String> = (0..50).map(|_| new_request_id()).collect();
    let unique: std::collections::HashSet<_> = ids.iter().collect();
    assert_eq!(unique.len(), ids.len(), "all ids should be distinct");
}

#[test]
fn request_round_trip_with_args() {
    let r = RpcRequest {
        request_id: "test-1".to_string(),
        method: "ask-eta".to_string(),
        args: json!({"gap_id": "INFRA-1759", "include_subtasks": true}),
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

#[tokio::test]
async fn call_rpc_stub_returns_not_implemented() {
    let res = call_rpc(
        "peer-session-1",
        "ask-capability",
        json!({"capability": "rust"}),
        DEFAULT_RPC_TIMEOUT_MS,
    )
    .await;
    match res {
        Err(RpcError::NotImplemented) => {}
        Err(other) => panic!("expected NotImplemented, got: {}", other),
        Ok(_) => panic!("stub must not return Ok before INFRA-1119 slice 2/4"),
    }
}

#[tokio::test]
async fn serve_rpc_stub_returns_not_implemented() {
    let res = serve_rpc("ask-capability", |args| {
        // Handler body never runs in the stub world, but the closure must
        // type-check against the documented signature.
        let _ = args;
        Ok(json!({"present": true}))
    })
    .await;
    match res {
        Err(RpcError::NotImplemented) => {}
        Err(other) => panic!("expected NotImplemented, got: {}", other),
        Ok(_) => panic!("stub must not return Ok before INFRA-1119 slice 2/4"),
    }
}

#[test]
fn error_display_mentions_slice() {
    let e = RpcError::NotImplemented;
    let s = format!("{e}");
    assert!(
        s.contains("INFRA-1119"),
        "error display should reference slice 2/4"
    );
}
