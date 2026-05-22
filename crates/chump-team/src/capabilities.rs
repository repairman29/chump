//! Worker-capability registry (which machines can claim which gaps).
//!
//! Phase 0 scaffolding; INFRA-1475 fills in the methods.

use crate::errors::ChumpTeamError;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    Claude,
    Opencode,
    Codex,
    Manual,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerCapability {
    pub team_id: Uuid,
    pub user_id: Uuid,
    pub machine: String,
    pub skills: Vec<String>,
    pub backend: Backend,
    pub max_concurrent_gaps: i32,
    pub last_heartbeat_at: DateTime<Utc>,
}

fn unimpl(method: &'static str) -> ChumpTeamError {
    ChumpTeamError::Other(anyhow::anyhow!(
        "{method}: not yet implemented in Phase 0 (INFRA-1665 scaffolding)"
    ))
}

impl ChumpTeam {
    /// Register or update this machine's capabilities.
    pub async fn upsert_capability(&self, _cap: WorkerCapability) -> Result<()> {
        Err(unimpl("upsert_capability"))
    }

    /// Heartbeat — push last_heartbeat_at forward.
    pub async fn heartbeat(&self, _machine: &str) -> Result<()> {
        Err(unimpl("heartbeat"))
    }

    /// List all known workers in the team. Includes stale ones (for the
    /// cockpit view); filter by last_heartbeat_at client-side if needed.
    pub async fn list_capabilities(&self, _team_id: Uuid) -> Result<Vec<WorkerCapability>> {
        Err(unimpl("list_capabilities"))
    }
}
