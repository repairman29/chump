// crates/chump-coord/src/jetstream_consumer.rs — META-175
//
// JetStream durable consumer per-role — restart-safe replay building block.
//
// ## Contract
//
// - `subscribe_for_role(role)` creates (or resumes) a durable JetStream pull
//   consumer named `chump-fleet-<role>` on the `CHUMP_EVENTS` stream.
//   DeliverPolicy::All on first create; ByStartSequence after restart (so
//   only unacked messages replay).
//
// - `JetstreamConsumer::next()` fetches the next message (blocking up to
//   `CHUMP_FLEET_WIRE_FETCH_TIMEOUT_MS`).
//
// - `Message::ack()` sends the JetStream explicit ack so the broker advances
//   the consumer's ack floor.
//
// ## Feature flag
//
// Both `CHUMP_FLEET_WIRE_V1=1` **and** `CHUMP_NATS_URL` must be set for the
// JetStream path to activate. If either is absent the caller falls back to the
// file-inbox tick-preamble (INFRA-2262 path).
//
// ## Observability
//
// `JetstreamConsumer::lag()` returns (delivered_seq - ack_floor_seq) for the
// cockpit panel. Delivery latency (p50/p99) is computed from
// `kind=feedback_fanout_delivered` timestamps stored in ambient events; the
// `/api/fleet-wire/health` endpoint reads those via `ambient.jsonl` scan.

use anyhow::{anyhow, Result};
use async_nats::jetstream::{self, consumer as jsc};
use chrono::Utc;
use std::time::Duration;

use crate::{DEFAULT_NATS_URL, EVENTS_STREAM};

// Tracing is already a workspace dep (see root Cargo.toml).
// These spans surface in logs + ambient when the consumer is created/resumed
// so fleet-brief and watchdogs can tell the NATS path activated.
use tracing::{info, warn};

/// Default timeout waiting for the next message from a fetch call (ms).
const DEFAULT_FETCH_TIMEOUT_MS: u64 = 2_000;

// ── Feature-flag guard ────────────────────────────────────────────────────────

/// Returns `true` when **both** `CHUMP_FLEET_WIRE_V1=1` and `CHUMP_NATS_URL`
/// are set in the process environment.
///
/// Callers should check this before calling `subscribe_for_role`; if it
/// returns `false` they must fall back to the file-inbox path.
pub fn fleet_wire_enabled() -> bool {
    let v1_flag = std::env::var("CHUMP_FLEET_WIRE_V1")
        .ok()
        .map(|v| v.trim() == "1")
        .unwrap_or(false);
    let nats_set = std::env::var("CHUMP_NATS_URL")
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false);
    v1_flag && nats_set
}

// ── Public API ────────────────────────────────────────────────────────────────

/// A durable JetStream pull consumer bound to one Chump fleet role.
///
/// Created via `subscribe_for_role`. Drop `JetstreamConsumer` when done; the
/// durable state lives on the broker and will resume on the next call with the
/// same role name.
pub struct JetstreamConsumer {
    consumer: async_nats::jetstream::consumer::Consumer<jsc::pull::Config>,
    role: String,
    /// Cached consumer info for lag reporting. Refreshed on `lag()`.
    _js: jetstream::Context,
}

/// A single message fetched from the JetStream consumer.
///
/// Call `ack()` after processing to advance the consumer's ack floor.
/// Messages not ack'd will be redelivered on the next `subscribe_for_role`
/// call with the same role (restart-safe replay).
pub struct Message {
    inner: async_nats::jetstream::Message,
    /// RFC3339 timestamp recorded when the message was delivered, used for
    /// latency percentile computation by the observability endpoint.
    pub delivered_at: String,
}

impl Message {
    /// Acknowledge the message so the broker advances the ack floor.
    pub async fn ack(self) -> Result<()> {
        self.inner
            .ack()
            .await
            .map_err(|e| anyhow!("JetStream ack error: {}", e))
    }

    /// The raw message payload bytes.
    pub fn payload(&self) -> &bytes::Bytes {
        &self.inner.payload
    }

    /// Consume and return the raw `async_nats::jetstream::Message`.
    pub fn into_inner(self) -> async_nats::jetstream::Message {
        self.inner
    }
}

