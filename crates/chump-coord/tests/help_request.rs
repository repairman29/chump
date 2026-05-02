//! Integration tests for the FLEET-010 help-seeking protocol.
//!
//! Same skip-if-no-NATS pattern as `work_board.rs` and
//! `distributed_mutex.rs`: each test that needs a broker calls
//! `connect_or_skip` and early-returns when NATS is unreachable, so
//! CI without a NATS service container still passes.
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test help_request -- --nocapture
//! ```

use chump_coord::help_request::{generate_help_id, BlockerType, HelpRequest, HelpStatus};
use chump_coord::work_board::TransitionMiss;
use chump_coord::CoordClient;
use std::sync::Arc;

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

fn unique_bucket(prefix: &str) -> String {
    format!("test_help_{}_{}", prefix, uuid::Uuid::new_v4().simple())
}

#[tokio::test]
#[serial_test::serial]
async fn post_and_get_help_request_round_trip() {
    let bucket = unique_bucket("rt");
    unsafe {
        std::env::set_var("CHUMP_NATS_HELP_REQUESTS_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("post_and_get_help_request_round_trip").await else {
            return Ok::<(), &'static str>(());
        };
        let req = HelpRequest::new(
            BlockerType::MissingCapability,
            "need a reviewer with anthropic family",
            "session-alpha",
        )
        .with_parent_gap("FLEET-024")
        .with_needed_capability("review")
        .blocking();
        client.post_help_request(&req).await.expect("post ok");
        let read = client
            .get_help_request(&req.help_id)
            .await
            .expect("get ok")
            .expect("must exist");
        assert_eq!(read.help_id, req.help_id);
        assert_eq!(read.parent_gap.as_deref(), Some("FLEET-024"));
        assert_eq!(read.needed_capability.as_deref(), Some("review"));
        assert_eq!(read.blocker_type, BlockerType::MissingCapability);
        assert!(read.blocking);
        assert_eq!(read.status, HelpStatus::Open);
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_HELP_REQUESTS_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn claim_transitions_open_to_claimed() {
    let bucket = unique_bucket("claim");
    unsafe {
        std::env::set_var("CHUMP_NATS_HELP_REQUESTS_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("claim_transitions_open_to_claimed").await else {
            return Ok::<(), &'static str>(());
        };
        let req = HelpRequest::new(BlockerType::Timeout, "ran past 60min budget", "poster");
        client.post_help_request(&req).await.unwrap();

        let claimed = client
            .claim_help_request(&req.help_id, "agent-bravo")
            .await
            .expect("no transport error")
            .expect("claim should succeed");
        assert_eq!(claimed.status, HelpStatus::Claimed);
        assert_eq!(claimed.claimed_by.as_deref(), Some("agent-bravo"));
        assert!(claimed.claimed_at.is_some());
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_HELP_REQUESTS_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn double_claim_loses_revision_race() {
    let bucket = unique_bucket("race");
    unsafe {
        std::env::set_var("CHUMP_NATS_HELP_REQUESTS_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("double_claim_loses_revision_race").await else {
            return Ok::<(), &'static str>(());
        };
        let client = Arc::new(client);
        let req = HelpRequest::new(BlockerType::UnknownTaskClass, "single-claim race", "poster");
        client.post_help_request(&req).await.unwrap();

        const N: usize = 8;
        let mut handles = Vec::with_capacity(N);
        for i in 0..N {
            let c = Arc::clone(&client);
            let id = req.help_id.clone();
            handles.push(tokio::spawn(async move {
                c.claim_help_request(&id, &format!("session-{}", i)).await
            }));
        }

        let mut wins = 0usize;
        for h in handles {
            let outcome = h.await.unwrap().expect("no transport error");
            match outcome {
                Ok(_) => wins += 1,
                Err(miss) => assert!(
                    matches!(
                        miss,
                        TransitionMiss::StaleRevision
                            | TransitionMiss::WrongState(
                                chump_coord::work_board::SubtaskStatus::Claimed
                            )
                    ),
                    "non-winner miss kind unexpected: {:?}",
                    miss
                ),
            }
        }
        assert_eq!(wins, 1, "exactly one agent must successfully claim");
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_HELP_REQUESTS_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn complete_requires_claim_holder() {
    let bucket = unique_bucket("complete");
    unsafe {
        std::env::set_var("CHUMP_NATS_HELP_REQUESTS_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("complete_requires_claim_holder").await else {
            return Ok::<(), &'static str>(());
        };
        let req = HelpRequest::new(BlockerType::Other, "complete-auth", "poster");
        client.post_help_request(&req).await.unwrap();
        client
            .claim_help_request(&req.help_id, "the-holder")
            .await
            .unwrap()
            .unwrap();

        // Imposter denied.
        let denied = client
            .complete_help_request(&req.help_id, "the-imposter", Some("PR#9"))
            .await
            .expect("no transport error")
            .expect_err("imposter must be rejected");
        match denied {
            TransitionMiss::NotClaimHolder { holder, caller } => {
                assert_eq!(holder, "the-holder");
                assert_eq!(caller, "the-imposter");
            }
            other => panic!("expected NotClaimHolder, got {:?}", other),
        }

        // Holder succeeds.
        let completed = client
            .complete_help_request(&req.help_id, "the-holder", Some("PR#42"))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(completed.status, HelpStatus::Completed);
        assert_eq!(completed.resolution.as_deref(), Some("PR#42"));
        assert!(completed.completed_at.is_some());

        // Re-completion rejected.
        let again = client
            .complete_help_request(&req.help_id, "the-holder", None)
            .await
            .unwrap()
            .expect_err("second complete must be rejected");
        assert!(matches!(again, TransitionMiss::WrongState(_)));
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_HELP_REQUESTS_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn fail_marks_terminal() {
    let bucket = unique_bucket("fail");
    unsafe {
        std::env::set_var("CHUMP_NATS_HELP_REQUESTS_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("fail_marks_terminal").await else {
            return Ok::<(), &'static str>(());
        };
        let req = HelpRequest::new(BlockerType::Other, "we will fail this", "poster");
        client.post_help_request(&req).await.unwrap();
        client
            .claim_help_request(&req.help_id, "responder")
            .await
            .unwrap()
            .unwrap();
        let failed = client
            .fail_help_request(&req.help_id, "responder", "could not reproduce blocker")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(failed.status, HelpStatus::Failed);
        assert_eq!(
            failed.failure_reason.as_deref(),
            Some("could not reproduce blocker")
        );
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_HELP_REQUESTS_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn list_filters_by_status_and_parent() {
    let bucket = unique_bucket("list");
    unsafe {
        std::env::set_var("CHUMP_NATS_HELP_REQUESTS_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("list_filters_by_status_and_parent").await else {
            return Ok::<(), &'static str>(());
        };
        // Three help requests with different parents/statuses.
        let r1 =
            HelpRequest::new(BlockerType::Timeout, "r1", "poster").with_parent_gap("FLEET-024");
        let r2 = HelpRequest::new(BlockerType::MissingCapability, "r2", "poster")
            .with_parent_subtask("SUBTASK-12345678");
        let r3 = HelpRequest::new(BlockerType::Other, "r3", "poster").with_parent_gap("FLEET-008");

        client.post_help_request(&r1).await.unwrap();
        client.post_help_request(&r2).await.unwrap();
        client.post_help_request(&r3).await.unwrap();

        // Claim + complete r3 to put it in Completed.
        client
            .claim_help_request(&r3.help_id, "responder")
            .await
            .unwrap()
            .unwrap();
        client
            .complete_help_request(&r3.help_id, "responder", Some("done"))
            .await
            .unwrap()
            .unwrap();

        // Filter: status=open
        let open = client
            .list_help_requests(Some(HelpStatus::Open), None, None)
            .await
            .unwrap();
        assert!(open.iter().any(|r| r.help_id == r1.help_id));
        assert!(open.iter().any(|r| r.help_id == r2.help_id));
        assert!(!open.iter().any(|r| r.help_id == r3.help_id));

        // Filter: parent_subtask
        let by_subtask = client
            .list_help_requests(None, Some("SUBTASK-12345678"), None)
            .await
            .unwrap();
        assert_eq!(by_subtask.len(), 1);
        assert_eq!(by_subtask[0].help_id, r2.help_id);

        // Filter: parent_gap=FLEET-024
        let by_gap = client
            .list_help_requests(None, None, Some("FLEET-024"))
            .await
            .unwrap();
        assert_eq!(by_gap.len(), 1);
        assert_eq!(by_gap[0].help_id, r1.help_id);

        // No filters → all three.
        let all = client.list_help_requests(None, None, None).await.unwrap();
        assert!(all.len() >= 3);
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_HELP_REQUESTS_BUCKET");
    }
    result.unwrap();
}

#[test]
fn help_ids_are_unique() {
    let mut ids = std::collections::HashSet::new();
    for _ in 0..1000 {
        let id = generate_help_id();
        assert!(id.starts_with("HELP-"));
        assert_eq!(id.len(), "HELP-".len() + 8);
        assert!(ids.insert(id), "duplicate help id generated");
    }
}
