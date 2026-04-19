//! # chump-coord
//!
//! NATS-backed atomic coordination layer for multi-agent Chump sessions.
//!
//! ## Design (Phase 1 — additive)
//!
//! Phase 1 runs **alongside** the existing file-based lease system
//! (`.chump-locks/*.json` + `ambient.jsonl`). File leases remain
//! authoritative; this crate provides an **atomic claim layer** on top:
//!
//! - **NATS KV `chump.gaps`** — one key per gap (`gap.<gap-id>`), written
//!   with [`kv::Store::create`] which fails atomically if the key exists.
//!   Eliminates the 3-second sleep race that caused 5× duplicate implementations.
//!
//! - **NATS JetStream `CHUMP_EVENTS`** — persistent, replayable event stream
//!   on subjects `chump.events.*`. Augments `ambient.jsonl` with real-time
//!   fanout and 24-hour replay.
//!
//! Both are **optional**: every public function degrades gracefully when the
//! NATS server is unreachable. The caller always falls back to the file system.
//!
//! ## Quick start
//!
//! ```no_run
//! use chump_coord::CoordClient;
//!
//! # #[tokio::main]
//! # async fn main() -> anyhow::Result<()> {
//! let client = CoordClient::connect_or_skip().await;
//!
//! if let Some(c) = client {
//!     match c.try_claim_gap("COG-016", "my-session-id").await? {
//!         true  => println!("Claimed COG-016"),
//!         false => println!("Already claimed — pick a different gap"),
//!     }
//! }
//! # Ok(())
//! # }
//! ```
//!
//! ## Environment variables
//!
//! | Variable | Default | Purpose |
//! |---|---|---|
//! | `CHUMP_NATS_URL` | `nats://127.0.0.1:4222` | NATS server address |
//! | `CHUMP_NATS_TIMEOUT_MS` | `500` | Connection + op timeout in ms |
//! | `CHUMP_GAP_CLAIM_TTL_SECS` | `14400` (4h) | KV entry TTL |

use anyhow::{anyhow, Result};
use async_nats::jetstream::{self, kv};
use bytes::Bytes;
use chrono::Utc;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// Default NATS server URL — localhost embedded instance.
pub const DEFAULT_NATS_URL: &str = "nats://127.0.0.1:4222";

/// KV bucket name for atomic gap claims.
pub const GAP_BUCKET: &str = "chump.gaps";

/// JetStream stream name for coordination events.
pub const EVENTS_STREAM: &str = "CHUMP_EVENTS";

/// JetStream subject prefix for all events.
pub const EVENTS_SUBJECT: &str = "chump.events";

/// Default TTL for gap claim entries (4 hours, matches file lease default).
pub const DEFAULT_GAP_TTL_SECS: u64 = 14_400;

// ── Claim record ─────────────────────────────────────────────────────────────

/// Stored in NATS KV `chump.gaps.gap.<gap-id>` when a session claims a gap.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GapClaim {
    /// Session ID of the claiming agent.
    pub session_id: String,
    /// RFC3339 timestamp of when the claim was created.
    pub claimed_at: String,
    /// Optional: files the claiming session intends to touch.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<String>,
}

// ── Event record ─────────────────────────────────────────────────────────────

/// All structured events published to `chump.events.*`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CoordEvent {
    /// Event type: INTENT | DONE | STUCK | HANDOFF | WARN | ALERT | session_start | commit
    pub event: String,
    /// Sending session ID.
    pub session: String,
    /// RFC3339 UTC timestamp.
    pub ts: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gap: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

// ── CoordClient ───────────────────────────────────────────────────────────────

/// Connected coordination client.
pub struct CoordClient {
    /// Raw NATS client — exposed so callers can subscribe directly.
    pub nats: async_nats::Client,
    js: jetstream::Context,
    gaps_kv: kv::Store,
}

