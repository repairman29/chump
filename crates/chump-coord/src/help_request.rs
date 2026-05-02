//! # Help-seeking protocol (FLEET-010)
//!
//! When an agent hits a blocker mid-task — execution timeout, missing
//! capability (task needs a model family the agent doesn't have, or a
//! tool that isn't wired), unknown task class — it posts a
//! `HelpRequest` to the shared board. Other agents on the fleet see
//! the request, score it against their own capabilities, and claim it
//! if they're a fit. The original agent either blocks (waits on the
//! response) or continues in parallel, depending on how it set
//! [`HelpRequest::blocking`].
//!
//! FLEET-010 layers on top of FLEET-008 (work board): a help request
//! can hang off a subtask, a parent gap, or be a free-floating ask.
//! The lifecycle mirrors `Subtask` — same Open/Claimed/Completed/Failed
//! states, same revision-guarded CAS transitions, same NotClaimHolder
//! protection on completion.
//!
//! ## Schema
//!
//! Mirrors the schema sketched in
//! `docs/strategy/FLEET_VISION_2026Q2.md` Layer 2:
//!
//! ```text
//! HelpRequest {
//!   help_id, parent_subtask, parent_gap,
//!   posted_by, posted_at,
//!   blocker_type: timeout | missing_capability | unknown_task_class | other,
//!   description, needed_capability, blocking,
//!   status: open | claimed | completed | failed,
//!   claimed_by, claimed_at,
//!   completed_at, resolution, failure_reason,
//! }
//! ```
//!
//! ## Atomicity
//!
//! - **`post_help_request`** — `kv::Store::create`, fails if id collides.
//! - **`claim_help_request`** — revision-guarded `kv::Store::update`.
//!   N concurrent claims → exactly one succeeds.
//! - **`complete_help_request` / `fail_help_request`** —
//!   revision-guarded; only the claim holder may transition into a
//!   terminal state.
//!
//! Events fan out on `chump.events.help_request.{posted,claimed,completed,failed}`.

use anyhow::{anyhow, Result};
use async_nats::jetstream::{self, kv};
use bytes::Bytes;
use chrono::Utc;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;

use crate::work_board::TransitionMiss;
use crate::{CoordClient, CoordEvent, EVENTS_SUBJECT};

/// KV bucket name for help-request state.
///
/// Per-test override via `CHUMP_NATS_HELP_REQUESTS_BUCKET` so
/// integration tests get a fresh bucket and don't pollute the
/// production queue.
pub const HELP_REQUESTS_BUCKET: &str = "chump_help_requests";

/// Default help-request TTL — 7 days. Same default as the work board:
/// abandoned requests time out so the bucket doesn't grow forever.
pub const DEFAULT_HELP_REQUEST_TTL_SECS: u64 = 7 * 86_400;

/// Subject prefix for help-request events. Events land on
/// `chump.events.help_request.{posted,claimed,completed,failed}`.
pub const HELP_REQUEST_EVENT_PREFIX: &str = "help_request";

// ── Types ────────────────────────────────────────────────────────────────────

/// Why an agent is asking for help. The vision doc lists three primary
/// triggers — timeout, missing capability, unknown task class — plus an
/// `Other` escape hatch for anything else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockerType {
    /// Agent timed out (execution exceeded its budget).
    Timeout,
    /// The task requires a capability this agent doesn't have
    /// (model family, tool, MCP server, hardware).
    MissingCapability,
    /// The task class isn't in this agent's
    /// `supported_task_classes`.
    UnknownTaskClass,
    /// Free-form blocker that doesn't match any of the above.
    Other,
}

/// Help-request lifecycle state. Identical shape to `SubtaskStatus`
/// but kept distinct so help-requests and subtasks can evolve
/// independently — different events, different audit trails.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HelpStatus {
    /// Posted, no responder yet.
    Open,
    /// A responder agent has claimed it.
    Claimed,
    /// Responder finished and posted a resolution.
    Completed,
    /// Responder gave up or hit an unrecoverable error.
    Failed,
}

