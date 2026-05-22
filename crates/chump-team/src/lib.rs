//! INFRA-1665: Marcus M-D Phase 0 — Chump team-shared substrate client.
//!
//! This crate is a thin wrapper around the Supabase PostgREST API
//! ([postgrest] crate). It encodes the schema from `supabase/migrations/`
//! as Rust types and provides methods for the operations the rest of
//! Chump needs:
//!
//! - **Auth** ([`auth`]): create / list / revoke team API keys
//! - **Shared work queue** ([`gaps`] + [`claims`]): INFRA-1475 surface
//! - **Vector-space nuggets** ([`nuggets`]): INFRA-1473 surface
//! - **Worker capability registry** ([`capabilities`])
//! - **Per-operator quotas** ([`quotas`])
//!
//! ## Auth model
//!
//! Two kinds of credentials at runtime:
//!
//! 1. **Anon key + JWT** — the operator's daily-driver. Every request
//!    carries a user-bound JWT, so the database's RLS policies enforce
//!    isolation per team membership. This is what `chump claim`,
//!    `chump fleet`, etc. use.
//!
//! 2. **Service-role key** — the schema/migration superuser. Bypasses
//!    RLS entirely. Only `chump team migrate` and admin scripts use this.
//!    Never expose to the CLI from `chump claim` etc.
//!
//! ## Deployment models
//!
//! Single code path, three URLs:
//!
//! - Operator BYO Supabase project: `CHUMP_TEAM_URL=https://abc.supabase.co`
//! - Chump-hosted (future):         `CHUMP_TEAM_URL=https://team.chump.dev`
//! - Self-hosted (Supabase local):  `CHUMP_TEAM_URL=http://localhost:54321`
//!
//! ## Offline degradation
//!
//! Per INFRA-1475 AC #7, every call SHOULD succeed against the local
//! state.db if the team endpoint is unreachable. The pattern is
//! implemented in each module via the [`Outcome`] enum — `Local` means
//! the result came from the local fallback, `Remote` means the team
//! server replied.

pub mod auth;
pub mod capabilities;
pub mod claims;
pub mod config;
pub mod errors;
pub mod gaps;
pub mod nuggets;
pub mod quotas;

pub use auth::{TeamApiKey, TeamAuth};
pub use capabilities::WorkerCapability;
pub use claims::{Claim, ClaimResult};
pub use config::ChumpTeamConfig;
pub use errors::{ChumpTeamError, Result};
pub use gaps::{Effort, GapStatus, Priority, SharedGap};
pub use nuggets::{Nugget, NuggetKind, NuggetQuery};
pub use quotas::OperatorQuota;

use postgrest::Postgrest;
use std::sync::Arc;

/// Top-level client. One per running process — clone freely (cheap).
#[derive(Clone)]
pub struct ChumpTeam {
    inner: Arc<Inner>,
}

struct Inner {
    // Held by the client even though Phase 0 only reads it via the (unused-here)
    // `config()` method below. INFRA-1473 + INFRA-1475 implementations will
    // read `config.user_jwt` and `config.active_team_slug`. Suppress dead-code
    // until then.
    #[allow(dead_code)]
    config: ChumpTeamConfig,
    postgrest: Postgrest,
}

impl ChumpTeam {
    /// Construct from env vars:
    ///   CHUMP_TEAM_URL      — Supabase project URL (required)
    ///   CHUMP_TEAM_API_KEY  — anon key OR service-role key (required)
    ///   CHUMP_TEAM_JWT      — user JWT (optional; required for RLS to apply)
    pub fn from_env() -> Result<Self> {
        let config = ChumpTeamConfig::from_env()?;
        Ok(Self::new(config))
    }

    /// Construct from an explicit config.
    pub fn new(config: ChumpTeamConfig) -> Self {
        let mut pg = Postgrest::new(format!("{}/rest/v1", config.url))
            .insert_header("apikey", &config.api_key);
        if let Some(jwt) = &config.user_jwt {
            pg = pg.insert_header("Authorization", format!("Bearer {jwt}"));
        }
        Self {
            inner: Arc::new(Inner {
                config,
                postgrest: pg,
            }),
        }
    }

    pub(crate) fn postgrest(&self) -> &Postgrest {
        &self.inner.postgrest
    }

    #[allow(dead_code)] // wired by INFRA-1473 / INFRA-1475 implementations
    pub(crate) fn config(&self) -> &ChumpTeamConfig {
        &self.inner.config
    }

    /// Smoke-test the connection. Returns Ok if the project responds
    /// and the API key is accepted.
    pub async fn ping(&self) -> Result<()> {
        // Hit the cheapest endpoint: GET on /teams?limit=1
        let resp = self
            .postgrest()
            .from("teams")
            .select("id")
            .limit(1)
            .execute()
            .await
            .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("postgrest: {e}")))?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(ChumpTeamError::Http {
                status: resp.status().as_u16(),
                body: resp.text().await.unwrap_or_default(),
            })
        }
    }
}

/// Outcome of an operation that can degrade to local fallback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome<T> {
    /// Result came from the remote team server.
    Remote(T),
    /// Team server unreachable; result came from local state.db fallback.
    Local(T),
}

impl<T> Outcome<T> {
    pub fn into_inner(self) -> T {
        match self {
            Outcome::Remote(t) | Outcome::Local(t) => t,
        }
    }

    pub fn is_remote(&self) -> bool {
        matches!(self, Outcome::Remote(_))
    }
}
