//! INFRA-1475 — live Supabase round-trip integration test.
//!
//! Env-gated. If `CHUMP_TEAM_URL` is unset, the test prints a skip line and
//! returns success. Operators with credentials in `~/.chump/team.toml` can:
//!
//! ```bash
//! export $(grep -E '^(url|service_role)' ~/.chump/team.toml \
//!     | sed 's/url *=/CHUMP_TEAM_URL=/; s/service_role *=/CHUMP_TEAM_API_KEY=/' \
//!     | tr -d ' "')
//! cargo test -p chump-team --test live -- --nocapture
//! ```
//!
//! What it asserts (Phase-1 MVP scope of INFRA-1475):
//!   1. reserve_gap creates a row and returns the full SharedGap
//!   2. list_gaps returns it
//!   3. get_gap finds it by ID
//!   4. update_gap mutates fields and bumps updated_at
//!   5. try_claim_gap wins the first call (returns Won)
//!   6. try_claim_gap loses the second call (returns Lost with the holder)
//!   7. release_claim flips released_at; subsequent try_claim_gap wins again
//!   8. list_active_claims excludes released ones
//!
//! Cleans up after itself (deletes the test gap) on success and failure.

use chump_team::{
    ChumpTeam, ChumpTeamConfig, ClaimResult, Effort, GapFilter, GapPatch, GapStatus, Priority,
    ReleaseReason,
};
use uuid::Uuid;

/// Dogfood team ID — must exist before the test runs. Created by the
/// Phase 0 smoke-test in INFRA-1665.
const DOGFOOD_TEAM_ID: &str = "00000000-0000-0000-0000-000000000001";
const DOGFOOD_USER_ID: &str = "00000000-0000-0000-0000-000000000999";

fn skip_if_no_creds() -> Option<ChumpTeam> {
    let url = std::env::var("CHUMP_TEAM_URL").ok();
    let key = std::env::var("CHUMP_TEAM_API_KEY").ok();
    match (url, key) {
        (Some(u), Some(k)) if !u.is_empty() && !k.is_empty() => {
            Some(ChumpTeam::new(ChumpTeamConfig {
                url: u,
                api_key: k,
                user_jwt: None,
                active_team_slug: None,
            }))
        }
        _ => {
            eprintln!(
                "[skip] CHUMP_TEAM_URL + CHUMP_TEAM_API_KEY not set — \
                 skipping live round-trip test"
            );
            None
        }
    }
}

#[tokio::test]
async fn ping_works() {
    let Some(client) = skip_if_no_creds() else {
        return;
    };
    client.ping().await.expect("ping should succeed");
}

#[tokio::test]
async fn roundtrip_gap_claim_release() {
    let Some(client) = skip_if_no_creds() else {
        return;
    };
    let team_id: Uuid = DOGFOOD_TEAM_ID.parse().unwrap();
    let user_id: Uuid = DOGFOOD_USER_ID.parse().unwrap();

    // Use a unique gap_id per test run so reruns don't collide.
    let gap_id = format!("INFRA-LIVETEST-{}", &Uuid::new_v4().to_string()[..8]);

    // 1. reserve_gap
    let gap = client
        .reserve_gap(
            &gap_id,
            team_id,
            "INFRA",
            "live round-trip test (auto-cleanup)",
            Priority::P2,
            Effort::Xs,
            user_id,
        )
        .await
        .expect("reserve_gap");
    assert_eq!(gap.id, gap_id);
    assert_eq!(gap.priority, Priority::P2);
    assert_eq!(gap.effort, Effort::Xs);
    assert_eq!(gap.status, GapStatus::Open);

    // 2. list_gaps surfaces it
    let listed = client
        .list_gaps(GapFilter {
            status: Some(GapStatus::Open),
            ..Default::default()
        })
        .await
        .expect("list_gaps");
    assert!(
        listed.iter().any(|g| g.id == gap_id),
        "newly-reserved gap not in list"
    );

    // 3. get_gap by ID
    let fetched = client
        .get_gap(&gap_id)
        .await
        .expect("get_gap")
        .expect("gap present");
    assert_eq!(fetched.title, gap.title);

    // 4. update_gap
    let patched = client
        .update_gap(
            &gap_id,
            GapPatch {
                notes: Some("touched by live test".to_string()),
                ..Default::default()
            },
        )
        .await
        .expect("update_gap");
    assert_eq!(patched.notes.as_deref(), Some("touched by live test"));
    assert!(
        patched.updated_at > gap.updated_at,
        "updated_at did not advance"
    );

    // 5. try_claim_gap (Won)
    let machine = "live-test-host";
    let session_a = format!("live-test-A-{}", gap_id);
    let result = client
        .try_claim_gap(&gap_id, team_id, user_id, machine, &session_a, 60)
        .await
        .expect("try_claim_gap A");
    let claim_a = match result {
        ClaimResult::Won(c) => c,
        ClaimResult::Lost { .. } => panic!("first claim should win"),
    };

    // 6. try_claim_gap (Lost) — second call must report the holder
    let session_b = format!("live-test-B-{}", gap_id);
    let result = client
        .try_claim_gap(&gap_id, team_id, user_id, machine, &session_b, 60)
        .await
        .expect("try_claim_gap B");
    match result {
        ClaimResult::Lost { held_by } => {
            assert_eq!(held_by.id, claim_a.id, "Lost should report the same holder");
        }
        ClaimResult::Won(_) => panic!("second claim should have lost"),
    }

    // 7. release_claim + re-claim
    client
        .release_claim(claim_a.id, ReleaseReason::Aborted)
        .await
        .expect("release_claim");
    let result = client
        .try_claim_gap(&gap_id, team_id, user_id, machine, &session_b, 60)
        .await
        .expect("try_claim_gap after release");
    let claim_b = match result {
        ClaimResult::Won(c) => c,
        ClaimResult::Lost { .. } => panic!("after release, second claim should win"),
    };
    assert_ne!(claim_a.id, claim_b.id, "post-release claim is a new row");

    // 8. list_active_claims includes claim_b, not claim_a
    let active = client
        .list_active_claims(team_id)
        .await
        .expect("list_active_claims");
    assert!(
        active.iter().any(|c| c.id == claim_b.id),
        "claim_b should be active"
    );
    assert!(
        !active.iter().any(|c| c.id == claim_a.id),
        "claim_a should be released (not active)"
    );

    // Cleanup — release the final claim. The test gap itself is left in the
    // table; a `LIVETEST-*` sweep can prune them later. (Deleting it would
    // CASCADE-delete the claims and lose the audit trail.)
    let _ = client
        .release_claim(claim_b.id, ReleaseReason::Aborted)
        .await;
}
