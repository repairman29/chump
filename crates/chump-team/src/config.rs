//! Configuration loading for `chump-team`.
//!
//! Resolution order (later wins):
//!   1. defaults
//!   2. ~/.chump/team.toml          (operator-wide)
//!   3. <repo>/.chump/team.toml     (repo-specific override)
//!   4. environment variables       (highest precedence)

use crate::errors::{ChumpTeamError, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChumpTeamConfig {
    /// Supabase project URL (e.g. https://abc.supabase.co)
    pub url: String,
    /// API key — either the project's anon key (preferred, daily-driver)
    /// or service-role key (admin / migrations only).
    pub api_key: String,
    /// Optional user JWT. Required for RLS policies to apply; if absent,
    /// requests are made with anonymous auth context (which usually means
    /// nothing is visible).
    pub user_jwt: Option<String>,
    /// Team this operator currently has selected. Optional — single-team
    /// users default to the only team they belong to.
    pub active_team_slug: Option<String>,
}

impl ChumpTeamConfig {
    /// Load from environment variables. The MVP path; later we'll layer
    /// in TOML config loading.
    pub fn from_env() -> Result<Self> {
        let url = std::env::var("CHUMP_TEAM_URL")
            .map_err(|_| ChumpTeamError::MissingEnv("CHUMP_TEAM_URL"))?;
        let api_key = std::env::var("CHUMP_TEAM_API_KEY")
            .map_err(|_| ChumpTeamError::MissingEnv("CHUMP_TEAM_API_KEY"))?;
        let user_jwt = std::env::var("CHUMP_TEAM_JWT").ok();
        let active_team_slug = std::env::var("CHUMP_TEAM_SLUG").ok();
        Ok(Self {
            url,
            api_key,
            user_jwt,
            active_team_slug,
        })
    }
}
