//! # Work board (FLEET-008)
//!
//! NATS-backed shared work queue for the FLEET vision Layer 2 (Work
//! Decomposition & Claiming). An agent that hits a too-large gap can
//! `post_subtask` to publish a smaller piece of work; another agent on
//! the fleet polls or watches the board, scores the subtask against its
//! own capabilities, and `claim_subtask`s it. State transitions are
//! atomic via NATS KV CAS (revision-guarded `update`), so two agents
//! cannot both succeed at claiming the same subtask.
//!
//! Schema mirrors the sketch in `docs/strategy/FLEET_VISION_2026Q2.md`:
//!
//! ```text
//! Subtask {
//!   subtask_id, parent_gap, title, description,
//!   requirement: { task_class, required_model_family, min_vram_gb,
//!                  min_inference_speed, estimated_duration_sec, decomposable },
//!   posted_by, posted_at,
//!   claimed_by, claimed_at, completed_at, completed_commit,
//!   status: open | claimed | completed | failed,
//! }
//! ```
//!
//! FLEET-010 (help-seeking) lives in its own bucket
//! [`crate::help_request`] rather than nested on Subtask, so help
//! requests can hang off either a subtask or a parent gap and survive
//! across subtask state transitions.
//!
//! ## Atomicity
//!
//! - **`post_subtask`** uses `kv::Store::create` — fails atomically if a
//!   subtask with the same id already exists. The id is generated from a
//!   v4 UUID by default, so collisions are statistically impossible.
//! - **`claim_subtask`** reads the current entry's revision, then calls
//!   `kv::Store::update(key, new_value, revision)`. If another agent
//!   claimed first, the revision is stale and the update fails — we
//!   return `Ok(false)` so the caller knows it lost the race.
//! - **`complete_subtask` / `fail_subtask`** are also revision-guarded:
//!   only the claim holder can complete a subtask it actually owns.
//!
//! ## Events
//!
//! Every state transition also publishes a `CoordEvent` on
//! `chump.events.work_board.{posted,claimed,completed,failed}` so that
//! `chump-coord watch` and the ambient stream see real-time fanout.
//!
//! ## NATS unavailable
//!
//! The work board has **no filesystem fallback** — unlike gap claims
//! (which fall back to `.chump-locks/`), there is no per-machine
//! analogue of a fleet work queue. Callers must detect a `None` from
//! [`crate::CoordClient::connect_or_skip`] and either skip or post
//! locally and retry later.

use anyhow::{anyhow, Result};
use async_nats::jetstream::{self, kv};
use bytes::Bytes;
use chrono::Utc;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;

use crate::{CoordClient, CoordEvent, EVENTS_SUBJECT};

/// KV bucket name for work-board subtask state.
///
/// Per-test override via `CHUMP_NATS_WORK_BOARD_BUCKET` so integration
/// tests get a fresh bucket and don't pollute the production queue.
pub const WORK_BOARD_BUCKET: &str = "chump_work_board";

/// Default subtask TTL — 7 days. After this, abandoned subtasks
/// auto-expire from the KV bucket; explicit completion before the TTL
/// is the normal path.
pub const DEFAULT_WORK_BOARD_TTL_SECS: u64 = 7 * 86_400;

/// Subject prefix for work-board events. Subtask events land on
/// `chump.events.work_board.{posted,claimed,completed,failed}`.
pub const WORK_BOARD_EVENT_PREFIX: &str = "work_board";

// ── Types ────────────────────────────────────────────────────────────────────

/// Subtask lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SubtaskStatus {
    /// Posted, no claimant yet.
    Open,
    /// One agent has claimed it; work is in flight.
    Claimed,
    /// Successfully completed by the claimant.
    Completed,
    /// The claimant gave up or hit an unrecoverable error.
    Failed,
}

/// Capability requirements for fitting a subtask to an agent.
///
/// Mirrors `TaskRequirement` in FLEET_VISION_2026Q2.md but using
/// snake_case Rust idioms. All fields except `task_class` are
/// optional — an agent posting a "review" subtask doesn't need to know
/// the reviewing agent's VRAM.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Requirement {
    /// Required task class, e.g. "review", "refactor", "test-writing",
    /// "gap-filling". Free-form for v1; FLEET-009 capability matching
    /// will tighten the vocabulary.
    pub task_class: String,
    /// Optional model family preference: "anthropic" | "open-source" | "local".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_model_family: Option<String>,
    /// Optional minimum VRAM in GB.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_vram_gb: Option<u32>,
    /// Optional minimum inference speed in tokens/sec.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_inference_speed_tok_per_sec: Option<f32>,
    /// Caller's estimate of how long this subtask should take.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_duration_sec: Option<u32>,
    /// `true` if the claimant is allowed to break this subtask down
    /// further (recursive decomposition). Defaults to false.
    #[serde(default)]
    pub decomposable: bool,
}

