//! Integration tests for the FLEET-007 distributed-mutex property.
//!
//! These tests run against a real NATS server (default
//! `nats://127.0.0.1:4222`). If NATS is unreachable they SKIP (return early
//! with a logged warning) rather than fail, so CI without a NATS service
//! container still passes. Locally:
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test distributed_mutex -- --nocapture
//! ```
//!
//! The property under test is the one INFRA-042 documented as missing from
//! the file-based lease system: **two agents cannot claim the same gap
//! simultaneously**. Every test seeds a unique gap ID (UUID), so concurrent
//! test runs against the same NATS server don't collide.

use chump_coord::CoordClient;
use std::sync::Arc;
use std::time::Duration;

/// Returns a unique synthetic gap ID for a single test, so tests never
/// collide on the shared NATS KV bucket even when run in parallel.
fn unique_gap_id(prefix: &str) -> String {
    format!("{}-{}", prefix, uuid::Uuid::new_v4())
}

/// Connect to NATS or skip (return None) if unreachable. Tests that need
/// NATS use this and early-return on None.
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
async fn first_claim_wins_second_loses() {
    let Some(client) = connect_or_skip("first_claim_wins_second_loses").await else {
        return;
    };
    let gap = unique_gap_id("FLEET-007-A");

    let first = client
        .try_claim_gap(&gap, "session-alpha")
        .await
        .expect("first claim should not error");
    assert!(first, "first claim must win");

    let second = client
        .try_claim_gap(&gap, "session-beta")
        .await
        .expect("second claim should not error");
    assert!(!second, "second claim must lose (CAS conflict)");

    // Cleanup so we don't pollute the shared bucket.
    client.release_gap(&gap).await.ok();
}

#[tokio::test]
async fn release_allows_reclaim() {
    let Some(client) = connect_or_skip("release_allows_reclaim").await else {
        return;
    };
    let gap = unique_gap_id("FLEET-007-B");

    assert!(client.try_claim_gap(&gap, "sess-1").await.unwrap());
    client.release_gap(&gap).await.expect("release ok");

    // After release, a different session can claim again.
    assert!(
        client.try_claim_gap(&gap, "sess-2").await.unwrap(),
        "post-release reclaim must succeed"
    );
    client.release_gap(&gap).await.ok();
}

#[tokio::test]
async fn gap_claim_returns_holder_session() {
    let Some(client) = connect_or_skip("gap_claim_returns_holder_session").await else {
        return;
    };
    let gap = unique_gap_id("FLEET-007-C");

    assert!(client.try_claim_gap(&gap, "the-holder").await.unwrap());

    let holder = client
        .gap_claim(&gap)
        .await
        .expect("read claim ok")
        .expect("claim must exist");
    assert_eq!(holder.session_id, "the-holder");

    client.release_gap(&gap).await.ok();
}

/// The load-bearing property assertion for FLEET-007:
/// N concurrent tasks all calling `try_claim_gap` on the same gap → exactly
/// one returns `Ok(true)` and N-1 return `Ok(false)`. This is the property
/// the file-based lease system lacks (per INFRA-042: every concurrent
/// agent "wins" because there's no atomic CAS).
#[tokio::test]
async fn concurrent_claims_exactly_one_winner() {
    let Some(client) = connect_or_skip("concurrent_claims_exactly_one_winner").await else {
        return;
    };
    let client = Arc::new(client);
    let gap = unique_gap_id("FLEET-007-D");

    const N: usize = 16;
    let mut handles = Vec::with_capacity(N);
    for i in 0..N {
        let client = Arc::clone(&client);
        let gap = gap.clone();
        handles.push(tokio::spawn(async move {
            client
                .try_claim_gap(&gap, &format!("session-{}", i))
                .await
                .expect("no NATS error during race")
        }));
    }

    let mut wins = 0usize;
    let mut losses = 0usize;
    for h in handles {
        match h.await.unwrap() {
            true => wins += 1,
            false => losses += 1,
        }
    }

    assert_eq!(wins, 1, "exactly one task must win the CAS race");
    assert_eq!(losses, N - 1, "all other tasks must lose");

    client.release_gap(&gap).await.ok();
}

/// FLEET-007 acceptance criterion: "Lease auto-expires if agent stops renewing
/// (TTL validation in test)." NATS KV `max_age` removes entries after the TTL
/// elapses with no further writes, so a stale claim becomes claimable again.
///
/// Uses a fresh bucket name + 2s TTL via env (the bucket is created per-test
/// via `CHUMP_NATS_GAP_BUCKET`, so it doesn't collide with the production
/// `chump_gaps` bucket or other tests' buckets). `#[serial]` because the env
/// mutation isn't safe alongside other tests that read the same vars.
#[tokio::test]
#[serial_test::serial]
async fn ttl_expiry_allows_reclaim() {
    let bucket = format!("test_ttl_{}", uuid::Uuid::new_v4().simple());
    // SAFETY: tests use scoped env vars on a single tokio runtime; no other
    // task in this binary reads these vars concurrently with this set, and
    // each test sets a unique bucket name + restores TTL on exit.
    unsafe {
        std::env::set_var("CHUMP_NATS_GAP_BUCKET", &bucket);
        std::env::set_var("CHUMP_GAP_CLAIM_TTL_SECS", "2");
    }
    let result = async {
        let Some(client) = connect_or_skip("ttl_expiry_allows_reclaim").await else {
            return Ok::<(), &'static str>(());
        };
        let gap = unique_gap_id("FLEET-007-TTL");
        assert!(
            client.try_claim_gap(&gap, "first-holder").await.unwrap(),
            "first claim must win"
        );
        // Wait past TTL — NATS KV max_age cleanup is asynchronous, so give it
        // a generous margin beyond the 2s TTL before re-claiming.
        tokio::time::sleep(Duration::from_secs(4)).await;
        let reclaimed = client
            .try_claim_gap(&gap, "second-holder")
            .await
            .expect("post-TTL claim should not error");
        assert!(
            reclaimed,
            "after TTL expiry, a new session must be able to claim"
        );
        client.release_gap(&gap).await.ok();
        Ok(())
    }
    .await;
    unsafe {
        std::env::remove_var("CHUMP_NATS_GAP_BUCKET");
        std::env::remove_var("CHUMP_GAP_CLAIM_TTL_SECS");
    }
    result.unwrap();
}
