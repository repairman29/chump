// crates/chump-coord/src/presence.rs — CREDIBLE-246 (CREDIBLE-099 slice)
//
// Worker PRESENCE storage in NATS-KV. CREDIBLE-099 found that fleet workers
// register the CLAIM (gap.<id> in the gaps KV bucket) but never register
// THEMSELVES — there is no record of who/what is doing the work. This module
// is the storage slice: a `WorkerPresence` record per worker session, kept
// in its own `chump_workers` KV bucket (independent lifecycle from gap
// claims — a worker can be alive with no current gap, or dead with a stale
// claim still held).
//
// Two operations, matching CREDIBLE-246's acceptance criteria:
//   1. `register_presence` — on registration, put a fresh record.
//   2. `update_presence_gap` / `refresh_presence` / `mark_terminal` — on any
//      presence change (new gap picked, heartbeat, ship, exit), put an
//      updated record.
//
// Modeled on `capability.rs` (INFRA-1120) which solves the sibling problem
// (what can this worker do) with the same KV-bucket + heartbeat shape.

use anyhow::{Context, Result};
use async_nats::jetstream::kv;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// KV bucket name for worker presence records.
/// Per-test override via `CHUMP_NATS_WORKERS_BUCKET`.
pub const WORKERS_BUCKET: &str = "chump_workers";

/// Presence records auto-purge after this many seconds of inactivity
/// (2x the heartbeat interval below), same ratio as `capability.rs`.
pub const DEFAULT_PRESENCE_TTL_SECONDS: u64 = 300;

/// Heartbeat / refresh interval for presence records.
pub const PRESENCE_HEARTBEAT_INTERVAL_SECS: u64 = 60;

// scanner-anchor: worker_presence_registered worker_presence_updated

/// Lifecycle state of a worker presence record.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PresenceStatus {
    /// Worker is registered and (as far as the record shows) still running.
    Active,
    /// Worker shipped or exited; record kept for audit until TTL purge.
    Terminal,
}

/// A worker's presence record — the "who/what is doing this work" the
/// CREDIBLE-099 gap description says is missing today. Distinct from
/// [`crate::capability::CapabilityManifest`]: capability answers "what CAN
/// this worker pick", presence answers "IS this worker alive, and on what".
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerPresence {
    /// Stable worker/session identifier — same value used as the NATS RPC
    /// session id and gap-claim `session_id`.
    pub worker_id: String,
    /// `claude` | `opencode` | `codex` | `local-llm` | `manual` | ...
    pub backend: String,
    /// Machine identifier (hostname or operator-assigned label).
    pub machine: Option<String>,
    /// Free-form capability tags, sourced the same way as
    /// `WorkerCapability::from_env` (`WORKER_SKILLS`).
    pub skills: Vec<String>,
    /// `claude` | `opencode` | `codex` | `manual` — the harness driving
    /// this worker (distinct from `backend`, which is the model provider).
    pub harness: String,
    /// When this worker first registered.
    pub started_at: DateTime<Utc>,
    /// Gap this worker is currently working, if any.
    pub current_gap: Option<String>,
    /// `Active` while working; `Terminal` once shipped/exited.
    pub status: PresenceStatus,
    /// Last time this record was written (registration, gap change,
    /// heartbeat, or terminal transition).
    pub updated_at: DateTime<Utc>,
}

impl WorkerPresence {
    /// Whether this record should still be considered live given a
    /// reference timestamp and TTL.
    pub fn is_alive(&self, now: DateTime<Utc>, ttl_seconds: i64) -> bool {
        self.status == PresenceStatus::Active
            && now.signed_duration_since(self.updated_at).num_seconds() <= ttl_seconds
    }
}

