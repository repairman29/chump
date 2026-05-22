//! Cross-agent context discoveries with vector-similarity retrieval
//! (INFRA-1473 — Marcus M-D Phase 2).
//!
//! Phase 0 (INFRA-1665) shipped the schema (nuggets, nugget_reads, pgvector,
//! HNSW). Phase 2 (this file, INFRA-1473) implements the Rust API that:
//!
//!   1. Embeds nugget body text via OpenAI text-embedding-3-small (1536-dim,
//!      matching the schema). When OPENAI_API_KEY is unset, nuggets are
//!      stored with NULL embedding — search excludes them until reindex.
//!   2. Inserts into shared.nuggets; RLS scopes the row to team_id.
//!   3. Searches via pgvector cosine similarity (HNSW index), top-K with a
//!      min_similarity floor and optional repo_url boost.
//!   4. Logs reads to nugget_reads for the cross-pollination audit (AC #6).
//!   5. Auto-promotes a nugget to keeper=true after N distinct sessions read it.
//!
//! Privacy: when an embedding API is configured, the body of every nugget
//! leaves the operator's machine. Documented in docs/security/NUGGET_DATAFLOW.md.

use crate::errors::ChumpTeamError;
use crate::gaps::fetch_json;
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

impl NuggetKind {
    fn as_db_str(&self) -> &'static str {
        match self {
            NuggetKind::Gotcha => "gotcha",
            NuggetKind::Pattern => "pattern",
            NuggetKind::DeadEnd => "dead_end",
            NuggetKind::FailureMode => "failure_mode",
            NuggetKind::Convention => "convention",
            NuggetKind::Other => "other",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    Low,
    Medium,
    High,
}

impl Confidence {
    fn as_db_str(&self) -> &'static str {
        match self {
            Confidence::Low => "low",
            Confidence::Medium => "medium",
            Confidence::High => "high",
        }
    }
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

/// Similarity-search query parameters.
#[derive(Debug, Clone)]
pub struct NuggetQuery {
    /// Free-text query; will be embedded by the same path that embeds nuggets.
    pub query_text: String,
    /// Restrict to nuggets for this repo URL (boosts ranking + filters out
    /// other-repo nuggets entirely).
    pub repo_url: Option<String>,
    /// Restrict to specific kinds (empty = all kinds).
    pub kinds: Vec<NuggetKind>,
    /// Top-K to return.
    pub limit: usize,
    /// Minimum cosine similarity (0..1) for inclusion. 0.6 is a reasonable
    /// default — below that the matches tend to be incidental.
    pub min_similarity: f32,
}

impl Default for NuggetQuery {
    fn default() -> Self {
        Self {
            query_text: String::new(),
            repo_url: None,
            kinds: vec![],
            limit: 5,
            min_similarity: 0.6,
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

/// Auto-keeper threshold: after this many DISTINCT reading sessions on a
/// nugget, promote keeper=true so it survives the 30-day expiry sweep.
pub const KEEPER_AUTO_PROMOTE_READS: i64 = 3;

/// Embedding model + dimension contract. Pinned to text-embedding-3-small
/// because the schema's `vector(1536)` column is fixed at this dimension.
const EMBED_MODEL: &str = "text-embedding-3-small";
const EMBED_DIM: usize = 1536;

/// Embedding mode for create_nugget:
///   - `AutoEmbed`: call OpenAI if OPENAI_API_KEY is set; else store NULL embedding.
///   - `Provided(vec)`: caller already computed the embedding (test fixtures, batch reindex).
///   - `Skip`: never embed; store NULL. Search will exclude this nugget.
#[derive(Debug, Clone)]
pub enum EmbedMode {
    AutoEmbed,
    Provided(Vec<f32>),
    Skip,
}

/// Embed a string using OpenAI's text-embedding-3-small endpoint.
/// Returns None if OPENAI_API_KEY is unset (caller should treat as Skip).
/// Errors only on transport / auth / bad response — operator-visible.
pub async fn embed_text(text: &str) -> Result<Option<Vec<f32>>> {
    let api_key = match std::env::var("OPENAI_API_KEY") {
        Ok(k) if !k.is_empty() => k,
        _ => return Ok(None),
    };
    let endpoint = std::env::var("OPENAI_EMBED_ENDPOINT")
        .unwrap_or_else(|_| "https://api.openai.com/v1/embeddings".to_string());
    let payload = serde_json::json!({
        "model": EMBED_MODEL,
        "input": text,
    });
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("reqwest build: {e}")))?;
    let resp = client
        .post(&endpoint)
        .bearer_auth(api_key)
        .json(&payload)
        .send()
        .await
        .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("openai request: {e}")))?;
    if !resp.status().is_success() {
        let status = resp.status().as_u16();
        let body = resp.text().await.unwrap_or_default();
        return Err(ChumpTeamError::Http { status, body });
    }
    #[derive(Deserialize)]
    struct EmbedResp {
        data: Vec<EmbedData>,
    }
    #[derive(Deserialize)]
    struct EmbedData {
        embedding: Vec<f32>,
    }
    let parsed: EmbedResp = resp
        .json()
        .await
        .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("openai parse: {e}")))?;
    let vec = parsed
        .data
        .into_iter()
        .next()
        .ok_or_else(|| ChumpTeamError::Other(anyhow::anyhow!("openai: empty data")))?
        .embedding;
    if vec.len() != EMBED_DIM {
        return Err(ChumpTeamError::Other(anyhow::anyhow!(
            "openai returned {} dims; schema expects {EMBED_DIM}",
            vec.len()
        )));
    }
    Ok(Some(vec))
}

