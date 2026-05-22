//! Shared work queue (INFRA-1475 surface).
//!
//! Mirrors the local state.db `gaps` table for cross-operator visibility.
//! Phase 0 (INFRA-1665) shipped the types; this file (INFRA-1475) implements
//! the CRUD against the live Supabase substrate.

use crate::errors::ChumpTeamError;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum Priority {
    P0,
    P1,
    P2,
    P3,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Effort {
    Xs,
    S,
    M,
    L,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum GapStatus {
    Open,
    Claimed,
    Shipped,
    Superseded,
    Blocked,
}

/// One row of `shared_gaps`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SharedGap {
    pub id: String,
    pub team_id: Uuid,
    pub title: String,
    pub domain: String,
    pub priority: Priority,
    pub effort: Effort,
    pub status: GapStatus,
    pub description: Option<String>,
    pub acceptance_criteria: Option<String>,
    pub notes: Option<String>,
    #[serde(default)]
    pub skills_required: Vec<String>,
    pub preferred_machine: Option<String>,
    #[serde(default)]
    pub depends_on: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub created_by_user_id: Uuid,
    pub updated_at: DateTime<Utc>,
    pub shipped_at: Option<DateTime<Utc>>,
    pub closed_pr: Option<i32>,
}

/// Filter for `list_gaps`.
#[derive(Debug, Clone, Default)]
pub struct GapFilter {
    pub status: Option<GapStatus>,
    pub priority: Option<Priority>,
    pub effort_max: Option<Effort>,
    pub domain: Option<String>,
}

/// Sparse update for a gap; None fields untouched.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GapPatch {
    pub status: Option<GapStatus>,
    pub description: Option<String>,
    pub acceptance_criteria: Option<String>,
    pub notes: Option<String>,
    pub closed_pr: Option<i32>,
    pub priority: Option<Priority>,
    pub effort: Option<Effort>,
}

// Database string spellings. PostgREST returns lowercase strings matching
// the CHECK constraints; serde's default for the variants doesn't match.
impl Priority {
    pub fn as_db_str(&self) -> &'static str {
        match self {
            Priority::P0 => "P0",
            Priority::P1 => "P1",
            Priority::P2 => "P2",
            Priority::P3 => "P3",
        }
    }
}

impl Effort {
    pub fn as_db_str(&self) -> &'static str {
        match self {
            Effort::Xs => "xs",
            Effort::S => "s",
            Effort::M => "m",
            Effort::L => "l",
        }
    }
}

impl GapStatus {
    pub fn as_db_str(&self) -> &'static str {
        match self {
            GapStatus::Open => "open",
            GapStatus::Claimed => "claimed",
            GapStatus::Shipped => "shipped",
            GapStatus::Superseded => "superseded",
            GapStatus::Blocked => "blocked",
        }
    }
}

/// Internal helper: drive a postgrest::Builder to completion and parse the
/// JSON body. Used by every read/write path in this module.
pub(crate) async fn fetch_json<T: for<'de> serde::Deserialize<'de>>(
    builder: postgrest::Builder,
    table: &'static str,
) -> Result<T> {
    let resp = builder
        .execute()
        .await
        .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("{table} request: {e}")))?;
    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("{table} body: {e}")))?;
    if !status.is_success() {
        // 23505 == unique-violation. For shared_claims this is the CAS race
        // signal; for other tables it's a real bug. We expose it as Conflict
        // so callers (notably try_claim_gap) can pattern-match.
        if body.contains("23505") {
            return Err(ChumpTeamError::Conflict {
                table,
                detail: body,
            });
        }
        if status.as_u16() == 401 || status.as_u16() == 403 {
            return Err(ChumpTeamError::Unauthorized(body));
        }
        return Err(ChumpTeamError::Http {
            status: status.as_u16(),
            body,
        });
    }
    serde_json::from_str(&body).map_err(ChumpTeamError::from)
}

impl ChumpTeam {
    /// List gaps visible to the calling user. RLS restricts to teams the
    /// caller is a member of.
    pub async fn list_gaps(&self, filter: GapFilter) -> Result<Vec<SharedGap>> {
        let mut q = self.postgrest().from("shared_gaps").select("*");
        if let Some(s) = filter.status {
            q = q.eq("status", s.as_db_str());
        }
        if let Some(p) = filter.priority {
            q = q.eq("priority", p.as_db_str());
        }
        if let Some(d) = &filter.domain {
            q = q.eq("domain", d);
        }
        // MVP: exact effort match if set. effort_max ordering comes later.
        if let Some(e) = filter.effort_max {
            q = q.eq("effort", e.as_db_str());
        }
        fetch_json::<Vec<SharedGap>>(q, "shared_gaps").await
    }

