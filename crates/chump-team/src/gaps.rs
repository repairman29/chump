//! Shared work queue (INFRA-1475 surface).
//!
//! Mirrors the local state.db `gaps` table for cross-operator visibility.
//! Phase 0 (INFRA-1665) ships the types only; CRUD methods are stubs that
//! get filled in by the INFRA-1475 implementation gap.

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

fn unimpl(method: &'static str) -> ChumpTeamError {
    ChumpTeamError::Other(anyhow::anyhow!(
        "{method}: not yet implemented in Phase 0 (INFRA-1665 scaffolding); \
         INFRA-1475 will fill this in"
    ))
}

impl ChumpTeam {
    /// List gaps visible to the calling user. RLS restricts to their teams.
    pub async fn list_gaps(&self, _filter: GapFilter) -> Result<Vec<SharedGap>> {
        Err(unimpl("list_gaps"))
    }

    /// Reserve a new gap. Mirrors local `chump gap reserve`.
    pub async fn reserve_gap(
        &self,
        _team_id: Uuid,
        _domain: &str,
        _title: &str,
        _priority: Priority,
        _effort: Effort,
    ) -> Result<SharedGap> {
        Err(unimpl("reserve_gap"))
    }

    /// Fetch one gap by ID.
    pub async fn get_gap(&self, _gap_id: &str) -> Result<Option<SharedGap>> {
        Err(unimpl("get_gap"))
    }

    /// Update gap metadata (description, AC, notes, status).
    pub async fn update_gap(&self, _gap_id: &str, _patch: GapPatch) -> Result<SharedGap> {
        Err(unimpl("update_gap"))
    }
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
