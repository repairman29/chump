//! crates/chump-coord/tests/a2a_layer1a_react.rs — RESILIENT-334
//!
//! Proves the A2A L1a keystone: a worker SUBSCRIBES to the NATS bus and ACTS
//! on what it hears — end to end, worker -> bus -> worker, with no polling
//! of `list_subtasks` / the gap queue in the discovery path.
//!
//! Before this gap: `subscribe_events` existed (INFRA-1118/INFRA-2266) but
//! (a) nothing consumed WORK_POSTED events with it — every consumer either
//! printed (`chump-coord watch`) or discovered work by polling
//! `list_subtasks` on a timer — and (b) the wire shape published by
//! `work_board`/`help_request` (`{"event":"WORK_POSTED", "reason": <id>, ...}`)
//! didn't even deserialize into the subscribe-side `events::CoordEvent`
//! (`kind` was a required field with no alias to `event`), so those messages
//! were silently dropped by `run_nats_consumer`'s decode-error branch.
//!
//! Skips cleanly (never fails CI) when no NATS broker is reachable, matching
//! the pattern used by every other `a2a_layer1a*` / `work_board` test.

use chump_coord::events::EventFilter;
use chump_coord::nats_primary::subscribe_events_with_session;
use chump_coord::work_board::{Requirement, Subtask, SubtaskStatus};
use chump_coord::worker::{react_to_event, ReactOutcome};
use chump_coord::CoordClient;
use std::time::Duration;

async fn connect_or_skip(test_name: &str) -> Option<CoordClient> {
    match CoordClient::connect_or_skip().await {
        Some(c) => Some(c),
        None => {
            eprintln!("[{test_name}] SKIP — NATS unreachable");
            None
        }
    }
}

fn unique_bucket(prefix: &str) -> String {
    format!("test_react_{}_{}", prefix, uuid::Uuid::new_v4().simple())
}

/// The keystone test: session A posts a subtask to the work board; session B
/// is *only* driven by the subscribed event stream (never calls
/// `list_subtasks`) and reacts to the WORK_POSTED event by claiming it. If
/// this passes, a real coordination event flowed worker -> bus -> worker
/// with the KV store acting purely as the durable backlog, not the live
/// channel.
#[tokio::test]
#[serial_test::serial]
async fn worker_claims_subtask_reactively_from_bus_event_without_polling() {
    let bucket = unique_bucket("keystone");
    unsafe {
        std::env::set_var("CHUMP_NATS_WORK_BOARD_BUCKET", &bucket);
        std::env::set_var("CHUMP_A2A_LAYER", "1");
    }

    let result = async {
        let Some(poster) =
            connect_or_skip("worker_claims_subtask_reactively_from_bus_event_without_polling")
                .await
        else {
            return Ok::<(), &'static str>(());
        };
        let reactor = CoordClient::connect().await.expect("reactor connect");

        let session_b = format!("test-react-worker-{}", uuid::Uuid::new_v4().simple());

        // Session B subscribes FIRST — the whole point is that discovery
        // happens via the bus, so the consumer must exist before the event
        // is published.
        let mut stream = subscribe_events_with_session(EventFilter::All, Some(session_b.clone()))
            .await
            .expect("subscribe must succeed with NATS available");

        // Let the JetStream durable consumer actually attach before we publish.
        tokio::time::sleep(Duration::from_millis(300)).await;

        // Session A posts a subtask session B has never listed or polled for.
        let subtask = Subtask::new(
            "RESILIENT-334",
            "reactive-claim keystone probe",
            "test-react-poster",
            Requirement {
                task_class: "coord-test".to_string(),
                ..Default::default()
            },
        );
        let subtask_id = subtask.subtask_id.clone();
        poster.post_subtask(&subtask).await.expect("post ok");

        // Session B's ONLY source of truth here is the event it receives off
        // the bus — no list_subtasks call anywhere in this loop.
        let event = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .expect("WORK_POSTED must arrive within 5s")
            .expect("stream must not close");

        assert_eq!(
            event.kind, "WORK_POSTED",
            "event.kind must survive the wire bridge"
        );
        assert_eq!(
            event.payload.get("reason").and_then(|v| v.as_str()),
            Some(subtask_id.as_str()),
            "subtask id must be recoverable from the bridged payload"
        );

        let outcome = react_to_event(&reactor, &event, &session_b, |st| {
            st.requirement.task_class == "coord-test"
        })
        .await
        .expect("react_to_event must not error");

        let claimed = match outcome {
            ReactOutcome::Claimed(subtask) => *subtask,
            other => panic!("expected Claimed, got {other:?}"),
        };
        assert_eq!(claimed.subtask_id, subtask_id);
        assert_eq!(claimed.claimed_by.as_deref(), Some(session_b.as_str()));
        assert_eq!(claimed.status, SubtaskStatus::Claimed);

        // Ground-truth check against the durable backlog: the KV store
        // reflects the claim the bus event drove, confirming the queue is
        // the backlog (source of truth for who won) not the discovery path.
        let persisted = poster
            .get_subtask(&subtask_id)
            .await
            .expect("get ok")
            .expect("must exist");
        assert_eq!(persisted.claimed_by.as_deref(), Some(session_b.as_str()));

        Ok(())
    }
    .await;

    unsafe {
        std::env::remove_var("CHUMP_NATS_WORK_BOARD_BUCKET");
        std::env::remove_var("CHUMP_A2A_LAYER");
    }
    result.expect("test body");
}

