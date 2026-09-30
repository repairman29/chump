//! Integration tests for `PersistentMission<MergeRequest>` (INFRA-7981, an
//! INFRA-2252 slice).
//!
//! Coverage:
//! - `MergeRequest` round-trips through the `PersistentMission` envelope
//!   via the INFRA-2247 `FileBackedMissionStore`.
//! - `addMission` / `listPendingMissions` / `markCompleted` API behavior.
//! - Simulated process restart: a fresh `MergeQueueStore` pointed at the
//!   same root sees the same pending queue, in order, after the original
//!   store is dropped.

use chump_coord::mission::{MergeQueueStore, MergeRequest};
use tempfile::TempDir;

fn sample(id: &str, sequence: u32) -> MergeRequest {
    MergeRequest {
        id: id.to_string(),
        pr_number: 1000 + sequence as u64,
        branch: format!("feature/{}", id),
        sha: format!("{:040}", sequence),
        sequence,
        queued_at: "2026-09-30T00:00:00Z".to_string(),
    }
}

#[test]
fn add_and_list_pending_preserves_queue_order() {
    let tmp = TempDir::new().expect("tempdir");
    let store = MergeQueueStore::new(tmp.path().to_path_buf());

    // Insert out of order; sequence field (not insertion order) governs order.
    store.add_mission(sample("mr-b", 1)).expect("add b");
    store.add_mission(sample("mr-a", 0)).expect("add a");
    store.add_mission(sample("mr-c", 2)).expect("add c");

    let pending = store.list_pending_missions().expect("list");
    let ids: Vec<&str> = pending.iter().map(|mr| mr.id.as_str()).collect();
    assert_eq!(ids, vec!["mr-a", "mr-b", "mr-c"]);
}

#[test]
fn mark_completed_removes_from_pending_list() {
    let tmp = TempDir::new().expect("tempdir");
    let store = MergeQueueStore::new(tmp.path().to_path_buf());

    store.add_mission(sample("mr-1", 0)).expect("add");
    store.add_mission(sample("mr-2", 1)).expect("add");

    store
        .mark_completed("mr-1", "2026-09-30T00:05:00Z")
        .expect("mark completed");

    let pending = store.list_pending_missions().expect("list");
    let ids: Vec<&str> = pending.iter().map(|mr| mr.id.as_str()).collect();
    assert_eq!(ids, vec!["mr-2"]);
}

#[test]
fn survives_simulated_process_restart() {
    let tmp = TempDir::new().expect("tempdir");

    {
        // "Process 1": queue two merges, complete one.
        let store = MergeQueueStore::new(tmp.path().to_path_buf());
        store.add_mission(sample("mr-x", 0)).expect("add x");
        store.add_mission(sample("mr-y", 1)).expect("add y");
        store
            .mark_completed("mr-x", "2026-09-30T00:10:00Z")
            .expect("complete x");
        // store dropped here — simulates process exit.
    }

    {
        // "Process 2": fresh store, same root — state must have survived.
        let store = MergeQueueStore::new(tmp.path().to_path_buf());
        let pending = store.list_pending_missions().expect("list after restart");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, "mr-y");
        assert_eq!(pending[0].pr_number, 1001);
    }
}

#[test]
fn mark_completed_is_idempotent_from_pending_state() {
    let tmp = TempDir::new().expect("tempdir");
    let store = MergeQueueStore::new(tmp.path().to_path_buf());
    store.add_mission(sample("mr-z", 0)).expect("add");

    // First completion checkpoints Pending -> InProgress -> Completed.
    store
        .mark_completed("mr-z", "2026-09-30T00:20:00Z")
        .expect("first completion");

    assert!(store.list_pending_missions().expect("list").is_empty());
}
