//! Atomic claim/lease records (INFRA-1475 surface).
//!
//! The CAS guarantee lives in the database: `shared_claims` has a partial
//! unique index on (gap_id) WHERE released_at IS NULL. INSERT races
//! collapse to one winner; losers get ChumpTeamError::Conflict.

use crate::errors::ChumpTeamError;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ReleaseReason {
    Shipped,
    Aborted,
    Expired,
    Evicted,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claim {
    pub id: Uuid,
    pub gap_id: String,
    pub team_id: Uuid,
    pub operator_user_id: Uuid,
    pub worker_machine: String,
    pub session_id: String,
    pub claimed_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub released_at: Option<DateTime<Utc>>,
    pub release_reason: Option<ReleaseReason>,
}

/// Outcome of a try_claim call.
#[derive(Debug)]
pub enum ClaimResult {
    /// We won the CAS — the gap is now held by us.
    Won(Claim),
    /// Another operator already holds the gap.
    Lost { held_by: Claim },
}

fn unimpl(method: &'static str) -> ChumpTeamError {
    ChumpTeamError::Other(anyhow::anyhow!(
        "{method}: not yet implemented in Phase 0 (INFRA-1665 scaffolding); \
         INFRA-1475 will fill this in"
    ))
}

impl ChumpTeam {
    /// Attempt to atomically claim a gap.
    /// On conflict (another active claim exists), returns ClaimResult::Lost
    /// with the holder's details.
    pub async fn try_claim_gap(
        &self,
        _gap_id: &str,
        _worker_machine: &str,
        _session_id: &str,
        _ttl_secs: u64,
    ) -> Result<ClaimResult> {
        Err(unimpl("try_claim_gap"))
    }

    /// Release a claim. Idempotent — calling on an already-released claim
    /// is a no-op.
    pub async fn release_claim(&self, _claim_id: Uuid, _reason: ReleaseReason) -> Result<()> {
        Err(unimpl("release_claim"))
    }

    /// Renew the lease (push expires_at forward). Used by long-running workers.
    pub async fn renew_claim(&self, _claim_id: Uuid, _new_ttl_secs: u64) -> Result<Claim> {
        Err(unimpl("renew_claim"))
    }

    /// List all active claims for a team. Cockpit cross-operator view.
    pub async fn list_active_claims(&self, _team_id: Uuid) -> Result<Vec<Claim>> {
        Err(unimpl("list_active_claims"))
    }
}
