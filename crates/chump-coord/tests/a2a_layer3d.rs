// crates/chump-coord/tests/a2a_layer3d.rs — INFRA-1121
//
// Integration test for A2A Layer 3d (3/4): concurrent-writer CAS invariant.
//
// AC #6: concurrent writers (≥ 10 tokio tasks) on CAS key — exactly one wins
// per round, all others retry; final value is deterministic.
//
// Design: N tasks each attempt to CAS main.head.sha from Null → their own
// ID string. Because only one task can see Null at a time (file-backend
// rename is atomic), exactly one task wins the first slot. Subsequent rounds
// retry from the observed current value, so all N tasks eventually land a
// write in some linear order. At the end the key holds exactly one of the
// N submitted values (deterministic ownership).

use chump_coord::scratchpad::{cas, get};
use serde_json::json;
use serial_test::serial;
use std::sync::{Arc, Mutex};
use tokio::task::JoinSet;

// ── Helper: clear the scratchpad directory between tests ──────────────────────
fn scratch_dir_for_test(dir: &tempfile::TempDir) {
    std::env::set_var("CHUMP_SCRATCH_DIR", dir.path().to_str().unwrap());
}

fn clear_scratch_dir_env() {
    std::env::remove_var("CHUMP_SCRATCH_DIR");
}

// ── Concurrent CAS: 10 writers ────────────────────────────────────────────────

/// Exactly one writer wins the first CAS (Null → id); the others get
/// CASConflict, retry, and eventually converge. At the end, the key holds
/// one of the writer IDs and the final value is stable.
#[serial]
#[tokio::test]
async fn concurrent_cas_writers_converge_to_single_winner() {
    let dir = tempfile::tempdir().unwrap();
    scratch_dir_for_test(&dir);

    const N: usize = 10;
    let wins: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

    let mut set = JoinSet::new();

    for i in 0..N {
        let wins = Arc::clone(&wins);
        set.spawn(async move {
            let my_id = format!("writer_{i}");
            let mut retries = 0_usize;
            loop {
                // Read current value.
                let current = get("main.head.sha").await.unwrap_or(None);
                let expected = current.clone().unwrap_or(serde_json::Value::Null);
                let new_val = json!(my_id);
                match cas("main.head.sha", expected, new_val).await {
                    Ok(()) => {
                        wins.lock().unwrap().push(my_id.clone());
                        break;
                    }
                    Err(chump_coord::scratchpad::ScratchError::CASConflict { .. }) => {
                        retries += 1;
                        if retries > 100 {
                            panic!("writer_{i} retried too many times (>100)");
                        }
                        // Back off briefly to reduce thundering-herd.
                        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
                    }
                    Err(e) => panic!("unexpected error from writer_{i}: {e}"),
                }
            }
        });
    }

    // Wait for all writers to finish.
    while let Some(result) = set.join_next().await {
        result.expect("writer task panicked");
    }

    // Exactly N writes landed (each writer wins exactly one slot).
    // Drop the guard before the async get() below to avoid holding a
    // MutexGuard across an await point (clippy::await_holding_lock).
    let wins_len = wins.lock().unwrap().len();
    assert_eq!(
        wins_len, N,
        "expected {N} successful writes (one per writer), got {wins_len}"
    );

    // Final value is one of the writer IDs.
    let final_val = get("main.head.sha")
        .await
        .expect("get should succeed")
        .expect("key should be set");
    let final_str = final_val.as_str().expect("value should be string");
    assert!(
        final_str.starts_with("writer_"),
        "final value should be a writer ID, got: {final_str}"
    );

    clear_scratch_dir_env();
}

// ── Only one task wins the Null→value CAS ─────────────────────────────────────

/// When N tasks all race to CAS from Null, exactly one succeeds;
/// all others get CASConflict (not silent data loss).
#[serial]
#[tokio::test]
async fn exactly_one_null_cas_winner() {
    let dir = tempfile::tempdir().unwrap();
    scratch_dir_for_test(&dir);

    const N: usize = 12;
    let success_count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let conflict_count = Arc::new(std::sync::atomic::AtomicUsize::new(0));

    let mut set = JoinSet::new();
    for i in 0..N {
        let sc = Arc::clone(&success_count);
        let cc = Arc::clone(&conflict_count);
        set.spawn(async move {
            match cas(
                "last_known_good.chump_binary",
                serde_json::Value::Null,
                json!(format!("build_{i}")),
            )
            .await
            {
                Ok(()) => {
                    sc.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                Err(chump_coord::scratchpad::ScratchError::CASConflict { .. }) => {
                    cc.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                Err(e) => panic!("unexpected error: {e}"),
            }
        });
    }

    while let Some(r) = set.join_next().await {
        r.expect("task panicked");
    }

    let successes = success_count.load(std::sync::atomic::Ordering::Relaxed);
    let conflicts = conflict_count.load(std::sync::atomic::Ordering::Relaxed);

    // Exactly one winner — the others all get CASConflict.
    assert_eq!(
        successes, 1,
        "expected exactly 1 CAS winner from Null, got {successes}"
    );
    assert_eq!(
        conflicts,
        N - 1,
        "expected {}/{N} conflicts, got {conflicts}",
        N - 1
    );

    clear_scratch_dir_env();
}
