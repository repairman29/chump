//! Atomic claim/lease records (INFRA-1475 surface).
//!
//! The CAS guarantee lives in the database: `shared_claims` has a partial
//! unique index on `(gap_id) WHERE released_at IS NULL`. INSERT races collapse
//! to one winner; losers get [`ChumpTeamError::Conflict`].

use crate::errors::ChumpTeamError;
use crate::gaps::fetch_json;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Duration, Utc};
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

impl ReleaseReason {
    fn as_db_str(&self) -> &'static str {
        match self {
            ReleaseReason::Shipped => "shipped",
            ReleaseReason::Aborted => "aborted",
            ReleaseReason::Expired => "expired",
            ReleaseReason::Evicted => "evicted",
        }
    }
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

/// Outcome of a try_claim call. `Won(claim)` means we hold the gap; `Lost`
/// means another active claim already exists (and we report the holder so
/// the operator can see who's working on it).
#[derive(Debug)]
pub enum ClaimResult {
    Won(Claim),
    Lost { held_by: Claim },
}

impl ChumpTeam {
    /// Attempt to atomically claim a gap.
    ///
    /// Sequence: probe → INSERT → on 23505, probe again and return Lost.
    /// The 23505 path is rare (only happens when two operators race in the
    /// ~1ms window between probe and insert); both arms eventually agree
    /// on a single holder.
    pub async fn try_claim_gap(
        &self,
        gap_id: &str,
        team_id: Uuid,
        operator_user_id: Uuid,
        worker_machine: &str,
        session_id: &str,
        ttl_secs: u64,
    ) -> Result<ClaimResult> {
        // First, check if there's already an active claim. Cheap optimization
        // to avoid the INSERT-and-rollback path on the common collision case.
        if let Some(held) = self.active_claim_for(gap_id).await? {
            return Ok(ClaimResult::Lost { held_by: held });
        }

        let expires_at = Utc::now() + Duration::seconds(ttl_secs as i64);
        let payload = serde_json::json!({
            "gap_id": gap_id,
            "team_id": team_id,
            "operator_user_id": operator_user_id,
            "worker_machine": worker_machine,
            "session_id": session_id,
            "expires_at": expires_at.to_rfc3339(),
        });
        let q = self
            .postgrest()
            .from("shared_claims")
            .insert(payload.to_string());

        match fetch_json::<Vec<Claim>>(q, "shared_claims").await {
            Ok(mut rows) => {
                let claim = rows.pop().ok_or_else(|| {
                    ChumpTeamError::Other(anyhow::anyhow!("try_claim_gap: insert returned no row"))
                })?;
                Ok(ClaimResult::Won(claim))
            }
            Err(ChumpTeamError::Conflict { .. }) => {
                // Another claimer beat us in the race. Re-probe to surface
                // who actually won.
                match self.active_claim_for(gap_id).await? {
                    Some(held) => Ok(ClaimResult::Lost { held_by: held }),
                    None => Err(ChumpTeamError::Other(anyhow::anyhow!(
                        "try_claim_gap: race conflict but no active claim found"
                    ))),
                }
            }
            Err(e) => Err(e),
        }
    }

    /// Release a claim. Idempotent — releasing an already-released claim
    /// is a no-op (the WHERE clause matches nothing).
    pub async fn release_claim(&self, claim_id: Uuid, reason: ReleaseReason) -> Result<()> {
        let payload = serde_json::json!({
            "released_at": Utc::now().to_rfc3339(),
            "release_reason": reason.as_db_str(),
        });
        let q = self
            .postgrest()
            .from("shared_claims")
            .update(payload.to_string())
            .eq("id", claim_id.to_string())
            .is("released_at", "null");
        let _: Vec<Claim> = fetch_json(q, "shared_claims").await?;
        Ok(())
    }

    /// Renew the lease (push expires_at forward by `new_ttl_secs` from now).
    /// Used by long-running workers to keep their claim alive.
    pub async fn renew_claim(&self, claim_id: Uuid, new_ttl_secs: u64) -> Result<Claim> {
        let new_expires = Utc::now() + Duration::seconds(new_ttl_secs as i64);
        let payload = serde_json::json!({
            "expires_at": new_expires.to_rfc3339(),
        });
        let q = self
            .postgrest()
            .from("shared_claims")
            .update(payload.to_string())
            .eq("id", claim_id.to_string())
            .is("released_at", "null");
        let rows: Vec<Claim> = fetch_json(q, "shared_claims").await?;
        rows.into_iter().next().ok_or_else(|| {
            ChumpTeamError::Other(anyhow::anyhow!(
                "renew_claim: claim_id={claim_id} not found or already released"
            ))
        })
    }

    /// List all active claims for a team (cockpit cross-operator view).
    pub async fn list_active_claims(&self, team_id: Uuid) -> Result<Vec<Claim>> {
        let q = self
            .postgrest()
            .from("shared_claims")
            .select("*")
            .eq("team_id", team_id.to_string())
            .is("released_at", "null")
            .order("claimed_at.desc");
        fetch_json::<Vec<Claim>>(q, "shared_claims").await
    }

    /// Lookup the single active claim for a gap (if any). Internal helper
    /// used by try_claim_gap.
    pub(crate) async fn active_claim_for(&self, gap_id: &str) -> Result<Option<Claim>> {
        let q = self
            .postgrest()
            .from("shared_claims")
            .select("*")
            .eq("gap_id", gap_id)
            .is("released_at", "null")
            .limit(1);
        let rows: Vec<Claim> = fetch_json(q, "shared_claims").await?;
        Ok(rows.into_iter().next())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_reason_db_strings() {
        assert_eq!(ReleaseReason::Shipped.as_db_str(), "shipped");
        assert_eq!(ReleaseReason::Aborted.as_db_str(), "aborted");
        assert_eq!(ReleaseReason::Expired.as_db_str(), "expired");
        assert_eq!(ReleaseReason::Evicted.as_db_str(), "evicted");
    }
}
