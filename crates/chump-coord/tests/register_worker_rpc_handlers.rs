// crates/chump-coord/tests/register_worker_rpc_handlers.rs — CREDIBLE-245
//
// Integration test for `chump_coord::rpc::register_worker_rpc_handlers`
// (CREDIBLE-099 slice): registering a worker session's RPC handlers and
// getting a success response back when a peer calls one of them.
//
// Skips (does not fail) when NATS is unreachable, matching the pattern used
// by a2a_layer1a.rs / help_request.rs / distributed_mutex.rs.

use chump_coord::rpc::{ask_capability, ask_eta, register_worker_rpc_handlers};
use std::time::Duration;

async fn nats_url_if_available() -> Option<String> {
    let url =
        std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| "nats://127.0.0.1:4222".to_string());
    match tokio::time::timeout(Duration::from_millis(500), async_nats::connect(&url)).await {
        Ok(Ok(_)) => Some(url),
        _ => None,
    }
}

#[tokio::test]
async fn register_worker_rpc_handlers_serves_success_responses() {
    let Some(nats_url) = nats_url_if_available().await else {
        eprintln!(
            "skip — no NATS on {}",
            nats_url_if_available().await.unwrap_or_default()
        );
        return;
    };

    let nats = async_nats::connect(&nats_url)
        .await
        .expect("connect must succeed once nats_url_if_available confirmed reachability");
    let session_id = format!("test-worker-{}", uuid::Uuid::new_v4().simple());

    // AC#1: registers a worker session's RPC handlers without error.
    register_worker_rpc_handlers(&nats, &session_id)
        .await
        .expect("register_worker_rpc_handlers should succeed");

    // Give the subscriptions a moment to establish before calling in.
    tokio::time::sleep(Duration::from_millis(200)).await;

    let caller = async_nats::connect(&nats_url)
        .await
        .expect("caller connect");

    // AC#2: a peer calling a registered handler gets a success response.
    let eta = ask_eta(&caller, &session_id, "CREDIBLE-245")
        .await
        .expect("ask_eta should get a response from the registered worker");
    assert!(
        eta.error.is_none(),
        "ask_eta should not error: {:?}",
        eta.error
    );
    assert!(
        eta.result.is_some(),
        "ask_eta should return a result payload"
    );

    let cap = ask_capability(&caller, &session_id, None)
        .await
        .expect("ask_capability should get a response from the registered worker");
    assert!(
        cap.error.is_none(),
        "ask_capability should not error: {:?}",
        cap.error
    );
    assert!(
        cap.result
            .as_ref()
            .and_then(|r| r.get("capabilities"))
            .is_some(),
        "ask_capability result should contain capabilities: {:?}",
        cap.result
    );
}