impl ChumpTeam {
    /// Insert a new nugget. See [`EmbedMode`] for embedding behavior.
    /// Returns the created Nugget. Embedding is dropped from the returned
    /// row to keep RPC payloads small (use `get_nugget_with_embedding` to
    /// re-fetch if needed).
    #[allow(clippy::too_many_arguments)]
    pub async fn create_nugget(
        &self,
        team_id: Uuid,
        repo_url: &str,
        author_user_id: Uuid,
        title: &str,
        body: &str,
        kind: NuggetKind,
        confidence: Confidence,
        embed: EmbedMode,
        gap_id: Option<&str>,
    ) -> Result<Nugget> {
        let embedding = match embed {
            EmbedMode::Provided(v) => Some(v),
            EmbedMode::Skip => None,
            EmbedMode::AutoEmbed => {
                // Concatenate title+body to maximize semantic recall.
                let full = format!("{title}\n\n{body}");
                embed_text(&full).await?
            }
        };
        let expires_at = Utc::now() + chrono::Duration::days(30);
        let payload = serde_json::json!({
            "team_id": team_id,
            "repo_url": repo_url,
            "author_user_id": author_user_id,
            "title": title,
            "body": body,
            "kind": kind.as_db_str(),
            "confidence": confidence.as_db_str(),
            "embedding": embedding,
            "expires_at": expires_at.to_rfc3339(),
            "gap_id": gap_id,
        });
        let q = self.postgrest().from("nuggets").insert(payload.to_string());
        let mut rows: Vec<Nugget> = fetch_json(q, "nuggets").await?;
        rows.pop().ok_or_else(|| {
            ChumpTeamError::Other(anyhow::anyhow!("create_nugget: insert returned no row"))
        })
    }

