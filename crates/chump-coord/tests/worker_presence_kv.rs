// crates/chump-coord/tests/worker_presence_kv.rs — CREDIBLE-246 (CREDIBLE-099 slice)
//
// Integration test for worker presence storage in NATS-KV:
//   AC-1: a worker presence record is stored on registration.
//   AC-2: the record is updated when presence changes (gap picked, ship/exit).
//
// Requires a live NATS server with JetStream enabled. If unreachable, tests SKIP.
//
// To run locally:
//   nats-server -js &
//   cargo test -p chump-coord --test worker_presence_kv -- --nocapture

use chump_coord::presence::{build_presence, PresenceStatus};
use chump_coord::CoordClient;
use serial_test::serial;
use uuid::Uuid;

async fn connect_or_skip(label: &str, bucket: &str) -> Option<CoordClient> {
    std::env::set_var("CHUMP_NATS_WORKERS_BUCKET", bucket);
    match CoordClient::connect_or_skip().await {
        Some(c) => Some(c),
        None => {
            eprintln!(
                "[{}] SKIP — NATS unreachable. Start: nats-server -js",
                label
            );
            std::env::remove_var("CHUMP_NATS_WORKERS_BUCKET");
            None
        }
    }
}

fn unique_bucket() -> String {
    format!("workers-test-{}", &Uuid::new_v4().to_string()[..8])
}

#[tokio::test]
#[serial]
async fn register_then_read_back() {
    let bucket = unique_bucket();
    let Some(client) = connect_or_skip("register_then_read_back", &bucket).await else {
        return;
    };

    let worker_id = format!("worker-{}", &Uuid::new_v4().to_string()[..8]);
    let presence = build_presence(&worker_id, Some("CREDIBLE-246".to_string()));

    client
        .register_worker_presence(&presence)
        .await
        .expect("register_worker_presence");

    let read_back = client
        .worker_presence(&worker_id)
        .await
        .expect("worker_presence")
        .expect("record should exist after registration");

    assert_eq!(read_back.worker_id, worker_id);
    assert_eq!(read_back.current_gap.as_deref(), Some("CREDIBLE-246"));
    assert_eq!(read_back.status, PresenceStatus::Active);

    std::env::remove_var("CHUMP_NATS_WORKERS_BUCKET");
}

#[tokio::test]
#[serial]
async fn update_gap_changes_current_gap_and_bumps_updated_at() {
    let bucket = unique_bucket();
    let Some(client) = connect_or_skip("update_gap", &bucket).await else {
        return;
    };

    let worker_id = format!("worker-{}", &Uuid::new_v4().to_string()[..8]);
    let presence = build_presence(&worker_id, Some("GAP-A".to_string()));
    client
        .register_worker_presence(&presence)
        .await
        .expect("register");

    let first = client
        .worker_presence(&worker_id)
        .await
        .expect("get")
        .expect("exists");

    // Ensure a measurable time delta before the update.
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;

    client
        .update_worker_presence_gap(&worker_id, Some("GAP-B".to_string()))
        .await
        .expect("update_worker_presence_gap");

    let second = client
        .worker_presence(&worker_id)
        .await
        .expect("get")
        .expect("exists");

    assert_eq!(second.current_gap.as_deref(), Some("GAP-B"));
    assert!(second.updated_at > first.updated_at);
    assert_eq!(second.status, PresenceStatus::Active);

    std::env::remove_var("CHUMP_NATS_WORKERS_BUCKET");
}

#[tokio::test]
#[serial]
async fn mark_terminal_on_ship_or_exit() {
    let bucket = unique_bucket();
    let Some(client) = connect_or_skip("mark_terminal", &bucket).await else {
        return;
    };

    let worker_id = format!("worker-{}", &Uuid::new_v4().to_string()[..8]);
    let presence = build_presence(&worker_id, Some("GAP-X".to_string()));
    client
        .register_worker_presence(&presence)
        .await
        .expect("register");

    client
        .mark_worker_terminal(&worker_id)
        .await
        .expect("mark_worker_terminal");

    let after = client
        .worker_presence(&worker_id)
        .await
        .expect("get")
        .expect("record kept for audit after terminal transition");

    assert_eq!(after.status, PresenceStatus::Terminal);
    // Once terminal, is_alive() must be false regardless of recency.
    assert!(!after.is_alive(after.updated_at, 300));

    std::env::remove_var("CHUMP_NATS_WORKERS_BUCKET");
}

#[tokio::test]
#[serial]
async fn list_worker_presence_returns_all_registered_workers() {
    let bucket = unique_bucket();
    let Some(client) = connect_or_skip("list_presence", &bucket).await else {
        return;
    };

    let tag = &Uuid::new_v4().to_string()[..8];
    for n in 0..3 {
        let worker_id = format!("worker-{}-{}", tag, n);
        let presence = build_presence(&worker_id, None);
        client
            .register_worker_presence(&presence)
            .await
            .expect("register");
    }

    let all = client.list_worker_presence().await.expect("list");
    let matching = all
        .iter()
        .filter(|p| p.worker_id.starts_with(&format!("worker-{}-", tag)))
        .count();
    assert_eq!(matching, 3);

    std::env::remove_var("CHUMP_NATS_WORKERS_BUCKET");
}
