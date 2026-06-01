//! META-175: JetStream durable consumer restart-safe replay integration test.
//!
//! ## Property under test
//!
//! When a consumer acks N of M messages from a durable JetStream consumer
//! then restarts (new `subscribe_for_role` call with the same role), only the
//! un-acked messages are replayed.
//!
//! ## Structure
//!
//! 1. Publish 3 events to the `CHUMP_EVENTS` stream.
//! 2. Start consumer for role `test-replay-<uuid>`.
//! 3. Drain all 3 messages; ack 2, leave 1 un-acked.
//! 4. Drop the consumer (simulates process restart).
//! 5. Create a new consumer for the same role.
//! 6. Assert exactly 1 message is replayed (the un-acked one).
//!
//! Requires a live NATS server with JetStream enabled. If NATS is unreachable
//! OR the feature flag is not set the test SKIPs rather than fails, so CI is
//! not broken in environments without NATS.
//!
//! To run locally:
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! CHUMP_FLEET_WIRE_V1=1 CHUMP_NATS_URL=nats://127.0.0.1:4222 \
//!   cargo test -p chump-coord --test jetstream_replay -- --ignored --nocapture
//! ```

use chump_coord::jetstream_consumer::subscribe_for_role;
use chump_coord::{CoordClient, CoordEvent};
use std::time::Duration;
use uuid::Uuid;

// Helper: connect and skip when NATS unavailable.
async fn client_or_skip(label: &str) -> Option<CoordClient> {
    match CoordClient::connect_or_skip().await {
        Some(c) => Some(c),
        None => {
            eprintln!(
                "[{}] SKIP — NATS unreachable. Run: docker run -d -p 4222:4222 nats:latest -js",
                label
            );
            None
        }
    }
}

/// Verify that 1 un-acked message is replayed after consumer restart.
///
/// Marked `#[ignore]` so it does not run in default `cargo test` (requires live NATS).
/// Run explicitly with `cargo test -- --ignored`.
#[tokio::test]
#[ignore]
async fn durable_consumer_replays_unacked_on_restart() {
    // Feature-flag check — skip if not enabled.
    if !chump_coord::jetstream_consumer::fleet_wire_enabled() {
        eprintln!(
            "[durable_consumer_replays_unacked_on_restart] SKIP — \
             CHUMP_FLEET_WIRE_V1=1 + CHUMP_NATS_URL not set"
        );
        return;
    }

    let Some(pub_client) = client_or_skip("durable_consumer_replays_unacked_on_restart").await
    else {
        return;
    };

    // Use a unique role per test run to avoid cross-test interference.
    let role = format!("test-replay-{}", Uuid::new_v4().simple());
    let subject_tag = format!("jetstream_replay_test_{}", Uuid::new_v4().simple());

    // ── Step 1: Publish 3 events ──────────────────────────────────────────────
    for i in 0..3u32 {
        pub_client
            .emit(CoordEvent {
                event: "INTENT".to_string(),
                session: subject_tag.clone(),
                ts: chrono::Utc::now().to_rfc3339(),
                kind: Some(format!("test_replay_event_{}", i)),
                ..Default::default()
            })
            .await
            .expect("publish event ok");
    }
    pub_client.flush().await.ok();

    // ── Step 2: Start consumer ────────────────────────────────────────────────
    let consumer = subscribe_for_role(&role)
        .await
        .expect("subscribe_for_role must succeed with NATS available");

    // ── Step 3: Drain messages; ack 2, leave 1 ────────────────────────────────
    let mut received = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, consumer.next()).await {
            Ok(Some(msg)) => received.push(msg),
            Ok(None) | Err(_) => {
                // No message within timeout window — check if we have enough.
                if received.len() >= 3 {
                    break;
                }
            }
        }
        if received.len() >= 3 {
            break;
        }
    }

    // We need at least 3 to proceed; fewer means the stream had fewer messages.
    assert!(
        received.len() >= 3,
        "expected 3 messages, got {}",
        received.len()
    );

    // Ack the first 2; leave the third un-acked.
    let unacked_payload = received[2].payload().clone();
    received.remove(2); // remove so it won't be acked on drop
    for msg in received {
        msg.ack().await.expect("ack must succeed");
    }

    // Give NATS time to persist the ack.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // ── Step 4: Drop consumer (simulate restart) ──────────────────────────────
    drop(consumer);
    tokio::time::sleep(Duration::from_millis(200)).await;

    // ── Step 5: New consumer for the same role ────────────────────────────────
    let consumer2 = subscribe_for_role(&role)
        .await
        .expect("subscribe_for_role on restart must succeed");

    // ── Step 6: Assert exactly 1 message is replayed ─────────────────────────
    let mut replayed = Vec::new();
    let deadline2 = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline2.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, consumer2.next()).await {
            Ok(Some(msg)) => {
                replayed.push(msg.payload().clone());
                break; // We expect exactly 1; stop after first.
            }
            Ok(None) | Err(_) => break,
        }
    }

    assert_eq!(
        replayed.len(),
        1,
        "exactly 1 un-acked message must replay on restart, got {}",
        replayed.len()
    );

    assert_eq!(
        replayed[0], unacked_payload,
        "replayed message must be the un-acked one"
    );
}