    /// Similarity search. Embeds the query, runs an RPC (or direct SQL via
    /// PostgREST) to rank by cosine similarity, returns top-K above threshold.
    /// When no embedding can be produced (no OPENAI_API_KEY), returns an
    /// empty Vec — caller decides whether to surface a "search unavailable"
    /// warning vs silent no-op.
    pub async fn search_nuggets(&self, query: NuggetQuery) -> Result<Vec<NuggetMatch>> {
        if query.query_text.trim().is_empty() {
            return Ok(vec![]);
        }
        // 1. Embed the query.
        let embedding = match embed_text(&query.query_text).await? {
            Some(v) => v,
            None => return Ok(vec![]), // embedder unavailable
        };
        // 2. Call a pgvector RPC. PostgREST exposes RPCs at /rpc/<name>.
        //    We expect a function `search_nuggets(query_embedding vector(1536),
        //    team_filter uuid, repo_filter text, kinds_filter text[], top_k int,
        //    min_sim real)` to exist server-side; the migration to add it lives
        //    in 0004_nugget_search_rpc.sql (this PR ships it).
        let payload = serde_json::json!({
            "query_embedding": embedding,
            "repo_filter": query.repo_url,
            "kinds_filter": query
                .kinds
                .iter()
                .map(NuggetKind::as_db_str)
                .collect::<Vec<_>>(),
            "top_k": query.limit as i32,
            "min_sim": query.min_similarity,
        });
        let resp = self
            .postgrest()
            .rpc("search_nuggets", payload.to_string())
            .execute()
            .await
            .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("rpc search_nuggets: {e}")))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| ChumpTeamError::Other(anyhow::anyhow!("search_nuggets body: {e}")))?;
        if !status.is_success() {
            return Err(ChumpTeamError::Http {
                status: status.as_u16(),
                body,
            });
        }
        // RPC returns rows with the schema columns + a `similarity` column.
        #[derive(Deserialize)]
        struct Row {
            #[serde(flatten)]
            nugget: Nugget,
            similarity: f32,
        }
        let rows: Vec<Row> = serde_json::from_str(&body).map_err(ChumpTeamError::from)?;
        Ok(rows
            .into_iter()
            .map(|r| NuggetMatch {
                nugget: r.nugget,
                similarity: r.similarity,
            })
            .collect())
    }

    /// Log that a session read a nugget (audit trail for AC #6 — "fleet B
    /// reports having read it before starting").
    pub async fn log_nugget_read(
        &self,
        nugget_id: Uuid,
        user_id: Uuid,
        session_id: &str,
        gap_id: Option<&str>,
        similarity: f32,
    ) -> Result<()> {
        let payload = serde_json::json!({
            "nugget_id": nugget_id,
            "user_id": user_id,
            "session_id": session_id,
            "gap_id": gap_id,
            "similarity": similarity,
        });
        let q = self
            .postgrest()
            .from("nugget_reads")
            .insert(payload.to_string());
        // Ignore conflict (idempotent: same session reading same nugget twice).
        match fetch_json::<Vec<serde_json::Value>>(q, "nugget_reads").await {
            Ok(_) => {}
            Err(ChumpTeamError::Conflict { .. }) => {}
            Err(e) => return Err(e),
        }
        // Auto-promote-to-keeper check.
        self.maybe_promote_keeper(nugget_id).await?;
        Ok(())
    }

    /// Auto-keeper-promote: if KEEPER_AUTO_PROMOTE_READS distinct sessions
    /// have read this nugget, set keeper=true so it survives the 30d expiry.
    async fn maybe_promote_keeper(&self, nugget_id: Uuid) -> Result<()> {
        let q = self
            .postgrest()
            .from("nugget_reads")
            .select("session_id")
            .eq("nugget_id", nugget_id.to_string());
        let rows: Vec<serde_json::Value> = fetch_json(q, "nugget_reads").await?;
        // Count distinct session_ids.
        let mut sessions = std::collections::HashSet::new();
        for r in rows {
            if let Some(s) = r.get("session_id").and_then(|v| v.as_str()) {
                sessions.insert(s.to_string());
            }
        }
        if sessions.len() as i64 >= KEEPER_AUTO_PROMOTE_READS {
            let q = self
                .postgrest()
                .from("nuggets")
                .update(serde_json::json!({"keeper": true}).to_string())
                .eq("id", nugget_id.to_string())
                .eq("keeper", "false");
            let _: Vec<serde_json::Value> = fetch_json(q, "nuggets").await?;
        }
        Ok(())
    }

    /// Soft-delete a nugget. Author or admin only (enforced by RLS).
    pub async fn delete_nugget(&self, id: Uuid) -> Result<()> {
        let payload = serde_json::json!({"deleted_at": Utc::now().to_rfc3339()});
        let q = self
            .postgrest()
            .from("nuggets")
            .update(payload.to_string())
            .eq("id", id.to_string())
            .is("deleted_at", "null");
        let _: Vec<serde_json::Value> = fetch_json(q, "nuggets").await?;
        Ok(())
    }

    /// List nuggets visible to the caller. For browsing without similarity.
    pub async fn list_nuggets(&self, repo_url: Option<&str>, limit: usize) -> Result<Vec<Nugget>> {
        let mut q = self
            .postgrest()
            .from("nuggets")
            .select("*")
            .is("deleted_at", "null")
            .order("created_at.desc")
            .limit(limit);
        if let Some(r) = repo_url {
            q = q.eq("repo_url", r);
        }
        fetch_json::<Vec<Nugget>>(q, "nuggets").await
    }

    /// Manually flag a nugget as keeper (operator command).
    pub async fn set_keeper(&self, id: Uuid, keeper: bool) -> Result<()> {
        let q = self
            .postgrest()
            .from("nuggets")
            .update(serde_json::json!({"keeper": keeper}).to_string())
            .eq("id", id.to_string());
        let _: Vec<serde_json::Value> = fetch_json(q, "nuggets").await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nugget_kind_db_strings() {
        assert_eq!(NuggetKind::Gotcha.as_db_str(), "gotcha");
        assert_eq!(NuggetKind::DeadEnd.as_db_str(), "dead_end");
        assert_eq!(NuggetKind::FailureMode.as_db_str(), "failure_mode");
    }

    #[test]
    fn confidence_db_strings() {
        assert_eq!(Confidence::Low.as_db_str(), "low");
        assert_eq!(Confidence::High.as_db_str(), "high");
    }

    #[test]
    fn default_query_is_top_5_with_06_threshold() {
        let q = NuggetQuery::default();
        assert_eq!(q.limit, 5);
        assert_eq!(q.min_similarity, 0.6);
        assert!(q.query_text.is_empty());
    }

    #[test]
    fn embed_dim_pinned_to_schema() {
        assert_eq!(EMBED_DIM, 1536);
    }

    #[test]
    fn embed_model_pinned() {
        assert_eq!(EMBED_MODEL, "text-embedding-3-small");
    }

    #[test]
    fn keeper_threshold_at_3() {
        assert_eq!(KEEPER_AUTO_PROMOTE_READS, 3);
    }

    #[tokio::test]
    async fn embed_text_returns_none_when_no_api_key() {
        // Save + clear OPENAI_API_KEY for this test.
        let saved = std::env::var("OPENAI_API_KEY").ok();
        std::env::remove_var("OPENAI_API_KEY");
        let result = embed_text("test").await.expect("embed_text");
        assert!(result.is_none());
        if let Some(v) = saved {
            std::env::set_var("OPENAI_API_KEY", v);
        }
    }
}
