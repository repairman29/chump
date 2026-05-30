// crates/chump-coord/src/nats_primary.rs — INFRA-2266
//
// A2A Layer 1a slice 3/4 — NATS-primary JetStream durable consumer.
//
// This module is the public face of the NATS-primary subscribe path.
// The full implementation lives in `events.rs`; this module re-exports
// the stable public surface and documents the durable-consumer contract
// so callers can depend on `nats_primary` without importing `events` directly.
//
// ## Contract (Layer 1a)
//
// - `subscribe_events(filter)` with `CHUMP_A2A_LAYER=1`:
//   Creates a JetStream durable push consumer named `chump_<session_id>`.
//   Consumer config: DeliverPolicy::New, AckPolicy::Explicit,
//   max_ack_pending = CHUMP_A2A_MAX_ACK_PENDING (default 512).
//
// - On broker drop: switches to ambient.jsonl file-poll within 5s,
//   emits `kind=fleet_a2a_degraded` to ambient.jsonl.
//
// - On reconnect: reads JetStream consumer info to get last delivered
//   sequence, resumes from that offset, emits `kind=fleet_a2a_recovered`.
//
// - Backpressure: when pending_count >= max_ack_pending, emits
//   `kind=fleet_a2a_backpressure`. Hysteresis resets when
//   pending_count drops below max_ack_pending / 2.
//
// - `CHUMP_A2A_LAYER=0` (default): file-only path; zero NATS dependency.
//   This module's re-exports are still present but the runtime path
//   never touches async-nats.

pub use crate::events::{
    subscribe_events, subscribe_events_with_session, CoordEvent, EventFilter, EventStream,
    SubscribeError,
};

/// Per-session durable consumer name for the JetStream push consumer.
///
/// NATS consumer names allow alphanumeric, dash, underscore. All other
/// characters in `session_id` are replaced with `_`.
///
/// Cardinality is bounded by active fleet size (O(tens)). Dead durables
/// expire automatically with the stream's `max_age` (24h).
pub fn durable_consumer_name(session_id: &str) -> String {
    format!(
        "chump_{}",
        session_id
            .chars()
            .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            })
            .collect::<String>()
    )
}

/// Maximum pending ack count before `fleet_a2a_backpressure` is emitted.
/// Configurable via `CHUMP_A2A_MAX_ACK_PENDING`.
pub fn max_ack_pending() -> i64 {
    std::env::var("CHUMP_A2A_MAX_ACK_PENDING")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(512)
}

/// Whether the NATS-primary path is active (`CHUMP_A2A_LAYER >= 1`).
pub fn layer_enabled() -> bool {
    std::env::var("CHUMP_A2A_LAYER")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(0)
        >= 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durable_name_sanitises_special_chars() {
        assert_eq!(
            durable_consumer_name("claim-infra-2266-49096-1780121432"),
            "chump_claim-infra-2266-49096-1780121432"
        );
        assert_eq!(
            durable_consumer_name("session/with:dots.and spaces"),
            "chump_session_with_dots_and_spaces"
        );
    }

    #[test]
    fn durable_name_allows_dash_underscore() {
        let name = durable_consumer_name("my-session_id");
        assert_eq!(name, "chump_my-session_id");
    }

    #[test]
    fn max_ack_pending_default() {
        std::env::remove_var("CHUMP_A2A_MAX_ACK_PENDING");
        assert_eq!(max_ack_pending(), 512);
    }

    #[test]
    fn max_ack_pending_from_env() {
        std::env::set_var("CHUMP_A2A_MAX_ACK_PENDING", "64");
        assert_eq!(max_ack_pending(), 64);
        std::env::remove_var("CHUMP_A2A_MAX_ACK_PENDING");
    }

    #[test]
    fn layer_enabled_default_off() {
        std::env::remove_var("CHUMP_A2A_LAYER");
        assert!(!layer_enabled());
    }

    #[test]
    fn layer_enabled_when_set_to_1() {
        std::env::set_var("CHUMP_A2A_LAYER", "1");
        assert!(layer_enabled());
        std::env::remove_var("CHUMP_A2A_LAYER");
    }
}
