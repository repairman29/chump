//! INFRA-126: idempotent-replay integration test for the chump-coord event bus.
//!
//! Property under test: when the same agent emits an INTENT event twice with
//! the same session_id+gap_id, the gap claim remains singly-held.  Downstream
//! watchers may receive both JetStream messages (NATS does not deduplicate
//! without a Nats-Msg-Id header), but the authoritative claim state in the KV
//! store is idempotent: a second `try_claim_gap` call from the same session
//! returns false (already held) rather than double-inserting.
//!
//! The test also verifies that a competing session cannot sneak in a claim
//! between two INTENT emits from the first agent.
//!
//! Requires a live NATS server with JetStream enabled.  If unreachable the
//! test SKIPs.
//!
//! To run locally:
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test chump_coord_replay -- --nocapture
//! ```

use chump_coord::{CoordClient, CoordEvent};
use futures::StreamExt;
use std::time::Duration;

async fn connect_or_skip(label: &str) -> Option<CoordClient> {
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

fn unique_gap_id(prefix: &str) -> String {
    format!("{}-{}", prefix, uuid::Uuid::new_v4())
}

/// Emit the same INTENT twice; verify the claim is held exactly once and a
/// competing session still cannot claim the gap.
#[tokio::test]
async fn double_intent_does_not_double_claim() {
    let Some(client) = connect_or_skip("double_intent_does_not_double_claim").await else {
        return;
    };
    let Some(competitor) = connect_or_skip("double_intent_does_not_double_claim.competitor").await
    else {
        return;
    };

    let gap = unique_gap_id("INFRA-126-REPLAY-A");
    let session = "replay-session-alpha";

    // First INTENT + claim.
    client
        .emit_intent(session, &gap, "src/main.rs")
        .await
        .expect("first emit ok");
    let first_claim = client
        .try_claim_gap(&gap, session)
        .await
        .expect("first claim ok");
    assert!(first_claim, "first claim must succeed");

    // Simulate network retry: same INTENT emitted again (duplicate publish).
    client
        .emit_intent(session, &gap, "src/main.rs")
        .await
        .expect("second emit ok");

    // Second try_claim_gap from the same session returns false — already held.
    let second_claim = client
        .try_claim_gap(&gap, session)
        .await
        .expect("second claim call ok");
    assert!(
        !second_claim,
        "second claim from same session must return false (already held)"
    );

    // A competing session also cannot claim the gap.
    let competitor_claim = competitor
        .try_claim_gap(&gap, "replay-session-beta")
        .await
        .expect("competitor claim ok");
    assert!(
        !competitor_claim,
        "competitor must not be able to claim a gap held by replay-session-alpha"
    );

    // The stored claim still belongs to the original session.
    let holder = client
        .gap_claim(&gap)
        .await
        .expect("read claim ok")
        .expect("claim must exist");
    assert_eq!(holder.session_id, session, "claim holder must be unchanged");

    client.release_gap(&gap).await.ok();
}

/// Verify that releasing and re-claiming the same gap from the same session
/// produces exactly one active claim at any point in time (no phantom
/// double-entries from the two INTENT events).
#[tokio::test]
async fn release_and_reclaim_after_duplicate_intent() {
    let Some(client) = connect_or_skip("release_and_reclaim_after_duplicate_intent").await else {
        return;
    };

    let gap = unique_gap_id("INFRA-126-REPLAY-B");
    let session = "replay-reclaim-session";

    // Emit two INTENTs, claim, release, reclaim — all should work cleanly.
    client
        .emit_intent(session, &gap, "crates/foo/src/lib.rs")
        .await
        .expect("emit 1 ok");
    client
        .emit_intent(session, &gap, "crates/foo/src/lib.rs")
        .await
        .expect("emit 2 ok");

    assert!(
        client.try_claim_gap(&gap, session).await.unwrap(),
        "claim after two intents must succeed"
    );
    client.release_gap(&gap).await.expect("release ok");

    // Reclaim after release — the duplicate INTENT events in the stream do
    // not prevent a clean reclaim.
    assert!(
        client.try_claim_gap(&gap, session).await.unwrap(),
        "reclaim after release must succeed even with prior duplicate intents"
    );
    client.release_gap(&gap).await.ok();
}

/// A late-joining subscriber replaying the event stream receives both copies
/// of the duplicate INTENT.  This test documents the current behaviour: NATS
/// JetStream does not deduplicate unless a `Nats-Msg-Id` header is supplied.
/// The claim layer (KV CAS) is what enforces uniqueness, not the event bus.
#[tokio::test]
async fn late_subscriber_sees_replay_of_all_events() {
    let Some(publisher) = connect_or_skip("late_subscriber_sees_replay_of_all_events.pub").await
    else {
        return;
    };

    let unique_session = format!("replay-late-{}", uuid::Uuid::new_v4());
    let gap = unique_gap_id("INFRA-126-REPLAY-LATE");

    // Publish two identical INTENTs (same session + gap, different timestamps).
    for _ in 0..2 {
        publisher
            .emit(CoordEvent {
                event: "INTENT".to_string(),
                session: unique_session.clone(),
                ts: chrono::Utc::now().to_rfc3339(),
                gap: Some(gap.clone()),
                files: Some("late-join-test".to_string()),
                ..Default::default()
            })
            .await
            .expect("emit ok");
    }
    publisher.flush().await.ok();

    // Late subscriber joins AFTER the events were published and replays via
    // deliver_policy=All (JetStream default for `subscribe` is push-based
    // core NATS — use the jetstream consumer for guaranteed replay).
    let Some(subscriber) = connect_or_skip("late_subscriber_sees_replay_of_all_events.sub").await
    else {
        return;
    };

    // Use a JetStream push consumer with DeliverAll so events published
    // before the subscribe are replayed.
    let js = async_nats::jetstream::new(subscriber.nats.clone());
    let subject = "chump.events.intent".to_string();

    // Create an ephemeral push consumer on the stream (durable="" = ephemeral).
    let stream = js
        .get_stream("CHUMP_EVENTS")
        .await
        .expect("stream must exist after publish");
    let consumer = stream
        .create_consumer(async_nats::jetstream::consumer::push::Config {
            deliver_subject: subscriber.nats.new_inbox(),
            filter_subject: subject.clone(),
            deliver_policy: async_nats::jetstream::consumer::DeliverPolicy::All,
            ack_policy: async_nats::jetstream::consumer::AckPolicy::None,
            ..Default::default()
        })
        .await
        .expect("consumer created");

    let mut messages = consumer.messages().await.expect("message stream ok");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut received = 0usize;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        let Ok(Some(msg)) = tokio::time::timeout(remaining, messages.next()).await else {
            break;
        };
        let Ok(msg) = msg else { break };
        let payload = String::from_utf8_lossy(&msg.payload);
        if let Ok(ev) = serde_json::from_str::<CoordEvent>(&payload) {
            if ev.session == unique_session {
                received += 1;
                if received >= 2 {
                    break;
                }
            }
        }
        msg.ack().await.ok();
    }

    // Current behaviour: both copies are stored and replayed.  The claim
    // layer (KV CAS) prevents double-claiming, not the event bus.
    assert_eq!(
        received, 2,
        "late subscriber must see both copies of the duplicate INTENT \
         (JetStream stores all; KV CAS enforces claim uniqueness)"
    );
}