impl CoordClient {
    /// Connect to NATS and initialise the KV bucket + JetStream stream.
    pub async fn connect() -> Result<Self> {
        let url = std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| DEFAULT_NATS_URL.to_string());
        let timeout_ms: u64 = std::env::var("CHUMP_NATS_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(500);
        let ttl_secs: u64 = std::env::var("CHUMP_GAP_CLAIM_TTL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_GAP_TTL_SECS);

        let nats =
            tokio::time::timeout(Duration::from_millis(timeout_ms), async_nats::connect(&url))
                .await
                .map_err(|_| anyhow!("NATS connect timed out after {}ms ({})", timeout_ms, url))?
                .map_err(|e| anyhow!("NATS connect failed: {}", e))?;

        let js = jetstream::new(nats.clone());

        // KV bucket for gap claims — max_age = TTL.
        let gaps_kv = js
            .create_key_value(kv::Config {
                bucket: GAP_BUCKET.to_string(),
                max_age: Duration::from_secs(ttl_secs),
                history: 5,
                ..Default::default()
            })
            .await
            .map_err(|e| anyhow!("KV bucket setup failed: {}", e))?;

        // JetStream stream for coordination events.
        js.get_or_create_stream(jetstream::stream::Config {
            name: EVENTS_STREAM.to_string(),
            subjects: vec![format!("{}.>", EVENTS_SUBJECT)],
            max_age: Duration::from_secs(86_400), // 24h
            ..Default::default()
        })
        .await
        .map_err(|e| anyhow!("JetStream stream setup failed: {}", e))?;

        Ok(Self { nats, js, gaps_kv })
    }

    /// Like [`connect`] but returns `None` instead of an error when NATS is
    /// unreachable. Shell scripts use this to fall back to file-based leases.
    pub async fn connect_or_skip() -> Option<Self> {
        match Self::connect().await {
            Ok(c) => Some(c),
            Err(e) => {
                eprintln!(
                    "[chump-coord] NATS unavailable ({}) — using file-based coordination",
                    e
                );
                None
            }
        }
    }

    /// Returns `true` if the NATS server responded within 200ms.
    pub async fn ping(&self) -> bool {
        tokio::time::timeout(Duration::from_millis(200), self.nats.flush())
            .await
            .map(|r| r.is_ok())
            .unwrap_or(false)
    }

    // ── Atomic gap claims ─────────────────────────────────────────────────────

    /// Attempt to atomically claim `gap_id` for `session_id`.
    ///
    /// Returns `Ok(true)` if the claim was acquired, `Ok(false)` if another
    /// session already holds it. The [`kv::Store::create`] call is the
    /// atomic mutex — it fails with `AlreadyExists` if the key exists.
    pub async fn try_claim_gap(&self, gap_id: &str, session_id: &str) -> Result<bool> {
        self.try_claim_gap_with_files(gap_id, session_id, &[]).await
    }

    /// Like [`try_claim_gap`] but records intended file touches.
    pub async fn try_claim_gap_with_files(
        &self,
        gap_id: &str,
        session_id: &str,
        files: &[&str],
    ) -> Result<bool> {
        let key = format!("gap.{}", gap_id);
        let claim = GapClaim {
            session_id: session_id.to_string(),
            claimed_at: Utc::now().to_rfc3339(),
            files: files.iter().map(|s| s.to_string()).collect(),
        };
        let value: Bytes = serde_json::to_vec(&claim)?.into();

        match self.gaps_kv.create(&key, value).await {
            Ok(_) => Ok(true),
            Err(e) => {
                // AlreadyExists = another session won the race
                if e.kind() == kv::CreateErrorKind::AlreadyExists {
                    Ok(false)
                } else {
                    Err(anyhow!("KV create error: {}", e))
                }
            }
        }
    }

    /// Release a gap claim. No-op if the key doesn't exist or is already gone.
    pub async fn release_gap(&self, gap_id: &str) -> Result<()> {
        let key = format!("gap.{}", gap_id);
        self.gaps_kv
            .purge(&key)
            .await
            .map_err(|e| anyhow!("KV purge error: {}", e))?;
        Ok(())
    }

    /// Read the current claim holder for a gap, or `None` if unclaimed.
    pub async fn gap_claim(&self, gap_id: &str) -> Result<Option<GapClaim>> {
        let key = format!("gap.{}", gap_id);
        match self.gaps_kv.get(&key).await {
            Ok(Some(bytes)) => {
                let claim: GapClaim = serde_json::from_slice(&bytes)?;
                Ok(Some(claim))
            }
            Ok(None) => Ok(None),
            Err(e) => Err(anyhow!("KV get error: {}", e)),
        }
    }

    /// List all currently active gap claims.
    pub async fn list_gap_claims(&self) -> Result<Vec<(String, GapClaim)>> {
        let mut keys = self
            .gaps_kv
            .keys()
            .await
            .map_err(|e| anyhow!("KV keys error: {}", e))?;

        let mut out = Vec::new();
        while let Some(key_result) = keys.next().await {
            let key = key_result.map_err(|e| anyhow!("KV key stream error: {}", e))?;
            if let Ok(Some(bytes)) = self.gaps_kv.get(&key).await {
                if let Ok(claim) = serde_json::from_slice::<GapClaim>(&bytes) {
                    let gap_id = key.trim_start_matches("gap.").to_string();
                    out.push((gap_id, claim));
                }
            }
        }
        Ok(out)
    }

    // ── Event publishing ──────────────────────────────────────────────────────

    /// Publish a structured event to `chump.events.<event_type>`.
    pub async fn emit(&self, event: CoordEvent) -> Result<()> {
        let subject = format!("{}.{}", EVENTS_SUBJECT, event.event.to_lowercase());
        let payload: Bytes = serde_json::to_vec(&event)?.into();
        self.js
            .publish(subject, payload)
            .await
            .map_err(|e| anyhow!("JetStream publish error: {}", e))?
            .await
            .map_err(|e| anyhow!("JetStream ack error: {}", e))?;
        Ok(())
    }

    /// Convenience: emit an INTENT event for a gap.
    pub async fn emit_intent(&self, session_id: &str, gap_id: &str, files: &str) -> Result<()> {
        self.emit(CoordEvent {
            event: "INTENT".to_string(),
            session: session_id.to_string(),
            ts: Utc::now().to_rfc3339(),
            gap: Some(gap_id.to_string()),
            files: Some(files.to_string()),
            ..Default::default()
        })
        .await
    }

    /// Convenience: emit a DONE event when a gap ships.
    pub async fn emit_done(&self, session_id: &str, gap_id: &str, commit: &str) -> Result<()> {
        self.emit(CoordEvent {
            event: "DONE".to_string(),
            session: session_id.to_string(),
            ts: Utc::now().to_rfc3339(),
            gap: Some(gap_id.to_string()),
            commit: Some(commit.to_string()),
            ..Default::default()
        })
        .await
    }

    /// Flush pending pub acks.
    pub async fn flush(&self) -> Result<()> {
        self.nats
            .flush()
            .await
            .map_err(|e| anyhow!("NATS flush error: {}", e))
    }
}
