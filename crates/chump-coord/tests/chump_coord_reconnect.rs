//! INFRA-126: reconnect integration test for the chump-coord NATS lease layer.
//!
//! Property under test: a gap claim persists in NATS KV across a client
//! disconnect.  After the original client connection is dropped (simulating
//! a network interruption), a freshly-reconnected client can still read the
//! claim and release it.  This verifies that claim state is durable in the
//! server, not ephemeral in the client handle.
//!
//! Requires a live NATS server with JetStream enabled.  If unreachable the
//! test SKIPs (returns early) rather than fails, so CI without a NATS
//! service container still passes.
//!
//! To run locally:
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test chump_coord_reconnect -- --nocapture
//! ```
//!
//! Or with a custom server URL:
//!
//! ```bash
//! TEST_NATS_URL=nats://my-server:4222 \
//!   cargo test -p chump-coord --test chump_coord_reconnect -- --nocapture
//! ```

use chump_coord::CoordClient;

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

fn unique_gap_id(prefix: &str) -> String {
    format!("{}-{}", prefix, uuid::Uuid::new_v4())
}

/// Claim a gap, drop the client (simulate disconnect), then reconnect and
/// verify the claim is still readable and releasable.
#[tokio::test]
async fn claim_survives_client_reconnect() {
    let Some(client_a) = connect_or_skip("claim_survives_client_reconnect.a").await else {
        return;
    };

    let gap = unique_gap_id("INFRA-126-RECONNECT-A");
    let session = "reconnect-session-1";

    assert!(
        client_a.try_claim_gap(&gap, session).await.unwrap(),
        "initial claim must succeed"
    );

    // Explicitly flush and drop client_a — this closes the NATS connection,
    // simulating a disconnect (network drop, process restart, etc.).
    client_a.flush().await.ok();
    drop(client_a);

    // Reconnect with a fresh client.
    let Some(client_b) = connect_or_skip("claim_survives_client_reconnect.b").await else {
        return;
    };

    // The claim must still be present in KV — it was written to the server,
    // not held only in the client's memory.
    let claim = client_b
        .gap_claim(&gap)
        .await
        .expect("gap_claim read ok")
        .expect("claim must still exist after client_a disconnect");

    assert_eq!(
        claim.session_id, session,
        "claim holder must be the original session"
    );

    // The reconnected client can release the claim.
    client_b
        .release_gap(&gap)
        .await
        .expect("release via reconnected client must succeed");

    // After release the gap is unclaimed.
    let post_release = client_b
        .gap_claim(&gap)
        .await
        .expect("post-release read ok");
    assert!(
        post_release.is_none(),
        "claim must be gone after release via reconnected client"
    );
}

/// Claim, drop connection, reconnect, extend the claim (re-claim after
/// release from new client), verify the second holder wins.
#[tokio::test]
async fn reconnected_client_can_extend_via_release_and_reclaim() {
    let Some(client_a) =
        connect_or_skip("reconnected_client_can_extend_via_release_and_reclaim.a").await
    else {
        return;
    };

    let gap = unique_gap_id("INFRA-126-RECONNECT-B");
    let session_1 = "reconnect-extend-s1";
    let session_2 = "reconnect-extend-s2";

    assert!(
        client_a.try_claim_gap(&gap, session_1).await.unwrap(),
        "first claim must win"
    );
    client_a.flush().await.ok();
    drop(client_a);

    // Second client reconnects as a "resumed" session.
    let Some(client_b) =
        connect_or_skip("reconnected_client_can_extend_via_release_and_reclaim.b").await
    else {
        return;
    };

    // Release on behalf of session_1 (the reconnected agent knows its own gap).
    client_b
        .release_gap(&gap)
        .await
        .expect("release on reconnect ok");

    // A new session can now claim the gap.
    assert!(
        client_b.try_claim_gap(&gap, session_2).await.unwrap(),
        "post-reconnect reclaim must succeed"
    );

    client_b.release_gap(&gap).await.ok();
}