/// A unit of work posted to the shared board.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subtask {
    /// Unique subtask id, e.g. "SUBTASK-7f3c1a92".
    pub subtask_id: String,
    /// Gap that spawned this subtask, e.g. "PRODUCT-009".
    pub parent_gap: String,
    /// One-line summary.
    pub title: String,
    /// Free-form description; can be empty.
    #[serde(default)]
    pub description: String,
    /// Capability requirements for claiming this subtask.
    pub requirement: Requirement,
    /// Session ID of the posting agent.
    pub posted_by: String,
    /// RFC3339 timestamp of when the subtask was posted.
    pub posted_at: String,
    /// Session ID of the claiming agent (set on transition Open→Claimed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed_by: Option<String>,
    /// RFC3339 timestamp of when the subtask was claimed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed_at: Option<String>,
    /// RFC3339 timestamp of when the subtask reached a terminal state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// Commit SHA or PR number associated with completion (free-form).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_commit: Option<String>,
    /// Free-form failure reason when status == Failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_reason: Option<String>,
    /// Current lifecycle state.
    pub status: SubtaskStatus,
}

impl Subtask {
    /// Build a freshly-posted Subtask from minimal inputs. Generates a
    /// new subtask id and stamps `posted_at` to "now".
    pub fn new(parent_gap: &str, title: &str, posted_by: &str, requirement: Requirement) -> Self {
        Self {
            subtask_id: generate_subtask_id(),
            parent_gap: parent_gap.to_string(),
            title: title.to_string(),
            description: String::new(),
            requirement,
            posted_by: posted_by.to_string(),
            posted_at: Utc::now().to_rfc3339(),
            claimed_by: None,
            claimed_at: None,
            completed_at: None,
            completed_commit: None,
            failure_reason: None,
            status: SubtaskStatus::Open,
        }
    }
}

/// Generate a fresh `SUBTASK-<8hex>` id.
pub fn generate_subtask_id() -> String {
    let u = uuid::Uuid::new_v4();
    let s = u.simple().to_string();
    format!("SUBTASK-{}", &s[..8])
}

// ── KV bucket setup ───────────────────────────────────────────────────────────

/// Initialise (or attach to) the work-board KV bucket. Called once
/// during [`CoordClient::connect`].
pub(crate) async fn init_bucket(js: &jetstream::Context) -> Result<kv::Store> {
    let bucket_name = std::env::var("CHUMP_NATS_WORK_BOARD_BUCKET")
        .unwrap_or_else(|_| WORK_BOARD_BUCKET.to_string());
    let ttl_secs: u64 = std::env::var("CHUMP_WORK_BOARD_TTL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_WORK_BOARD_TTL_SECS);
    js.create_key_value(kv::Config {
        bucket: bucket_name,
        max_age: Duration::from_secs(ttl_secs),
        history: 16, // keep some claim/complete history for debugging
        ..Default::default()
    })
    .await
    .map_err(|e| anyhow!("work-board KV bucket setup failed: {}", e))
}

// ── Outcome of claim / complete attempts ──────────────────────────────────────

/// Why a CAS-guarded transition didn't take.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransitionMiss {
    /// The subtask id wasn't found in the bucket.
    NotFound,
    /// Another agent's update raced ahead of this one.
    StaleRevision,
    /// The current state doesn't allow the requested transition
    /// (e.g. trying to claim something that's already Completed).
    WrongState(SubtaskStatus),
    /// `complete_subtask` / `fail_subtask` was called by a session that
    /// is not the claim holder.
    NotClaimHolder { holder: String, caller: String },
}

// ── CoordClient methods ──────────────────────────────────────────────────────