/// Build a fresh `WorkerPresence` for `worker_id` from environment
/// variables (`WORKER_SKILLS`, `WORKER_MACHINE`, `WORKER_BACKEND`,
/// `CHUMP_AGENT_HARNESS`) — the same env surface `WorkerCapability::from_env`
/// and `current_manifest` read, so a worker publishes one consistent
/// identity across capability, presence, and RPC session id.
pub fn build_presence(worker_id: &str, current_gap: Option<String>) -> WorkerPresence {
    let now = Utc::now();
    let skills = std::env::var("WORKER_SKILLS")
        .ok()
        .map(|s| {
            s.split(',')
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let machine = std::env::var("WORKER_MACHINE")
        .ok()
        .filter(|s| !s.is_empty() && s != "any");
    let backend = std::env::var("WORKER_BACKEND")
        .ok()
        .filter(|s| !s.is_empty() && s != "any")
        .unwrap_or_else(|| "unknown".to_string());
    let harness = std::env::var("CHUMP_AGENT_HARNESS").unwrap_or_else(|_| "manual".to_string());

    WorkerPresence {
        worker_id: worker_id.to_string(),
        backend,
        machine,
        skills,
        harness,
        started_at: now,
        current_gap,
        status: PresenceStatus::Active,
        updated_at: now,
    }
}

/// Initialise (or open) the `chump_workers` KV bucket on the given
/// JetStream context. TTL matches `DEFAULT_PRESENCE_TTL_SECONDS`; NATS
/// auto-purges records that outlive it (dead workers age out).
pub async fn init_workers_bucket(js: &async_nats::jetstream::Context) -> Result<kv::Store> {
    let bucket_name =
        std::env::var("CHUMP_NATS_WORKERS_BUCKET").unwrap_or_else(|_| WORKERS_BUCKET.to_string());
    js.create_key_value(kv::Config {
        bucket: bucket_name,
        max_age: Duration::from_secs(DEFAULT_PRESENCE_TTL_SECONDS),
        history: 4,
        ..Default::default()
    })
    .await
    .map_err(|e| anyhow::anyhow!("workers KV bucket setup failed: {}", e))
}

/// AC-1: register a worker's presence record in the `chump_workers` KV
/// bucket. Overwrites any prior record for the same `worker_id` (a
/// re-register after a crash-restart is expected to reset the record).
pub async fn register_presence(kv: &kv::Store, presence: &WorkerPresence) -> Result<()> {
    put_presence(kv, presence).await
}

/// AC-2: update the current-gap field of an existing presence record and
/// bump `updated_at`. If no prior record exists (e.g. update raced ahead
/// of register), synthesizes one via [`build_presence`] rather than
/// erroring — presence storage should never block worker progress.
pub async fn update_presence_gap(
    kv: &kv::Store,
    worker_id: &str,
    current_gap: Option<String>,
) -> Result<()> {
    let mut presence = get_presence(kv, worker_id)
        .await?
        .unwrap_or_else(|| build_presence(worker_id, None));
    presence.current_gap = current_gap;
    presence.status = PresenceStatus::Active;
    presence.updated_at = Utc::now();
    put_presence(kv, &presence).await
}

/// AC-2: refresh `updated_at` on an existing record (heartbeat) without
/// changing any other field. No-op if the record is already gone.
pub async fn refresh_presence(kv: &kv::Store, worker_id: &str) -> Result<()> {
    if let Some(mut presence) = get_presence(kv, worker_id).await? {
        presence.updated_at = Utc::now();
        put_presence(kv, &presence).await?;
    }
    Ok(())
}

/// AC-2: mark a worker's presence `Terminal` — call on ship or exit. The
/// record is kept (not purged) so operators/peers can see recently-finished
/// work until the KV bucket's TTL ages it out; this mirrors "deregisters or
/// marks terminal" from the CREDIBLE-099 acceptance criteria, choosing the
/// audit-preserving option.
pub async fn mark_terminal(kv: &kv::Store, worker_id: &str) -> Result<()> {
    if let Some(mut presence) = get_presence(kv, worker_id).await? {
        presence.status = PresenceStatus::Terminal;
        presence.updated_at = Utc::now();
        put_presence(kv, &presence).await?;
    }
    Ok(())
}

/// Read a single worker's presence record, or `None` if never registered
/// (or already purged by TTL).
pub async fn get_presence(kv: &kv::Store, worker_id: &str) -> Result<Option<WorkerPresence>> {
    match kv.get(worker_id).await {
        Ok(Some(bytes)) => {
            let presence: WorkerPresence =
                serde_json::from_slice(&bytes).context("deserialize WorkerPresence")?;
            Ok(Some(presence))
        }
        Ok(None) => Ok(None),
        Err(e) => Err(anyhow::anyhow!("workers KV get error: {}", e)),
    }
}

/// List every presence record currently in the bucket, live or terminal.
/// Callers filter by [`WorkerPresence::is_alive`] for a "who's alive" view.
pub async fn list_presence(kv: &kv::Store) -> Result<Vec<WorkerPresence>> {
    let mut keys = kv
        .keys()
        .await
        .map_err(|e| anyhow::anyhow!("workers KV keys error: {}", e))?;

    let mut out = Vec::new();
    while let Some(key_result) = keys.next().await {
        let key = key_result.map_err(|e| anyhow::anyhow!("KV key stream error: {}", e))?;
        if let Ok(Some(bytes)) = kv.get(&key).await {
            if let Ok(presence) = serde_json::from_slice::<WorkerPresence>(&bytes) {
                out.push(presence);
            }
        }
    }
    Ok(out)
}

async fn put_presence(kv: &kv::Store, presence: &WorkerPresence) -> Result<()> {
    let payload: Bytes = serde_json::to_vec(presence)
        .context("serialize WorkerPresence")?
        .into();
    kv.put(&presence.worker_id, payload)
        .await
        .map_err(|e| anyhow::anyhow!("workers KV put failed: {}", e))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(worker_id: &str) -> WorkerPresence {
        let now = Utc::now();
        WorkerPresence {
            worker_id: worker_id.to_string(),
            backend: "claude".to_string(),
            machine: Some("test-host".to_string()),
            skills: vec!["rust".to_string()],
            harness: "claude".to_string(),
            started_at: now,
            current_gap: Some("CREDIBLE-246".to_string()),
            status: PresenceStatus::Active,
            updated_at: now,
        }
    }

    #[test]
    fn json_round_trip() {
        let p = fixture("worker-1");
        let json = serde_json::to_string(&p).expect("serialize");
        let back: WorkerPresence = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(p, back);
    }

    #[test]
    fn is_alive_within_ttl_when_active() {
        let p = fixture("worker-1");
        assert!(p.is_alive(p.updated_at, DEFAULT_PRESENCE_TTL_SECONDS as i64));
    }

    #[test]
    fn is_not_alive_when_terminal() {
        let mut p = fixture("worker-1");
        p.status = PresenceStatus::Terminal;
        assert!(!p.is_alive(p.updated_at, DEFAULT_PRESENCE_TTL_SECONDS as i64));
    }

    #[test]
    fn is_not_alive_past_ttl() {
        let p = fixture("worker-1");
        let later =
            p.updated_at + chrono::Duration::seconds(DEFAULT_PRESENCE_TTL_SECONDS as i64 + 1);
        assert!(!p.is_alive(later, DEFAULT_PRESENCE_TTL_SECONDS as i64));
    }

    #[test]
    #[serial_test::serial(presence_env)]
    fn build_presence_reads_env() {
        std::env::set_var("WORKER_SKILLS", "rust,shell");
        std::env::set_var("WORKER_MACHINE", "macbook");
        std::env::set_var("WORKER_BACKEND", "claude");
        std::env::set_var("CHUMP_AGENT_HARNESS", "claude");

        let p = build_presence("worker-9", Some("INFRA-1".to_string()));

        assert_eq!(p.worker_id, "worker-9");
        assert_eq!(p.skills, vec!["rust".to_string(), "shell".to_string()]);
        assert_eq!(p.machine.as_deref(), Some("macbook"));
        assert_eq!(p.backend, "claude");
        assert_eq!(p.harness, "claude");
        assert_eq!(p.current_gap.as_deref(), Some("INFRA-1"));
        assert_eq!(p.status, PresenceStatus::Active);

        std::env::remove_var("WORKER_SKILLS");
        std::env::remove_var("WORKER_MACHINE");
        std::env::remove_var("WORKER_BACKEND");
        std::env::remove_var("CHUMP_AGENT_HARNESS");
    }

    #[test]
    #[serial_test::serial(presence_env)]
    fn build_presence_defaults_when_env_absent() {
        std::env::remove_var("WORKER_SKILLS");
        std::env::remove_var("WORKER_MACHINE");
        std::env::remove_var("WORKER_BACKEND");
        std::env::remove_var("CHUMP_AGENT_HARNESS");

        let p = build_presence("worker-solo", None);

        assert!(p.skills.is_empty());
        assert_eq!(p.machine, None);
        assert_eq!(p.backend, "unknown");
        assert_eq!(p.harness, "manual");
        assert_eq!(p.current_gap, None);
    }
}