/// A request for help from another agent on the fleet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HelpRequest {
    /// Unique help-request id, e.g. "HELP-7f3c1a92".
    pub help_id: String,
    /// Subtask the original agent was working on, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_subtask: Option<String>,
    /// Gap the original agent was working on, if any. At least one of
    /// `parent_subtask` / `parent_gap` should be set so responders can
    /// orient themselves.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_gap: Option<String>,
    /// Why the original agent is blocked.
    pub blocker_type: BlockerType,
    /// Free-form description of the blocker.
    pub description: String,
    /// Specific capability the helper needs to have (e.g. a task class
    /// like "review", or a model family like "anthropic"). Helpers can
    /// use this to match against their own
    /// `AgentCapabilities.supported_task_classes`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needed_capability: Option<String>,
    /// `true` if the original agent is blocking (waiting) for a
    /// response. `false` if the original agent continues working in
    /// parallel and will pick up the resolution asynchronously.
    /// Vision-doc Open Question #2: blocking vs parallel semantics.
    /// V1: caller declares which mode they want; we don't enforce it.
    #[serde(default)]
    pub blocking: bool,
    /// Session ID of the agent that posted the help request.
    pub posted_by: String,
    /// RFC3339 timestamp when the help request was posted.
    pub posted_at: String,
    /// Session ID of the agent that claimed the help request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed_by: Option<String>,
    /// RFC3339 timestamp when the help request was claimed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed_at: Option<String>,
    /// RFC3339 timestamp when the help request reached a terminal state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// Free-form resolution notes from the responder (commit SHA, PR
    /// number, prose answer, etc.).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    /// Free-form failure reason when status == Failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_reason: Option<String>,
    /// Current lifecycle state.
    pub status: HelpStatus,
}

impl HelpRequest {
    /// Construct a freshly-posted `HelpRequest`. Generates a new
    /// help id and stamps `posted_at` to "now".
    pub fn new(blocker_type: BlockerType, description: &str, posted_by: &str) -> Self {
        Self {
            help_id: generate_help_id(),
            parent_subtask: None,
            parent_gap: None,
            blocker_type,
            description: description.to_string(),
            needed_capability: None,
            blocking: false,
            posted_by: posted_by.to_string(),
            posted_at: Utc::now().to_rfc3339(),
            claimed_by: None,
            claimed_at: None,
            completed_at: None,
            resolution: None,
            failure_reason: None,
            status: HelpStatus::Open,
        }
    }

    /// Builder: attach to a parent subtask.
    pub fn with_parent_subtask(mut self, subtask_id: &str) -> Self {
        self.parent_subtask = Some(subtask_id.to_string());
        self
    }

    /// Builder: attach to a parent gap.
    pub fn with_parent_gap(mut self, gap_id: &str) -> Self {
        self.parent_gap = Some(gap_id.to_string());
        self
    }

    /// Builder: declare the specific capability needed.
    pub fn with_needed_capability(mut self, cap: &str) -> Self {
        self.needed_capability = Some(cap.to_string());
        self
    }

    /// Builder: mark as a blocking request (poster is waiting).
    pub fn blocking(mut self) -> Self {
        self.blocking = true;
        self
    }
}

/// Generate a fresh `HELP-<8hex>` id.
pub fn generate_help_id() -> String {
    let u = uuid::Uuid::new_v4();
    let s = u.simple().to_string();
    format!("HELP-{}", &s[..8])
}

// ── KV bucket setup ───────────────────────────────────────────────────────────

