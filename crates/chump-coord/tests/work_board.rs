//! Integration tests for the FLEET-008 work board.
//!
//! Same skip-if-no-NATS pattern as `distributed_mutex.rs`: each test
//! that needs a broker calls `connect_or_skip` and early-returns when
//! NATS is unreachable, so CI without a NATS service container still
//! passes. Locally:
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test work_board -- --nocapture
//! ```
//!
//! Tests use a fresh, UUID-suffixed bucket per test (via
//! `CHUMP_NATS_WORK_BOARD_BUCKET`) so concurrent runs and replays
//! against the same NATS server never collide.

use chump_coord::work_board::{
    generate_subtask_id, Requirement, Subtask, SubtaskStatus, TransitionMiss,
};
use chump_coord::CoordClient;
use std::sync::Arc;

/// Connect to NATS or skip (return None) if unreachable. Each test
/// bumps the work-board bucket env to a unique value first so its
/// state is isolated.
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
    format!("test_wb_{}_{}", prefix, uuid::Uuid::new_v4().simple())
}

fn make_requirement(task_class: &str) -> Requirement {
    Requirement {
        task_class: task_class.to_string(),
        ..Default::default()
    }
}

#[tokio::test]
#[serial_test::serial]
async fn post_and_get_subtask_round_trip() {
    let bucket = unique_bucket("rt");
    unsafe {
        std::env::set_var("CHUMP_NATS_WORK_BOARD_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("post_and_get_subtask_round_trip").await else {
            return Ok::<(), &'static str>(());
        };
        let subtask = Subtask::new(
            "FLEET-024",
            "Demo: write tests for work board",
            "session-alpha",
            make_requirement("test-writing"),
        );
        client.post_subtask(&subtask).await.expect("post ok");
        let read = client
            .get_subtask(&subtask.subtask_id)
            .await
            .expect("get ok")
            .expect("subtask must exist");
        assert_eq!(read.subtask_id, subtask.subtask_id);
        assert_eq!(read.parent_gap, "FLEET-024");
        assert_eq!(read.requirement.task_class, "test-writing");
        assert_eq!(read.status, SubtaskStatus::Open);
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_WORK_BOARD_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn claim_transitions_open_to_claimed() {
    let bucket = unique_bucket("claim");
    unsafe {
        std::env::set_var("CHUMP_NATS_WORK_BOARD_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("claim_transitions_open_to_claimed").await else {
            return Ok::<(), &'static str>(());
        };
        let subtask = Subtask::new(
            "FLEET-024",
            "claim me",
            "poster",
            make_requirement("review"),
        );
        client.post_subtask(&subtask).await.unwrap();

        let claimed = client
            .claim_subtask(&subtask.subtask_id, "agent-bravo")
            .await
            .expect("no transport error")
            .expect("claim should succeed");
        assert_eq!(claimed.status, SubtaskStatus::Claimed);
        assert_eq!(claimed.claimed_by.as_deref(), Some("agent-bravo"));
        assert!(claimed.claimed_at.is_some());
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_WORK_BOARD_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn double_claim_loses_revision_race() {
    let bucket = unique_bucket("race");
    unsafe {
        std::env::set_var("CHUMP_NATS_WORK_BOARD_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("double_claim_loses_revision_race").await else {
            return Ok::<(), &'static str>(());
        };
        let client = Arc::new(client);
        let subtask = Subtask::new(
            "FLEET-024",
            "single-claim race",
            "poster",
            make_requirement("review"),
        );
        client.post_subtask(&subtask).await.unwrap();

        // Concurrent claims. Exactly one agent must succeed; everyone
        // else gets either `WrongState(Claimed)` (read after the winner
        // landed) or `StaleRevision` (read before, lost the CAS).
        const N: usize = 10;
        let mut handles = Vec::with_capacity(N);
        for i in 0..N {
            let c = Arc::clone(&client);
            let id = subtask.subtask_id.clone();
            handles.push(tokio::spawn(async move {
                c.claim_subtask(&id, &format!("session-{}", i)).await
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
                            | TransitionMiss::WrongState(SubtaskStatus::Claimed)
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
        std::env::remove_var("CHUMP_NATS_WORK_BOARD_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn complete_requires_claim_holder() {
    let bucket = unique_bucket("complete");
    unsafe {
        std::env::set_var("CHUMP_NATS_WORK_BOARD_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("complete_requires_claim_holder").await else {
            return Ok::<(), &'static str>(());
        };
        let subtask = Subtask::new(
            "FLEET-024",
            "complete-auth",
            "poster",
            make_requirement("refactor"),
        );
        client.post_subtask(&subtask).await.unwrap();
        client
            .claim_subtask(&subtask.subtask_id, "the-holder")
            .await
            .unwrap()
            .unwrap();

        // An imposter cannot complete a claim it doesn't hold.
        let denied = client
            .complete_subtask(&subtask.subtask_id, "the-imposter", Some("abc1234"))
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

        // The actual holder can complete it.
        let completed = client
            .complete_subtask(&subtask.subtask_id, "the-holder", Some("PR#42"))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(completed.status, SubtaskStatus::Completed);
        assert_eq!(completed.completed_commit.as_deref(), Some("PR#42"));
        assert!(completed.completed_at.is_some());

        // Re-completion is rejected by the WrongState check.
        let again = client
            .complete_subtask(&subtask.subtask_id, "the-holder", None)
            .await
            .unwrap()
            .expect_err("second complete must be rejected");
        assert!(matches!(
            again,
            TransitionMiss::WrongState(SubtaskStatus::Completed)
        ));
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_WORK_BOARD_BUCKET");
    }
    result.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn list_subtasks_filters_by_status() {
    let bucket = unique_bucket("list");
    unsafe {
        std::env::set_var("CHUMP_NATS_WORK_BOARD_BUCKET", &bucket);
    }
    let result = async {
        let Some(client) = connect_or_skip("list_subtasks_filters_by_status").await else {
            return Ok::<(), &'static str>(());
        };
        // Post 3 subtasks; claim one; complete another.
        let mut posted_ids = Vec::new();
        for i in 0..3 {
            let s = Subtask::new(
                "FLEET-024",
                &format!("subtask-{}", i),
                "poster",
                make_requirement("review"),
            );
            client.post_subtask(&s).await.unwrap();
            posted_ids.push(s.subtask_id);
        }
        client
            .claim_subtask(&posted_ids[0], "agent-x")
            .await
            .unwrap()
            .unwrap();
        client
            .claim_subtask(&posted_ids[1], "agent-y")
            .await
            .unwrap()
            .unwrap();
        client
            .complete_subtask(&posted_ids[1], "agent-y", Some("done"))
            .await
            .unwrap()
            .unwrap();

        let open = client
            .list_subtasks(Some(SubtaskStatus::Open))
            .await
            .unwrap();
        let claimed = client
            .list_subtasks(Some(SubtaskStatus::Claimed))
            .await
            .unwrap();
        let completed = client
            .list_subtasks(Some(SubtaskStatus::Completed))
            .await
            .unwrap();
        let all = client.list_subtasks(None).await.unwrap();
        assert!(open.iter().any(|s| s.subtask_id == posted_ids[2]));
        assert!(claimed.iter().any(|s| s.subtask_id == posted_ids[0]));
        assert!(completed.iter().any(|s| s.subtask_id == posted_ids[1]));
        assert!(all.len() >= 3);
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_WORK_BOARD_BUCKET");
    }
    result.unwrap();
}

#[test]
fn subtask_ids_are_unique() {
    let mut ids = std::collections::HashSet::new();
    for _ in 0..1000 {
        let id = generate_subtask_id();
        assert!(id.starts_with("SUBTASK-"));
        assert_eq!(id.len(), "SUBTASK-".len() + 8);
        assert!(ids.insert(id), "duplicate subtask id generated");
    }
}
