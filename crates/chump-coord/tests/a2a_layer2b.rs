// crates/chump-coord/tests/a2a_layer2b.rs — INFRA-1119
//
// Integration test for the A2A Layer 2b RPC v1 (file-backed transport).
// Promoted from INFRA-1759 stub tests; this file now exercises the real
// call_rpc + serve_rpc_n flow.

use chump_coord::rpc::{
    call_rpc, new_request_id, serve_rpc_n, DedupTable, RpcError, RpcRequest, RpcResponse,
    DEDUP_WINDOW_SECONDS, DEFAULT_RPC_TIMEOUT_MS,
};
use serde_json::json;

// Tests that mutate process-level env vars (CHUMP_SESSION_ID, CHUMP_LOCK_DIR)
// are flavored multi-thread and use a per-test tmpdir for isolation. The
// stub-era tests are preserved where they still apply (types + dedup).

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

#[test]
fn error_display_distinguishes_variants() {
    let timeout = RpcError::Timeout.to_string();
    let crash = RpcError::HandlerCrashed("panic msg".into()).to_string();
    let net = RpcError::Network("conn refused".into()).to_string();
    assert!(timeout.contains("timeout"));
    assert!(crash.contains("crashed") || crash.contains("HandlerCrashed"));
    assert!(net.contains("transport") || net.contains("conn refused"));
    assert_ne!(timeout, crash);
    assert_ne!(timeout, net);
    assert_ne!(crash, net);
}

// ── Real-impl integration tests (file-backed transport) ─────────────────────
//
// Each tokio-test uses a tmpdir for CHUMP_LOCK_DIR so the real
// .chump-locks is never touched. Env mutation is wrapped in unsafe blocks
// because Rust 2024+ flags it as unsafe (single-threaded test by default).

fn isolate() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("tmpdir");
    unsafe {
        std::env::set_var("CHUMP_LOCK_DIR", dir.path());
        std::env::set_var("CHUMP_AMBIENT_LOG", dir.path().join("ambient.jsonl"));
    }
    dir
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn call_rpc_times_out_when_no_server() {
    let _dir = isolate();
    unsafe {
        std::env::set_var("CHUMP_SESSION_ID", "caller-only");
    }
    let result = call_rpc("dead-target", "ask-eta", json!({}), 250).await;
    assert!(
        matches!(result, Err(RpcError::Timeout)),
        "expected Timeout, got: {result:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn call_rpc_handler_panic_surfaces_as_handler_crashed() {
    let _dir = isolate();
    unsafe {
        std::env::set_var("CHUMP_SESSION_ID", "panic-server");
    }
    let server = tokio::spawn(async {
        let _ = serve_rpc_n(
            "ask-progress",
            |_args| -> Result<serde_json::Value, String> {
                panic!("boom: simulated handler crash");
            },
            Some(60),
        )
        .await;
    });
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    unsafe {
        std::env::set_var("CHUMP_SESSION_ID", "panic-caller");
    }
    let result = call_rpc("panic-server", "ask-progress", json!({}), 3_000).await;
    server.abort();
    match result {
        Err(RpcError::HandlerCrashed(msg)) => {
            assert!(
                msg.contains("HANDLER_CRASHED"),
                "expected sentinel, got: {msg}"
            );
        }
        other => panic!("expected HandlerCrashed, got {other:?}"),
    }
}
