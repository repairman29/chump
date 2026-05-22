//! Team auth: API keys + JWT identity.
//!
//! INFRA-1665 Phase 0 — type scaffolding. Full implementations land in
//! follow-up gaps once the Supabase project is provisioned.

use crate::errors::ChumpTeamError;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Identity returned by `whoami()`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TeamAuth {
    pub user_id: Uuid,
    pub team_id: Uuid,
    pub team_slug: String,
    pub role: TeamRole,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TeamRole {
    Owner,
    Admin,
    Operator,
    Viewer,
}

/// An API key as stored in `team_api_keys`. The plaintext key is shown
/// ONCE at creation and never persisted — only the bcrypt hash lives in
/// the database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TeamApiKey {
    pub id: Uuid,
    pub team_id: Uuid,
    pub user_id: Uuid,
    pub prefix: String,
    pub description: Option<String>,
    pub created_at: DateTime<Utc>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
}

/// Returned by `create_api_key` — the only time the plaintext is visible.
pub struct ApiKeyCreated {
    pub key: TeamApiKey,
    pub plaintext: String,
}

fn unimpl(method: &'static str) -> ChumpTeamError {
    ChumpTeamError::Other(anyhow::anyhow!(
        "{method}: not yet implemented in Phase 0 (INFRA-1665 scaffolding)"
    ))
}

impl ChumpTeam {
    /// Resolve the current identity. Requires a user JWT to be configured.
    pub async fn whoami(&self) -> Result<TeamAuth> {
        let _ = self;
        Err(unimpl("whoami"))
    }

    /// Create a new API key for the current user. Returns the plaintext key
    /// only on success; subsequent reads return only the prefix.
    pub async fn create_api_key(
        &self,
        _team_id: Uuid,
        _description: Option<String>,
    ) -> Result<ApiKeyCreated> {
        Err(unimpl("create_api_key"))
    }

    /// List the calling user's API keys.
    pub async fn list_api_keys(&self) -> Result<Vec<TeamApiKey>> {
        let _ = self;
        Ok(vec![])
    }

    /// Revoke an API key by ID. Caller must own it (enforced by RLS).
    pub async fn revoke_api_key(&self, _id: Uuid) -> Result<()> {
        Ok(())
    }
}