/// Initialise (or attach to) the help-request KV bucket. Called once
/// during [`CoordClient::connect`].
pub(crate) async fn init_bucket(js: &jetstream::Context) -> Result<kv::Store> {
    let bucket_name = std::env::var("CHUMP_NATS_HELP_REQUESTS_BUCKET")
        .unwrap_or_else(|_| HELP_REQUESTS_BUCKET.to_string());
    let ttl_secs: u64 = std::env::var("CHUMP_HELP_REQUEST_TTL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_HELP_REQUEST_TTL_SECS);
    js.create_key_value(kv::Config {
        bucket: bucket_name,
        max_age: Duration::from_secs(ttl_secs),
        history: 16,
        ..Default::default()
    })
    .await
    .map_err(|e| anyhow!("help-request KV bucket setup failed: {}", e))
}

// ── CoordClient methods ──────────────────────────────────────────────────────

impl CoordClient {
    /// Post a help request to the shared board.
    pub async fn post_help_request(&self, req: &HelpRequest) -> Result<()> {
        let key = help_request_key(&req.help_id);
        let value: Bytes = serde_json::to_vec(req)?.into();
        self.help_requests_kv
            .create(&key, value)
            .await
            .map_err(|e| anyhow!("help-request post error: {}", e))?;
        let _ = self
            .emit_help_request_event(
                "posted",
                CoordEvent {
                    event: "HELP_POSTED".to_string(),
                    session: req.posted_by.clone(),
                    ts: Utc::now().to_rfc3339(),
                    gap: req.parent_gap.clone(),
                    reason: Some(req.help_id.clone()),
                    files: req.parent_subtask.clone(),
                    kind: Some(format!("{:?}", req.blocker_type).to_lowercase()),
                    ..Default::default()
                },
            )
            .await;
        Ok(())
    }

    /// Read a help request by id.
    pub async fn get_help_request(&self, help_id: &str) -> Result<Option<HelpRequest>> {
        let key = help_request_key(help_id);
        match self.help_requests_kv.get(&key).await {
            Ok(Some(bytes)) => Ok(Some(serde_json::from_slice::<HelpRequest>(&bytes)?)),
            Ok(None) => Ok(None),
            Err(e) => Err(anyhow!("help-request get error: {}", e)),
        }
    }

    /// List help requests, optionally filtered by status, parent
    /// subtask, and/or parent gap. Filters compose with AND.
    pub async fn list_help_requests(
        &self,
        filter_status: Option<HelpStatus>,
        filter_parent_subtask: Option<&str>,
        filter_parent_gap: Option<&str>,
    ) -> Result<Vec<HelpRequest>> {
        let mut keys = self
            .help_requests_kv
            .keys()
            .await
            .map_err(|e| anyhow!("help-request keys error: {}", e))?;
        let mut out = Vec::new();
        while let Some(key_result) = keys.next().await {
            let key = key_result.map_err(|e| anyhow!("help-request key stream error: {}", e))?;
            if let Ok(Some(bytes)) = self.help_requests_kv.get(&key).await {
                if let Ok(req) = serde_json::from_slice::<HelpRequest>(&bytes) {
                    if filter_status.is_some_and(|s| s != req.status) {
                        continue;
                    }
                    if let Some(want) = filter_parent_subtask {
                        if req.parent_subtask.as_deref() != Some(want) {
                            continue;
                        }
                    }
                    if let Some(want) = filter_parent_gap {
                        if req.parent_gap.as_deref() != Some(want) {
                            continue;
                        }
                    }
                    out.push(req);
                }
            }
        }
        Ok(out)
    }

    /// Atomically claim an open help request.
    pub async fn claim_help_request(
        &self,
        help_id: &str,
        session_id: &str,
    ) -> Result<std::result::Result<HelpRequest, TransitionMiss>> {
        let key = help_request_key(help_id);
        let entry = match self.help_requests_kv.entry(&key).await {
            Ok(Some(e)) => e,
            Ok(None) => return Ok(Err(TransitionMiss::NotFound)),
            Err(e) => return Err(anyhow!("help-request entry error: {}", e)),
        };
        let mut req: HelpRequest = serde_json::from_slice(&entry.value)?;
        if req.status != HelpStatus::Open {
            // Map to the work-board TransitionMiss::WrongState shape.
            // The held subtask-status enum slot stores the *help*
            // status here; callers pattern-match on the variant
            // discriminant, not the inner value semantics.
            return Ok(Err(TransitionMiss::WrongState(map_status_to_subtask(
                req.status,
            ))));
        }
        req.status = HelpStatus::Claimed;
        req.claimed_by = Some(session_id.to_string());
        req.claimed_at = Some(Utc::now().to_rfc3339());
        let payload: Bytes = serde_json::to_vec(&req)?.into();
        match self
            .help_requests_kv
            .update(&key, payload, entry.revision)
            .await
        {
            Ok(_) => {
                let _ = self
                    .emit_help_request_event(
                        "claimed",
                        CoordEvent {
                            event: "HELP_CLAIMED".to_string(),
                            session: session_id.to_string(),
                            ts: Utc::now().to_rfc3339(),
                            gap: req.parent_gap.clone(),
                            reason: Some(req.help_id.clone()),
                            files: req.parent_subtask.clone(),
                            ..Default::default()
                        },
                    )
                    .await;
                Ok(Ok(req))
            }
            Err(_) => Ok(Err(TransitionMiss::StaleRevision)),
        }
    }

    /// Mark a claimed help request as completed.
    /// Only the original claimant may complete it.
    pub async fn complete_help_request(
        &self,
        help_id: &str,
        session_id: &str,
        resolution: Option<&str>,
    ) -> Result<std::result::Result<HelpRequest, TransitionMiss>> {
        self.terminate_help_request(
            help_id,
            session_id,
            HelpStatus::Completed,
            resolution.map(|s| s.to_string()),
            None,
            "completed",
            "HELP_COMPLETED",
        )
        .await
    }

    /// Mark a claimed help request as failed. Only the claim holder
    /// may transition into Failed.
    pub async fn fail_help_request(
        &self,
        help_id: &str,
        session_id: &str,
        reason: &str,
    ) -> Result<std::result::Result<HelpRequest, TransitionMiss>> {
        self.terminate_help_request(
            help_id,
            session_id,
            HelpStatus::Failed,
            None,
            Some(reason.to_string()),
            "failed",
            "HELP_FAILED",
        )
        .await
    }

    // Shared body for complete + fail — both are revision-guarded
    // transitions out of Claimed into a terminal state, gated on the
    // caller actually being the claim holder.
    #[allow(clippy::too_many_arguments)] // crate-internal helper; mirrors work_board's
    async fn terminate_help_request(
        &self,
        help_id: &str,
        session_id: &str,
        target: HelpStatus,
        resolution: Option<String>,
        failure_reason: Option<String>,
        event_suffix: &str,
        event_type: &str,
    ) -> Result<std::result::Result<HelpRequest, TransitionMiss>> {
        let key = help_request_key(help_id);
        let entry = match self.help_requests_kv.entry(&key).await {
            Ok(Some(e)) => e,
            Ok(None) => return Ok(Err(TransitionMiss::NotFound)),
            Err(e) => return Err(anyhow!("help-request entry error: {}", e)),
        };
        let mut req: HelpRequest = serde_json::from_slice(&entry.value)?;
        if req.status != HelpStatus::Claimed {
            return Ok(Err(TransitionMiss::WrongState(map_status_to_subtask(
                req.status,
            ))));
        }
        let holder = req.claimed_by.clone().unwrap_or_default();
        if holder != session_id {
            return Ok(Err(TransitionMiss::NotClaimHolder {
                holder,
                caller: session_id.to_string(),
            }));
        }
        req.status = target;
        req.completed_at = Some(Utc::now().to_rfc3339());
        req.resolution = resolution;
        req.failure_reason = failure_reason;
        let payload: Bytes = serde_json::to_vec(&req)?.into();
        match self
            .help_requests_kv
            .update(&key, payload, entry.revision)
            .await
        {
            Ok(_) => {
                let _ = self
                    .emit_help_request_event(
                        event_suffix,
                        CoordEvent {
                            event: event_type.to_string(),
                            session: session_id.to_string(),
                            ts: Utc::now().to_rfc3339(),
                            gap: req.parent_gap.clone(),
                            reason: Some(req.help_id.clone()),
                            files: req.parent_subtask.clone(),
                            commit: req.resolution.clone(),
                            ..Default::default()
                        },
                    )
                    .await;
                Ok(Ok(req))
            }
            Err(_) => Ok(Err(TransitionMiss::StaleRevision)),
        }
    }

    /// Internal: publish a help-request event on
    /// `chump.events.help_request.<suffix>`. Best-effort.
    async fn emit_help_request_event(&self, suffix: &str, event: CoordEvent) -> Result<()> {
        let subject = format!(
            "{}.{}.{}",
            EVENTS_SUBJECT, HELP_REQUEST_EVENT_PREFIX, suffix
        );
        let payload: Bytes = serde_json::to_vec(&event)?.into();
        self.js_publish_raw(&subject, payload).await
    }
}

/// KV key for a help request. Mirrors the gap-claim / subtask key
/// convention so all coordination keys are easy to scan in NATS.
fn help_request_key(help_id: &str) -> String {
    format!("help.{}", help_id)
}

/// Translate a [`HelpStatus`] into a [`crate::work_board::SubtaskStatus`]
/// for reuse of the shared [`TransitionMiss`] enum. The shapes are
/// identical so this is purely a type bridge — callers comparing
/// statuses across the two domains should just look at the
/// `TransitionMiss` discriminant (`WrongState`, `NotClaimHolder`, …).
fn map_status_to_subtask(s: HelpStatus) -> crate::work_board::SubtaskStatus {
    use crate::work_board::SubtaskStatus as S;
    match s {
        HelpStatus::Open => S::Open,
        HelpStatus::Claimed => S::Claimed,
        HelpStatus::Completed => S::Completed,
        HelpStatus::Failed => S::Failed,
    }
}