impl CoordClient {
    /// Post a subtask to the shared work board.
    ///
    /// Uses [`kv::Store::create`] so two agents that somehow generate
    /// the same subtask id cannot both succeed; the second hits
    /// `AlreadyExists`.
    pub async fn post_subtask(&self, subtask: &Subtask) -> Result<()> {
        let key = subtask_key(&subtask.subtask_id);
        let value: Bytes = serde_json::to_vec(subtask)?.into();
        self.work_board_kv
            .create(&key, value)
            .await
            .map_err(|e| anyhow!("work-board post error: {}", e))?;
        // Best-effort fanout — failure to publish the event must NOT
        // roll back the post (the subtask is already on the board).
        let _ = self
            .emit_work_board_event(
                "posted",
                CoordEvent {
                    event: "WORK_POSTED".to_string(),
                    session: subtask.posted_by.clone(),
                    ts: Utc::now().to_rfc3339(),
                    gap: Some(subtask.parent_gap.clone()),
                    reason: Some(subtask.subtask_id.clone()),
                    files: Some(subtask.title.clone()),
                    ..Default::default()
                },
            )
            .await;
        Ok(())
    }

    /// Read a subtask by id.
    pub async fn get_subtask(&self, subtask_id: &str) -> Result<Option<Subtask>> {
        let key = subtask_key(subtask_id);
        match self.work_board_kv.get(&key).await {
            Ok(Some(bytes)) => Ok(Some(serde_json::from_slice::<Subtask>(&bytes)?)),
            Ok(None) => Ok(None),
            Err(e) => Err(anyhow!("work-board get error: {}", e)),
        }
    }

    /// List all subtasks currently on the board.
    ///
    /// `filter_status` filters to a single status if provided; pass
    /// `None` to list everything (including completed/failed entries
    /// that haven't yet aged out via TTL).
    pub async fn list_subtasks(
        &self,
        filter_status: Option<SubtaskStatus>,
    ) -> Result<Vec<Subtask>> {
        let mut keys = self
            .work_board_kv
            .keys()
            .await
            .map_err(|e| anyhow!("work-board keys error: {}", e))?;
        let mut out = Vec::new();
        while let Some(key_result) = keys.next().await {
            let key = key_result.map_err(|e| anyhow!("work-board key stream error: {}", e))?;
            if let Ok(Some(bytes)) = self.work_board_kv.get(&key).await {
                if let Ok(subtask) = serde_json::from_slice::<Subtask>(&bytes) {
                    if filter_status.is_none_or(|s| s == subtask.status) {
                        out.push(subtask);
                    }
                }
            }
        }
        Ok(out)
    }

    /// Atomically claim an open subtask. Returns:
    /// - `Ok(Ok(updated_subtask))` if the claim succeeded.
    /// - `Ok(Err(reason))` if it didn't (stale revision, wrong state, not found).
    /// - `Err(_)` for transport / serialization errors.
    pub async fn claim_subtask(
        &self,
        subtask_id: &str,
        session_id: &str,
    ) -> Result<std::result::Result<Subtask, TransitionMiss>> {
        let key = subtask_key(subtask_id);
        let entry = match self.work_board_kv.entry(&key).await {
            Ok(Some(e)) => e,
            Ok(None) => return Ok(Err(TransitionMiss::NotFound)),
            Err(e) => return Err(anyhow!("work-board entry error: {}", e)),
        };
        let mut subtask: Subtask = serde_json::from_slice(&entry.value)?;
        if subtask.status != SubtaskStatus::Open {
            return Ok(Err(TransitionMiss::WrongState(subtask.status)));
        }
        subtask.status = SubtaskStatus::Claimed;
        subtask.claimed_by = Some(session_id.to_string());
        subtask.claimed_at = Some(Utc::now().to_rfc3339());
        let payload: Bytes = serde_json::to_vec(&subtask)?.into();
        match self
            .work_board_kv
            .update(&key, payload, entry.revision)
            .await
        {
            Ok(_) => {
                let _ = self
                    .emit_work_board_event(
                        "claimed",
                        CoordEvent {
                            event: "WORK_CLAIMED".to_string(),
                            session: session_id.to_string(),
                            ts: Utc::now().to_rfc3339(),
                            gap: Some(subtask.parent_gap.clone()),
                            reason: Some(subtask.subtask_id.clone()),
                            ..Default::default()
                        },
                    )
                    .await;
                Ok(Ok(subtask))
            }
            // The async-nats UpdateError doesn't expose a "revision mismatch"
            // discriminant we can match by name in 0.47, but any failure here
            // is treated as a CAS miss — the caller falls back to retrying
            // or picking a different subtask.
            Err(_) => Ok(Err(TransitionMiss::StaleRevision)),
        }
    }

