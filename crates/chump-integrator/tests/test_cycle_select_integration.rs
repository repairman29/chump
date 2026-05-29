//! Integration test: select_candidates filters correctly from a real state.db.

use chump_gap_store::{GapFieldUpdate, GapStore};
use chump_integrator::cycle::select::{select_candidates, StateDbWorkBoard};
use serial_test::serial;
use tempfile::TempDir;

fn make_store() -> (TempDir, GapStore) {
    let dir = tempfile::tempdir().unwrap();
    let store = GapStore::open(dir.path()).unwrap();
    (dir, store)
}

fn seed_gap(store: &GapStore, title: &str, priority: &str) -> String {
    std::env::set_var("CHUMP_RESERVE_VERIFY", "0");
    let id = store.reserve("INFRA", title, priority, "s").unwrap();
    std::env::remove_var("CHUMP_RESERVE_VERIFY");
    id
}

fn set_ready(store: &GapStore, gap_id: &str) {
    store
        .set_fields(
            gap_id,
            GapFieldUpdate {
                status: Some("ready_to_ship".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
}

#[test]
#[serial]
fn test_select_filters_only_ready_to_ship() {
    let (_dir, store) = make_store();

    let _open_id = seed_gap(&store, "EFFECTIVE P1: open gap", "P1");
    let ready_id = seed_gap(&store, "EFFECTIVE P1: ready gap", "P1");

    // Only ready_id becomes ready_to_ship; _open_id stays "open".
    set_ready(&store, &ready_id);

    let rows = store.list(Some("ready_to_ship")).unwrap();
    let board = StateDbWorkBoard::from_gap_rows(rows);
    let result = select_candidates(&board, 10, 10_000);

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].gap_id, ready_id);
}

#[test]
#[serial]
fn test_select_priority_ordering_from_db() {
    let (_dir, store) = make_store();

    let p2_id = seed_gap(&store, "EFFECTIVE P2: lower priority", "P2");
    let p0_id = seed_gap(&store, "EFFECTIVE P0: highest priority", "P0");
    let p1_id = seed_gap(&store, "EFFECTIVE P1: medium priority", "P1");

    for id in [&p2_id, &p0_id, &p1_id] {
        set_ready(&store, id);
    }

    let rows = store.list(Some("ready_to_ship")).unwrap();
    let board = StateDbWorkBoard::from_gap_rows(rows);
    let result = select_candidates(&board, 10, 10_000);

    assert_eq!(result.len(), 3);
    assert_eq!(result[0].gap_id, p0_id, "P0 should be first");
    assert_eq!(result[1].gap_id, p1_id, "P1 should be second");
    assert_eq!(result[2].gap_id, p2_id, "P2 should be third");
}

#[test]
#[serial]
fn test_select_max_batch_respected() {
    let (_dir, store) = make_store();

    for i in 0..8u32 {
        let id = seed_gap(&store, &format!("EFFECTIVE P1: select gap {i}"), "P1");
        set_ready(&store, &id);
    }

    let rows = store.list(Some("ready_to_ship")).unwrap();
    let board = StateDbWorkBoard::from_gap_rows(rows);
    let result = select_candidates(&board, 4, 10_000);

    assert_eq!(result.len(), 4, "max_batch=4 should cap at 4");
}
