//! RESILIENT-334 — workers SUBSCRIBE + ACT on NATS as the primary
//! coordination path.
//!
//! `nats_primary::subscribe_events` (INFRA-2266 / INFRA-1118) already lets a
//! session listen to `chump.events.>`, but until this module nothing on the
//! fleet actually *acted* on what it received — `chump-coord watch` only
//! prints, and the worker loop (`worker::loop_body`) discovers work purely by
//! polling `state.db` / `list_subtasks` on a timer. That's the "telemetry
//! firehose, not coordination" gap: publish worked, subscribe existed, but
//! the loop from bus event to a real state transition (a claim) was never
//! closed.
//!
//! This module is the first ACTOR on the subscribe stream: it reacts to
//! `WORK_POSTED` events (published by [`crate::work_board::CoordClient::post_subtask`])
//! by attempting an atomic claim the moment the event arrives — no polling,
//! no `list_subtasks` scan. The gap queue / KV store remains the durable
//! backlog (source of truth for who actually won the claim, via CAS), but
//! the *live* channel that tells a worker "there is new work" is now the bus.

use crate::events::CoordEvent as StreamEvent;
use crate::work_board::{Subtask, SubtaskStatus};
use crate::CoordClient;
use anyhow::Result;

/// Outcome of reacting to a single bus event.
#[derive(Debug, Clone)]
pub enum ReactOutcome {
    /// Not a `WORK_POSTED` event (or malformed) — nothing to do.
    Ignored,
    /// A `WORK_POSTED` event arrived but `should_claim` rejected it
    /// (capability mismatch), or the subtask was already gone/claimed by
    /// the time we looked.
    Skipped,
    /// We attempted the atomic claim and lost the race to another session
    /// reacting to the same event on the bus.
    LostRace,
    /// We won the atomic claim, driven entirely by the subscribed event.
    Claimed(Box<Subtask>),
}

/// React to one event pulled off a [`crate::events::EventStream`].
///
/// This is the "act" half of subscribe+act: given an event already
/// delivered by the bus, extract the posted subtask id from its payload,
/// fetch the subtask, run the caller's capability filter, and — if it
/// matches — attempt the same atomic CAS claim the pull-based picker uses.
/// The event, not a poll loop, is what triggers the attempt.
pub async fn react_to_event(
    client: &CoordClient,
    event: &StreamEvent,
    session_id: &str,
    should_claim: impl Fn(&Subtask) -> bool,
) -> Result<ReactOutcome> {
    if event.kind != "WORK_POSTED" {
        return Ok(ReactOutcome::Ignored);
    }

    let Some(subtask_id) = event.payload.get("reason").and_then(|v| v.as_str()) else {
        return Ok(ReactOutcome::Ignored);
    };

    let Some(subtask) = client.get_subtask(subtask_id).await? else {
        return Ok(ReactOutcome::Skipped);
    };

    if subtask.status != SubtaskStatus::Open || !should_claim(&subtask) {
        return Ok(ReactOutcome::Skipped);
    }

    match client.claim_subtask(subtask_id, session_id).await? {
        Ok(claimed) => Ok(ReactOutcome::Claimed(Box::new(claimed))),
        Err(_) => Ok(ReactOutcome::LostRace),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn work_posted_event(subtask_id: &str) -> StreamEvent {
        // Mirrors the exact shape CoordClient::post_subtask publishes
        // (lib::CoordEvent serialized: "event"/"gap"/"reason"/"files", no
        // "kind"/"payload" keys) after round-tripping through the bridging
        // Deserialize impl in events.rs.
        let raw = json!({
            "ts": "2026-08-15T00:00:00Z",
            "event": "WORK_POSTED",
            "session": "poster-session",
            "gap": "RESILIENT-334",
            "reason": subtask_id,
            "files": "some title",
        });
        serde_json::from_value(raw).expect("WORK_POSTED wire shape must deserialize")
    }

    #[test]
    fn non_work_posted_event_is_ignored() {
        let raw = json!({"ts": "t", "kind": "gap_claimed", "payload": {}});
        let event: StreamEvent = serde_json::from_value(raw).unwrap();
        assert_eq!(event.kind, "gap_claimed");
    }

    #[test]
    fn work_posted_event_carries_subtask_id_in_payload() {
        let event = work_posted_event("SUBTASK-abc12345");
        assert_eq!(event.kind, "WORK_POSTED");
        assert_eq!(
            event.payload.get("reason").and_then(|v| v.as_str()),
            Some("SUBTASK-abc12345")
        );
    }
}