/// A capability mismatch must NOT claim — proves `react_to_event` actually
/// gates on the caller's filter rather than blindly grabbing anything it
/// hears about.
#[tokio::test]
#[serial_test::serial]
async fn worker_skips_reactive_claim_on_capability_mismatch() {
    let bucket = unique_bucket("mismatch");
    unsafe {
        std::env::set_var("CHUMP_NATS_WORK_BOARD_BUCKET", &bucket);
        std::env::set_var("CHUMP_A2A_LAYER", "1");
    }

    let result = async {
        let Some(poster) =
            connect_or_skip("worker_skips_reactive_claim_on_capability_mismatch").await
        else {
            return Ok::<(), &'static str>(());
        };
        let reactor = CoordClient::connect().await.expect("reactor connect");
        let session_b = format!("test-react-nomatch-{}", uuid::Uuid::new_v4().simple());

        let mut stream = subscribe_events_with_session(EventFilter::All, Some(session_b.clone()))
            .await
            .expect("subscribe");
        tokio::time::sleep(Duration::from_millis(300)).await;

        let subtask = Subtask::new(
            "RESILIENT-334",
            "mismatch probe",
            "test-react-poster",
            Requirement {
                task_class: "needs-gpu".to_string(),
                ..Default::default()
            },
        );
        let subtask_id = subtask.subtask_id.clone();
        poster.post_subtask(&subtask).await.expect("post ok");

        let event = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .expect("event must arrive")
            .expect("stream must not close");

        let outcome = react_to_event(&reactor, &event, &session_b, |st| {
            st.requirement.task_class == "coord-test" // does not match "needs-gpu"
        })
        .await
        .expect("react_to_event must not error");

        assert!(
            matches!(outcome, ReactOutcome::Skipped),
            "expected Skipped on capability mismatch, got {outcome:?}"
        );

        let persisted = poster
            .get_subtask(&subtask_id)
            .await
            .expect("get ok")
            .expect("must exist");
        assert_eq!(
            persisted.status,
            SubtaskStatus::Open,
            "must remain unclaimed"
        );

        Ok(())
    }
    .await;

    unsafe {
        std::env::remove_var("CHUMP_NATS_WORK_BOARD_BUCKET");
        std::env::remove_var("CHUMP_A2A_LAYER");
    }
    result.expect("test body");
}
