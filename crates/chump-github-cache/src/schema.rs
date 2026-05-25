//! Typed structs for the cached subset of GitHub JSON.
//!
//! Phase 1 design notes:
//! - All fields YOU rely on are strictly-typed (`number: u64`, etc).
//! - Unknown JSON fields are silently dropped (default `serde` behavior
//!   — we do NOT use `deny_unknown_fields`) so GitHub adding a new field
//!   to a webhook payload does not panic the receiver.
//! - The DB-row representation (read out of SQLite columns) is separated
//!   from the wire representation (parsed out of `raw_payload_json`)
//!   only where they meaningfully differ. For Phase 1 they overlap a
//!   lot, so we use a single shape per concept.

use serde::{Deserialize, Serialize};

/// One row in the `pr_state` SQLite table.
///
/// Mirrors the column set produced by both the legacy Python receiver
/// (`scripts/ops/github-webhook-receiver.py::_upsert_pr`) and the
/// shell fallback (`scripts/coord/lib/github_cache.sh::_cache_fetch_and_store`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PrState {
    /// PR number (primary key).
    pub number: u64,
    /// Head branch name (e.g. `chump/infra-1999-claim`).
    pub head_ref: Option<String>,
    /// Head SHA (40-char hex).
    pub head_sha: Option<String>,
    /// Base branch name (e.g. `main`).
    pub base_ref: Option<String>,
    /// Base SHA.
    pub base_sha: Option<String>,
    /// `mergeable_state` from the GitHub PR object (clean / behind / dirty / unstable / etc).
    pub mergeable_state: Option<String>,
    /// 1 iff `auto_merge` is enabled on the PR.
    pub auto_merge_enabled: bool,
    /// 1 iff PR is a draft.
    pub draft: bool,
    /// ISO-8601 merge timestamp, or `None` if not merged.
    pub merged_at: Option<String>,
    /// PR title.
    pub title: Option<String>,
    /// Login of the PR opener.
    pub user_login: Option<String>,
    /// `updated_at` from the GitHub API.
    pub updated_at_api: String,
    /// Our local capture timestamp.
    pub fetched_at_local: String,
    /// The raw GitHub JSON payload as captured (string).
    pub raw_payload_json: Option<String>,
    /// `merge_state_status` separately stored (INFRA-1368) — duplicates
    /// `mergeable_state` for webhook-sourced rows but the column exists.
    pub merge_state_status: Option<String>,
}

/// Light projection for list endpoints — `(number, title, head_ref)`.
///
/// Returned by [`crate::GithubCache::query_open_prs`] and
/// [`crate::GithubCache::query_open_prs_by_title`]; matches the
/// tab-separated output of `cache_query_open_prs` in the bash helper.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PrSummary {
    /// PR number.
    pub number: u64,
    /// PR title (empty string if NULL in DB).
    pub title: String,
    /// Head ref (empty string if NULL in DB).
    pub head_ref: String,
}

/// One row in the `check_runs` SQLite table.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CheckRun {
    /// Head SHA the check ran against.
    pub head_sha: String,
    /// Check-run name (e.g. `rust-quality`).
    pub name: String,
    /// `status` field from the GitHub check-run API (queued / in_progress / completed).
    pub status: Option<String>,
    /// `conclusion` (success / failure / cancelled / etc) — present once status=completed.
    pub conclusion: Option<String>,
    /// ISO-8601 start time.
    pub started_at: Option<String>,
    /// ISO-8601 completion time.
    pub completed_at: Option<String>,
    /// Our local capture timestamp.
    pub fetched_at_local: String,
}

/// GitHub `pull_request` webhook payload (just the fields we touch).
///
/// The receiver deserializes the incoming webhook body into this; any
/// unknown JSON keys are silently dropped so GitHub schema additions do
/// not panic.
#[derive(Debug, Clone, Deserialize)]
pub struct PullRequestWebhookPayload {
    /// One of `opened`, `synchronize`, `closed`, `reopened`, etc.
    pub action: String,
    /// The PR object.
    pub pull_request: PrPayloadPr,
}