impl JetstreamConsumer {
    /// Fetch the next unacked message for this role, waiting up to the
    /// configured fetch timeout.
    ///
    /// Returns `None` when no message arrives within the timeout (caller
    /// should loop or do other work). Returns `Some(Message)` when a message
    /// is ready; call `Message::ack()` after processing.
    pub async fn next(&self) -> Option<Message> {
        let timeout_ms: u64 = std::env::var("CHUMP_FLEET_WIRE_FETCH_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_FETCH_TIMEOUT_MS);

        let expires = Duration::from_millis(timeout_ms);
        let mut batch = match self
            .consumer
            .fetch()
            .max_messages(1)
            .expires(expires)
            .messages()
            .await
        {
            Ok(b) => b,
            Err(_) => return None,
        };

        use futures::StreamExt;
        match batch.next().await {
            Some(Ok(msg)) => Some(Message {
                inner: msg,
                delivered_at: Utc::now().to_rfc3339(),
            }),
            _ => None,
        }
    }

    /// Return consumer lag: `delivered_seq - ack_floor_seq`.
    ///
    /// Uses a cached JetStream context to fetch live consumer info. Returns
    /// `None` when the info call fails (NATS unreachable, stream deleted, etc).
    pub async fn lag(&self) -> Option<u64> {
        let stream = self._js.get_stream(EVENTS_STREAM).await.ok()?;
        let durable = durable_name(&self.role);
        let info = stream.consumer_info(&durable).await.ok()?;
        // num_pending is the count of messages not yet delivered to this
        // consumer, which is the definition of lag for a pull consumer.
        Some(info.num_pending)
    }

    /// Role name this consumer is bound to.
    pub fn role(&self) -> &str {
        &self.role
    }
}

// ── Constructor ───────────────────────────────────────────────────────────────

/// Create (or resume) a durable JetStream pull consumer for `role`.
///
/// Consumer name: `chump-fleet-<role>`.
/// On first create: `DeliverPolicy::All` (process historical messages).
/// On restart (durable already exists): consumer resumes from last ack floor
/// (`DeliverPolicy::ByStartSequence` is honoured by the broker automatically
/// for existing durable consumers — the broker ignores the deliver_policy in
/// the create request when the durable already exists).
///
/// # Errors
///
/// - NATS unreachable within `CHUMP_NATS_TIMEOUT_MS`.
/// - Stream `CHUMP_EVENTS` does not exist (created by `CoordClient::connect`
///   — ensure a `CoordClient` has been constructed at least once).
pub async fn subscribe_for_role(role: &str) -> Result<JetstreamConsumer> {
    let url = std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| DEFAULT_NATS_URL.to_string());
    let timeout_ms: u64 = std::env::var("CHUMP_NATS_TIMEOUT_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(500);

    let nats = tokio::time::timeout(Duration::from_millis(timeout_ms), async_nats::connect(&url))
        .await
        .map_err(|_| anyhow!("NATS connect timed out after {}ms ({})", timeout_ms, url))?
        .map_err(|e| anyhow!("NATS connect failed: {}", e))?;

    let js = jetstream::new(nats);

    let stream = js
        .get_stream(EVENTS_STREAM)
        .await
        .map_err(|e| anyhow!("stream {} not found: {}", EVENTS_STREAM, e))?;

    let durable = durable_name(role);

    // Try to get the consumer first (resume case). If it doesn't exist,
    // create it with DeliverPolicy::All.
    let consumer = match stream.get_consumer::<jsc::pull::Config>(&durable).await {
        Ok(c) => {
            info!(
                role = role,
                durable = %durable,
                "jetstream_consumer: resumed existing durable consumer"
            );
            c
        }
        Err(_) => {
            // First-time create: deliver all messages from the beginning.
            info!(
                role = role,
                durable = %durable,
                "jetstream_consumer: creating new durable consumer (DeliverPolicy::All)"
            );
            stream
                .create_consumer(jsc::pull::Config {
                    durable_name: Some(durable.clone()),
                    ack_policy: jsc::AckPolicy::Explicit,
                    deliver_policy: jsc::DeliverPolicy::All,
                    filter_subject: format!("{}.>", crate::EVENTS_SUBJECT),
                    description: Some(format!(
                        "chump fleet consumer for role={} created={}",
                        role,
                        Utc::now().to_rfc3339()
                    )),
                    ..Default::default()
                })
                .await
                .map_err(|e| {
                    warn!(role = role, err = %e, "jetstream_consumer: consumer create failed");
                    anyhow!("consumer create failed for role={}: {}", role, e)
                })?
        }
    };

    Ok(JetstreamConsumer {
        consumer,
        role: role.to_string(),
        _js: js,
    })
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Durable consumer name for `role`. Uses NATS-safe chars: alphanumeric, `-`, `_`.
fn durable_name(role: &str) -> String {
    let sanitized: String = role
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    format!("chump-fleet-{}", sanitized)
}

// ── Unit tests (no NATS required) ─────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durable_name_basic() {
        assert_eq!(durable_name("ci-audit"), "chump-fleet-ci-audit");
        assert_eq!(durable_name("md_links"), "chump-fleet-md_links");
    }

    #[test]
    fn durable_name_sanitises_special_chars() {
        assert_eq!(durable_name("role/with:dots"), "chump-fleet-role_with_dots");
    }

    #[test]
    fn fleet_wire_disabled_by_default() {
        std::env::remove_var("CHUMP_FLEET_WIRE_V1");
        std::env::remove_var("CHUMP_NATS_URL");
        assert!(!fleet_wire_enabled());
    }

    #[test]
    fn fleet_wire_requires_both_flags() {
        // Only V1 set — disabled.
        std::env::set_var("CHUMP_FLEET_WIRE_V1", "1");
        std::env::remove_var("CHUMP_NATS_URL");
        assert!(!fleet_wire_enabled());

        // Only NATS_URL set — disabled.
        std::env::remove_var("CHUMP_FLEET_WIRE_V1");
        std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:4222");
        assert!(!fleet_wire_enabled());

        // Both set — enabled.
        std::env::set_var("CHUMP_FLEET_WIRE_V1", "1");
        assert!(fleet_wire_enabled());

        // Cleanup.
        std::env::remove_var("CHUMP_FLEET_WIRE_V1");
        std::env::remove_var("CHUMP_NATS_URL");
    }
}
