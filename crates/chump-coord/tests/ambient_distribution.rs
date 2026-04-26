//! FLEET-006: round-trip integration test for the ambient-stream NATS
//! distribution path.
//!
//! What this verifies: an event published via [`CoordClient::emit`] is
//! delivered to a separately-connected subscriber on `chump.events.>` —
//! i.e. the property that makes the ambient stream visible across
//! machines, closing the split-brain that FLEET-007 left behind (file
//! leases on NATS, but ambient.jsonl still local-only).
//!
//! Like `distributed_mutex.rs`, this test SKIPs (returns early) when no
//! NATS server is reachable so CI without a service container still
//! passes. Locally:
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test ambient_distribution -- --nocapture
//! ```

use chump_coord::{CoordClient, CoordEvent, EVENTS_SUBJECT};
use futures::StreamExt;
use std::time::Duration;

async fn connect_or_skip(test_name: &str) -> Option<CoordClient> {
    match CoordClient::connect_or_skip().await {
        Some(c) => Some(c),
        None => {
            eprintln!(
                "[{}] SKIP — NATS unreachable. Run: docker run -d -p 4222:4222 nats:latest -js",
                test_name
            );
            None
        }
    }
}

#[tokio::test]
async fn emit_round_trips_to_subscriber() {
    let Some(publisher) = connect_or_skip("emit_round_trips_to_subscriber").await else {
        return;
    };
    let Some(subscriber) = connect_or_skip("emit_round_trips_to_subscriber.sub").await else {
        return;
    };

    // Subscribe before publishing so we don't race the message.
    let subject_pattern = format!("{}.>", EVENTS_SUBJECT);
    let mut sub = subscriber
        .nats
        .subscribe(subject_pattern)
        .await
        .expect("subscribe ok");

    // Unique session ID so concurrent test runs don't see each other's events.
    let unique_session = format!("fleet-006-test-{}", uuid::Uuid::new_v4());
    let event = CoordEvent {
        event: "ambient_test".to_string(),
        session: unique_session.clone(),
        ts: chrono::Utc::now().to_rfc3339(),
        gap: Some("FLEET-006".to_string()),
        reason: Some("round-trip".to_string()),
        ..Default::default()
    };
    publisher.emit(event).await.expect("emit ok");
    publisher.flush().await.ok();

    // Wait for our specific event (filter by session ID).
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            panic!("did not observe published event within 5s — distribution broken");
        }
        let next = match tokio::time::timeout(remaining, sub.next()).await {
            Ok(Some(msg)) => msg,
            Ok(None) => panic!("subscription closed unexpectedly"),
            Err(_) => panic!("timed out waiting for event"),
        };
        let payload = String::from_utf8_lossy(&next.payload);
        let parsed: CoordEvent = match serde_json::from_str(&payload) {
            Ok(e) => e,
            Err(_) => continue,
        };
        if parsed.session == unique_session {
            assert_eq!(parsed.event, "ambient_test");
            assert_eq!(parsed.gap.as_deref(), Some("FLEET-006"));
            assert_eq!(parsed.reason.as_deref(), Some("round-trip"));
            return;
        }
    }
}

/// Subjects are derived from the lower-cased event name, so a custom
/// kind ("adversary_alert", "discord_intent", "session_start") fans out
/// to its own subject and a `chump.events.>` wildcard catches them all.
#[tokio::test]
async fn custom_event_kinds_route_to_their_subjects() {
    let Some(publisher) = connect_or_skip("custom_event_kinds_route_to_their_subjects").await
    else {
        return;
    };
    let Some(subscriber) = connect_or_skip("custom_event_kinds_route_to_their_subjects.sub").await
    else {
        return;
    };

    let unique_session = format!("fleet-006-kinds-{}", uuid::Uuid::new_v4());

    // Subscribe to the specific subject the adversary path will publish to.
    let mut adv_sub = subscriber
        .nats
        .subscribe(format!("{}.adversary_alert", EVENTS_SUBJECT))
        .await
        .expect("subscribe ok");

    publisher
        .emit(CoordEvent {
            event: "adversary_alert".to_string(),
            session: unique_session.clone(),
            ts: chrono::Utc::now().to_rfc3339(),
            reason: Some("test rule fired".to_string()),
            ..Default::default()
        })
        .await
        .expect("emit ok");
    publisher.flush().await.ok();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            panic!("adversary_alert did not arrive on its subject within 5s");
        }
        let msg = match tokio::time::timeout(remaining, adv_sub.next()).await {
            Ok(Some(m)) => m,
            Ok(None) => panic!("subscription closed unexpectedly"),
            Err(_) => panic!("timed out"),
        };
        let payload = String::from_utf8_lossy(&msg.payload);
        let Ok(ev) = serde_json::from_str::<CoordEvent>(&payload) else {
            continue;
        };
        if ev.session == unique_session {
            assert_eq!(ev.event, "adversary_alert");
            return;
        }
    }
}
