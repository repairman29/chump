//! Cross-agent context discoveries with vector-similarity retrieval
//! (INFRA-1473 surface).
//!
//! Phase 0 ships types + signatures. The embedding-generation glue and the
//! actual pgvector queries land in the INFRA-1473 implementation gap.

use crate::errors::ChumpTeamError;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NuggetKind {
    Gotcha,
    Pattern,
    DeadEnd,
    FailureMode,
    Convention,
    Other,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    Low,
    Medium,
    High,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Nugget {
    pub id: Uuid,
    pub team_id: Uuid,
    pub gap_id: Option<String>,
    pub repo_url: String,
    pub repo_path_glob: Option<String>,
    pub author_user_id: Uuid,
    pub author_session_id: Option<String>,
    pub author_machine: Option<String>,
    pub title: String,
    pub body: String,
    /// 1536-dim embedding. Empty when read via list/get without similarity.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub embedding: Option<Vec<f32>>,
    pub kind: NuggetKind,
    pub confidence: Confidence,
    pub keeper: bool,
    pub created_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    pub deleted_at: Option<DateTime<Utc>>,
}

/// Similarity-search query.
#[derive(Debug, Clone)]
pub struct NuggetQuery {
    /// Free-text query; will be embedded server-side or client-side.
    pub query_text: String,
    /// Restrict to nuggets for this repo URL.
    pub repo_url: Option<String>,
    /// Restrict to specific kinds (empty = all kinds).
    pub kinds: Vec<NuggetKind>,
    /// Top-K to return.
    pub limit: usize,
    /// Minimum cosine similarity (0..1) for inclusion.
    pub min_similarity: f32,
}

impl Default for NuggetQuery {
    fn default() -> Self {
        Self {
            query_text: String::new(),
            repo_url: None,
            kinds: vec![],
            limit: 8,
            min_similarity: 0.5,
        }
    }
}

/// Result of a similarity search.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NuggetMatch {
    pub nugget: Nugget,
    /// Cosine similarity score [0..1].
    pub similarity: f32,
}

fn unimpl(method: &'static str) -> ChumpTeamError {
    ChumpTeamError::Other(anyhow::anyhow!(
        "{method}: not yet implemented in Phase 0 (INFRA-1665 scaffolding); \
         INFRA-1473 will fill this in"
    ))
}

impl ChumpTeam {
    /// Insert a new nugget. Embedding is computed by the caller (or by a
    /// server-side trigger) — the value passes through unchanged.
    pub async fn create_nugget(
        &self,
        _team_id: Uuid,
        _repo_url: &str,
        _title: &str,
        _body: &str,
        _kind: NuggetKind,
        _embedding: Vec<f32>,
    ) -> Result<Nugget> {
        Err(unimpl("create_nugget"))
    }

    /// Similarity search. Returns Top-K nuggets above min_similarity.
    pub async fn search_nuggets(&self, _query: NuggetQuery) -> Result<Vec<NuggetMatch>> {
        Err(unimpl("search_nuggets"))
    }

    /// Log that a session read a particular nugget (audit trail).
    pub async fn log_nugget_read(
        &self,
        _nugget_id: Uuid,
        _session_id: &str,
        _gap_id: Option<&str>,
        _similarity: f32,
    ) -> Result<()> {
        Err(unimpl("log_nugget_read"))
    }

    /// Soft-delete a nugget. Author or admin only (enforced by RLS).
    pub async fn delete_nugget(&self, _id: Uuid) -> Result<()> {
        Err(unimpl("delete_nugget"))
    }
}