/// The `pull_request` sub-object of a GitHub `pull_request` webhook.
#[derive(Debug, Clone, Deserialize)]
pub struct PrPayloadPr {
    /// PR number.
    pub number: u64,
    /// Head ref-object.
    pub head: Option<PrPayloadRef>,
    /// Base ref-object.
    pub base: Option<PrPayloadRef>,
    /// Set when PR is merged.
    pub merged_at: Option<String>,
    /// Title.
    pub title: Option<String>,
    /// `mergeable_state` (clean/behind/dirty/unstable/draft/blocked).
    pub mergeable_state: Option<String>,
    /// Author.
    pub user: Option<PrPayloadUser>,
    /// `true` iff auto_merge is configured on the PR.
    #[serde(default)]
    pub auto_merge: Option<serde_json::Value>,
    /// `true` iff PR is in draft state.
    #[serde(default)]
    pub draft: bool,
    /// ISO-8601 timestamp of last update from GitHub.
    pub updated_at: Option<String>,
}

/// `head` or `base` sub-object of a PR payload — just `ref` and `sha`.
#[derive(Debug, Clone, Deserialize)]
pub struct PrPayloadRef {
    /// Branch name.
    #[serde(rename = "ref")]
    pub ref_: Option<String>,
    /// Commit SHA.
    pub sha: Option<String>,
}

/// `user` sub-object of a PR payload — just `login`.
#[derive(Debug, Clone, Deserialize)]
pub struct PrPayloadUser {
    /// GitHub login string.
    pub login: Option<String>,
}

/// GitHub `check_run` webhook payload.
///
/// Phase 1: we extract the head_sha + check_run object, UPSERT into
/// `check_runs`. Unknown fields silently dropped.
#[derive(Debug, Clone, Deserialize)]
pub struct CheckRunWebhookPayload {
    /// One of `created`, `completed`, `rerequested`, `requested_action`.
    pub action: String,
    /// The check-run object.
    pub check_run: CheckRunPayload,
}

/// The `check_run` sub-object — fields we persist.
#[derive(Debug, Clone, Deserialize)]
pub struct CheckRunPayload {
    /// Check-run name.
    pub name: String,
    /// Head SHA the check ran against.
    pub head_sha: String,
    /// `queued | in_progress | completed`.
    pub status: Option<String>,
    /// `success | failure | cancelled | ...` (present at status=completed).
    pub conclusion: Option<String>,
    /// ISO-8601 start.
    pub started_at: Option<String>,
    /// ISO-8601 completion.
    pub completed_at: Option<String>,
}

/// GitHub `workflow_run` webhook payload.
///
/// Phase 1: the legacy Python receiver treats `workflow_run.completed`
/// like a coarse-grained check signal — we mirror that by recording one
/// check_runs row keyed `head_sha, name=workflow_run`. Unknown fields
/// silently dropped.
#[derive(Debug, Clone, Deserialize)]
pub struct WorkflowRunWebhookPayload {
    /// `requested | in_progress | completed`.
    pub action: String,
    /// The workflow-run object.
    pub workflow_run: WorkflowRunPayload,
}

/// The `workflow_run` sub-object — fields we persist.
#[derive(Debug, Clone, Deserialize)]
pub struct WorkflowRunPayload {
    /// Workflow display name (e.g. `CI`, `Rust quality`).
    pub name: String,
    /// Head SHA the workflow ran on.
    pub head_sha: String,
    /// `queued | in_progress | completed`.
    pub status: Option<String>,
    /// `success | failure | cancelled | ...`.
    pub conclusion: Option<String>,
    /// ISO-8601 timestamps.
    pub run_started_at: Option<String>,
    /// `updated_at` doubles as completion time once status=completed.
    pub updated_at: Option<String>,
}