    /// Reserve a new gap. Mirrors local `chump gap reserve`. When authenticated
    /// via user JWT, RLS enforces `created_by_user_id = auth.uid()`; with the
    /// service-role key any UUID is allowed.
    #[allow(clippy::too_many_arguments)] // mirror of CLI args; builder would be over-engineering
    pub async fn reserve_gap(
        &self,
        gap_id: &str,
        team_id: Uuid,
        domain: &str,
        title: &str,
        priority: Priority,
        effort: Effort,
        created_by_user_id: Uuid,
    ) -> Result<SharedGap> {
        let payload = serde_json::json!({
            "id": gap_id,
            "team_id": team_id,
            "domain": domain,
            "title": title,
            "priority": priority.as_db_str(),
            "effort": effort.as_db_str(),
            "status": "open",
            "created_by_user_id": created_by_user_id,
        });
        let q = self
            .postgrest()
            .from("shared_gaps")
            .insert(payload.to_string());
        let rows: Vec<SharedGap> = fetch_json(q, "shared_gaps").await?;
        rows.into_iter().next().ok_or_else(|| {
            ChumpTeamError::Other(anyhow::anyhow!(
                "reserve_gap: insert returned no row (representation header missing?)"
            ))
        })
    }

    /// Fetch one gap by ID. Returns None if not visible (RLS) or missing.
    pub async fn get_gap(&self, gap_id: &str) -> Result<Option<SharedGap>> {
        let q = self
            .postgrest()
            .from("shared_gaps")
            .select("*")
            .eq("id", gap_id)
            .limit(1);
        let rows: Vec<SharedGap> = fetch_json(q, "shared_gaps").await?;
        Ok(rows.into_iter().next())
    }

    /// Update gap metadata. Only the patched fields are touched. Bumps
    /// updated_at server-side.
    pub async fn update_gap(&self, gap_id: &str, patch: GapPatch) -> Result<SharedGap> {
        let mut payload = serde_json::Map::new();
        if let Some(s) = patch.status {
            payload.insert("status".into(), s.as_db_str().into());
        }
        if let Some(d) = patch.description {
            payload.insert("description".into(), d.into());
        }
        if let Some(ac) = patch.acceptance_criteria {
            payload.insert("acceptance_criteria".into(), ac.into());
        }
        if let Some(n) = patch.notes {
            payload.insert("notes".into(), n.into());
        }
        if let Some(pr) = patch.closed_pr {
            payload.insert("closed_pr".into(), pr.into());
        }
        if let Some(p) = patch.priority {
            payload.insert("priority".into(), p.as_db_str().into());
        }
        if let Some(e) = patch.effort {
            payload.insert("effort".into(), e.as_db_str().into());
        }
        payload.insert("updated_at".into(), Utc::now().to_rfc3339().into());

        let q = self
            .postgrest()
            .from("shared_gaps")
            .update(serde_json::Value::Object(payload).to_string())
            .eq("id", gap_id);
        let rows: Vec<SharedGap> = fetch_json(q, "shared_gaps").await?;
        rows.into_iter().next().ok_or_else(|| {
            ChumpTeamError::Other(anyhow::anyhow!(
                "update_gap: returned no row (gap_id={gap_id} not found or not visible)"
            ))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn priority_db_strings() {
        assert_eq!(Priority::P0.as_db_str(), "P0");
        assert_eq!(Priority::P3.as_db_str(), "P3");
    }

    #[test]
    fn effort_db_strings() {
        assert_eq!(Effort::Xs.as_db_str(), "xs");
        assert_eq!(Effort::S.as_db_str(), "s");
        assert_eq!(Effort::M.as_db_str(), "m");
        assert_eq!(Effort::L.as_db_str(), "l");
    }

    #[test]
    fn gap_status_db_strings() {
        assert_eq!(GapStatus::Open.as_db_str(), "open");
        assert_eq!(GapStatus::Shipped.as_db_str(), "shipped");
    }

    #[test]
    fn gap_patch_default_empty() {
        let p = GapPatch::default();
        assert!(p.status.is_none());
        assert!(p.description.is_none());
    }
}
