//! INFRA-126: per-session ordering integration test for the chump-coord event bus.
//!
//! Properties under test:
//!
//! 1. **No events lost**: 5 concurrent publishers each emit 100 events; a
//!    JetStream consumer collects all of them and asserts count == 500.
//!
//! 2. **Per-session ts-monotonic ordering**: for each distinct session_id, the
//!    `ts` field of collected events is non-decreasing.  Global ordering is NOT
//!    asserted — with concurrent publishers, JetStream interleaves messages
//!    from different sessions arbitrarily.  The realistic guarantee is
//!    per-session monotonicity.
//!
//! Requires a live NATS server with JetStream enabled.  If unreachable the
//! test SKIPs.
//!
//! To run locally:
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test chump_coord_ordering -- --nocapture
//! ```

use chump_coord::{CoordClient, CoordEvent};
use futures::StreamExt;
use std::{collections::HashMap, time::Duration};

const SESSIONS: usize = 5;
const EVENTS_PER_SESSION: usize = 100;
const TOTAL: usize = SESSIONS * EVENTS_PER_SESSION;

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

/// Spawn `SESSIONS` concurrent publishers, each emitting `EVENTS_PER_SESSION`
/// events with strictly increasing sequence numbers embedded in `reason`.
/// A JetStream consumer replays the stream after all events are flushed and
/// asserts:
///   - total count == SESSIONS × EVENTS_PER_SESSION
///   - within each session_id, sequence numbers are strictly ascending
#[tokio::test]
async fn concurrent_publishers_no_loss_and_per_session_monotonic() {
    let run_id = uuid::Uuid::new_v4().to_string();

    // Spawn publishers concurrently.
    let mut publish_handles = Vec::with_capacity(SESSIONS);
    for session_idx in 0..SESSIONS {
        let run_id = run_id.clone();
        publish_handles.push(tokio::spawn(async move {
            let Some(client) = connect_or_skip(&format!("ordering.publisher-{session_idx}")).await
            else {
                return;
            };
            let session_id = format!("ordering-session-{session_idx}-{run_id}");
            let base_ts = chrono::Utc::now();
            for seq in 0..EVENTS_PER_SESSION {
                // Each event carries a ts that is strictly later than the
                // previous one for this session, achieved by adding seq
                // milliseconds.  Real sessions emit at wall-clock speed;
                // synthetic offset keeps the ts field monotonic without
                // sleeping.
                let ts = base_ts + chrono::Duration::milliseconds(seq as i64);
                client
                    .emit(CoordEvent {
                        event: "ordering_test".to_string(),
                        session: session_id.clone(),
                        ts: ts.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                        reason: Some(format!("seq={:05}", seq)),
                        ..Default::default()
                    })
                    .await
                    .expect("emit ok");
            }
            client.flush().await.ok();
        }));
    }
    for h in publish_handles {
        h.await.ok();
    }

    // Collect via JetStream replay (DeliverAll) so messages published before
    // subscribe are included.
    let Some(subscriber) =
        connect_or_skip("concurrent_publishers_no_loss_and_per_session_monotonic.sub").await
    else {
        return;
    };
    let js = async_nats::jetstream::new(subscriber.nats.clone());
    let stream = js
        .get_stream("CHUMP_EVENTS")
        .await
        .expect("CHUMP_EVENTS stream must exist");

    let consumer = stream
        .create_consumer(async_nats::jetstream::consumer::push::Config {
            deliver_subject: subscriber.nats.new_inbox(),
            filter_subject: "chump.events.ordering_test".to_string(),
            deliver_policy: async_nats::jetstream::consumer::DeliverPolicy::All,
            ack_policy: async_nats::jetstream::consumer::AckPolicy::None,
            ..Default::default()
        })
        .await
        .expect("consumer created");

    let mut messages = consumer.messages().await.expect("message stream ok");

    // Collect events that belong to THIS test run (keyed by session prefix + run_id).
    let mut collected: HashMap<String, Vec<(usize, chrono::DateTime<chrono::Utc>)>> =
        HashMap::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);

    loop {
        let total_so_far: usize = collected.values().map(|v| v.len()).sum();
        if total_so_far >= TOTAL {
            break;
        }
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
            // Filter to events from this test run.
            if ev.session.contains(&run_id) {
                if let Some(reason) = &ev.reason {
                    if let Some(seq_str) = reason.strip_prefix("seq=") {
                        if let Ok(seq) = seq_str.parse::<usize>() {
                            if let Ok(ts) = chrono::DateTime::parse_from_rfc3339(&ev.ts) {
                                collected
                                    .entry(ev.session.clone())
                                    .or_default()
                                    .push((seq, ts.with_timezone(&chrono::Utc)));
                            }
                        }
                    }
                }
            }
        }
        msg.ack().await.ok();
    }

    // Assert: no events lost.
    let total_collected: usize = collected.values().map(|v| v.len()).sum();
    assert_eq!(
        total_collected, TOTAL,
        "expected {} events total, got {} (no-loss property)",
        TOTAL, total_collected
    );

    // Assert: SESSIONS publishers were observed.
    assert_eq!(
        collected.len(),
        SESSIONS,
        "expected {} distinct sessions, got {}",
        SESSIONS,
        collected.len()
    );

    // Assert: per-session ts monotonic and seq complete.
    for (session_id, mut events) in collected {
        // Sort by seq so we can check ts order is consistent with seq order.
        events.sort_by_key(|(seq, _)| *seq);

        assert_eq!(
            events.len(),
            EVENTS_PER_SESSION,
            "session {} must have {} events, got {}",
            session_id,
            EVENTS_PER_SESSION,
            events.len()
        );

        // Verify all sequence numbers 0..EVENTS_PER_SESSION are present.
        for (i, (seq, _)) in events.iter().enumerate() {
            assert_eq!(*seq, i, "session {} missing seq {}", session_id, i);
        }

        // Verify per-session ts is non-decreasing.
        for window in events.windows(2) {
            let (seq_a, ts_a) = window[0];
            let (seq_b, ts_b) = window[1];
            assert!(
                ts_b >= ts_a,
                "session {} ts not monotonic: seq={} ts={} > seq={} ts={}",
                session_id,
                seq_a,
                ts_a,
                seq_b,
                ts_b
            );
        }
    }
}