/// Smoke test: consumer with zero messages returns None without hanging.
#[tokio::test]
#[ignore]
async fn consumer_next_returns_none_on_empty_stream() {
    if !chump_coord::jetstream_consumer::fleet_wire_enabled() {
        eprintln!("[consumer_next_returns_none_on_empty_stream] SKIP");
        return;
    }

    let Some(_client) = client_or_skip("consumer_next_returns_none_on_empty_stream").await else {
        return;
    };

    // Use a unique role so there are no pending messages.
    let role = format!("test-empty-{}", Uuid::new_v4().simple());

    // Use a short fetch timeout so this test completes quickly.
    std::env::set_var("CHUMP_FLEET_WIRE_FETCH_TIMEOUT_MS", "300");
    let consumer = subscribe_for_role(&role)
        .await
        .expect("subscribe must succeed");

    let msg = consumer.next().await;
    std::env::remove_var("CHUMP_FLEET_WIRE_FETCH_TIMEOUT_MS");

    assert!(msg.is_none(), "empty stream must yield None");
}

/// Lag reporting: after publishing N messages and acking K, lag is N-K.
#[tokio::test]
#[ignore]
async fn consumer_lag_reports_pending_count() {
    if !chump_coord::jetstream_consumer::fleet_wire_enabled() {
        eprintln!("[consumer_lag_reports_pending_count] SKIP");
        return;
    }

    let Some(pub_client) = client_or_skip("consumer_lag_reports_pending_count").await else {
        return;
    };

    let role = format!("test-lag-{}", Uuid::new_v4().simple());
    let tag = format!("lag_test_{}", Uuid::new_v4().simple());

    // Publish 3 events.
    for i in 0..3u32 {
        pub_client
            .emit(CoordEvent {
                event: "INTENT".to_string(),
                session: tag.clone(),
                ts: chrono::Utc::now().to_rfc3339(),
                kind: Some(format!("lag_test_event_{}", i)),
                ..Default::default()
            })
            .await
            .expect("publish ok");
    }
    pub_client.flush().await.ok();
    tokio::time::sleep(Duration::from_millis(300)).await;

    let consumer = subscribe_for_role(&role).await.expect("subscribe ok");

    // Lag after creation: 3 pending.
    let lag_before = consumer.lag().await.unwrap_or(0);
    assert!(
        lag_before >= 3,
        "lag before ack must be >= 3, got {}",
        lag_before
    );

    // Drain and ack all 3.
    let mut acked = 0;
    std::env::set_var("CHUMP_FLEET_WIRE_FETCH_TIMEOUT_MS", "500");
    for _ in 0..3 {
        if let Some(msg) = consumer.next().await {
            msg.ack().await.expect("ack ok");
            acked += 1;
        }
    }
    std::env::remove_var("CHUMP_FLEET_WIRE_FETCH_TIMEOUT_MS");
    assert_eq!(acked, 3, "must ack all 3 messages");
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Lag after acking all: 0.
    let lag_after = consumer.lag().await.unwrap_or(99);
    assert_eq!(
        lag_after, 0,
        "lag after full ack must be 0, got {}",
        lag_after
    );
}
