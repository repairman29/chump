//! Per-operator monthly quotas (INFRA-1475 AC #6 — spend-cap predecessor).
//!
//! Phase 0 scaffolding; the implementation gap wires this into the
//! existing `budget_tracker` LLM-cost dimension (INFRA-1486).

use crate::errors::ChumpTeamError;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OperatorQuota {
    pub team_id: Uuid,
    pub user_id: Uuid,
    pub max_llm_cost_usd_per_month: Option<f64>,
    pub tokens_used_current_month: i64,
    pub cost_used_current_month_usd: f64,
    pub reset_at: DateTime<Utc>,
}

fn unimpl(method: &'static str) -> ChumpTeamError {
    ChumpTeamError::Other(anyhow::anyhow!(
        "{method}: not yet implemented in Phase 0 (INFRA-1665 scaffolding)"
    ))
}

impl ChumpTeam {
    /// Fetch the calling user's quota row. None = no quota set (unlimited).
    pub async fn get_my_quota(&self) -> Result<Option<OperatorQuota>> {
        Err(unimpl("get_my_quota"))
    }

    /// Admin-only: set a quota for a team member.
    pub async fn set_quota(
        &self,
        _team_id: Uuid,
        _user_id: Uuid,
        _max_usd_per_month: Option<f64>,
    ) -> Result<OperatorQuota> {
        Err(unimpl("set_quota"))
    }

    /// Increment usage counters. Caller passes deltas; the database
    /// adds atomically (no race even with concurrent workers).
    pub async fn record_usage(&self, _tokens_delta: i64, _usd_delta: f64) -> Result<OperatorQuota> {
        Err(unimpl("record_usage"))
    }
}