    /// Mark a claimed subtask as completed. Only the original claimant
    /// is permitted to complete it.
    pub async fn complete_subtask(
        &self,
        subtask_id: &str,
        session_id: &str,
        commit_or_pr: Option<&str>,
    ) -> Result<std::result::Result<Subtask, TransitionMiss>> {
        self.terminate_subtask(
            subtask_id,
            session_id,
            SubtaskStatus::Completed,
            commit_or_pr.map(|s| s.to_string()),
            None,
            "completed",
            "WORK_COMPLETED",
        )
        .await
    }

    /// Mark a claimed subtask as failed. Same authorisation rule as
    /// complete (only the claimant can fail their own subtask).
    pub async fn fail_subtask(
        &self,
        subtask_id: &str,
        session_id: &str,
        reason: &str,
    ) -> Result<std::result::Result<Subtask, TransitionMiss>> {
        self.terminate_subtask(
            subtask_id,
            session_id,
            SubtaskStatus::Failed,
            None,
            Some(reason.to_string()),
            "failed",
            "WORK_FAILED",
        )
        .await
    }

    // Shared body for complete + fail — both are revision-guarded
    // transitions out of Claimed into a terminal status, gated on the
    // caller actually being the claim holder.
    #[allow(clippy::too_many_arguments)] // crate-internal helper, all args needed
    async fn terminate_subtask(
        &self,
        subtask_id: &str,
        session_id: &str,
        target: SubtaskStatus,
        completed_commit: Option<String>,
        failure_reason: Option<String>,
        event_suffix: &str,
        event_type: &str,
    ) -> Result<std::result::Result<Subtask, TransitionMiss>> {
        let key = subtask_key(subtask_id);
        let entry = match self.work_board_kv.entry(&key).await {
            Ok(Some(e)) => e,
            Ok(None) => return Ok(Err(TransitionMiss::NotFound)),
            Err(e) => return Err(anyhow!("work-board entry error: {}", e)),
        };
        let mut subtask: Subtask = serde_json::from_slice(&entry.value)?;
        if subtask.status != SubtaskStatus::Claimed {
            return Ok(Err(TransitionMiss::WrongState(subtask.status)));
        }
        let holder = subtask.claimed_by.clone().unwrap_or_default();
        if holder != session_id {
            return Ok(Err(TransitionMiss::NotClaimHolder {
                holder,
                caller: session_id.to_string(),
            }));
        }
        subtask.status = target;
        subtask.completed_at = Some(Utc::now().to_rfc3339());
        subtask.completed_commit = completed_commit;
        subtask.failure_reason = failure_reason;
        let payload: Bytes = serde_json::to_vec(&subtask)?.into();
        match self
            .work_board_kv
            .update(&key, payload, entry.revision)
            .await
        {
            Ok(_) => {
                let _ = self
                    .emit_work_board_event(
                        event_suffix,
                        CoordEvent {
                            event: event_type.to_string(),
                            session: session_id.to_string(),
                            ts: Utc::now().to_rfc3339(),
                            gap: Some(subtask.parent_gap.clone()),
                            reason: Some(subtask.subtask_id.clone()),
                            commit: subtask.completed_commit.clone(),
                            ..Default::default()
                        },
                    )
                    .await;
                Ok(Ok(subtask))
            }
            Err(_) => Ok(Err(TransitionMiss::StaleRevision)),
        }
    }

    /// Internal: publish a work-board event on
    /// `chump.events.work_board.<suffix>`. Best-effort.
    async fn emit_work_board_event(&self, suffix: &str, event: CoordEvent) -> Result<()> {
        let subject = format!("{}.{}.{}", EVENTS_SUBJECT, WORK_BOARD_EVENT_PREFIX, suffix);
        let payload: Bytes = serde_json::to_vec(&event)?.into();
        self.js_publish_raw(&subject, payload).await
    }
}

/// KV key for a subtask. NATS KV keys allow `.` so we mirror the
/// gap-claim convention (`gap.<id>`).
fn subtask_key(subtask_id: &str) -> String {
    format!("subtask.{}", subtask_id)
}
