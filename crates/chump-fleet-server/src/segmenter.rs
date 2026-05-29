//! Background segmenter — runs every 10s, derives `agent_segments` from `events`.
//!
//! ## Activity classifier
//!
//! Each event is mapped to one of: claim | edit | push | merge | blocked | idle.
//!
//! Classifier rules (evaluated in priority order):
//!   1. `event_kind` is "INTENT" or "claim"                       → claim
//!   2. `event_kind` is "DONE" or contains "merge"               → merge
//!   3. `event_kind` is "STUCK", "WARN", or "ALERT"              → blocked
//!   4. `event_kind` is "bash_call" AND payload contains
//!      "git push", "gh pr", or "bot-merge"                      → push
//!   5. `event_kind` is "bash_call" AND payload contains "cargo" → edit
//!   6. `event_kind` is "Edit"                                    → edit
//!   7. (fallback)                                                → edit
//!
//! ## Idle gap detection
//!
//! After sorting a session's events by ts_ms, any gap > 60 000ms between
//! consecutive events is inserted as an "idle" segment spanning the gap.
//!
//! ## Segment boundaries
//!
//! Activity runs of the same classified activity are collapsed into one segment.
//! A new segment starts when the activity changes.

use std::sync::Arc;
use tokio::time::{interval, Duration};
use tracing::{debug, error};

use crate::db::{EventRow, FleetStore};

const IDLE_GAP_MS: i64 = 60_000; // 60s gap → idle segment
const SEGMENT_INTERVAL_SECS: u64 = 10;

pub async fn run_segmenter_loop(store: Arc<FleetStore>) {
    let mut ticker = interval(Duration::from_secs(SEGMENT_INTERVAL_SECS));
    loop {
        ticker.tick().await;
        if let Err(e) = derive_segments(&store) {
            error!("segmenter error: {e}");
        } else {
            debug!("segmenter pass complete");
        }
    }
}

/// Derive/refresh all agent_segments from the current events table.
pub fn derive_segments(store: &FleetStore) -> anyhow::Result<()> {
    let sessions = store.all_session_ids()?;
    for session_id in sessions {
        derive_segments_for_session(store, &session_id)?;
    }
    Ok(())
}

fn derive_segments_for_session(store: &FleetStore, session_id: &str) -> anyhow::Result<()> {
    let events = store.events_for_session(session_id)?;
    if events.is_empty() {
        return Ok(());
    }

    // Build a flat list of (ts_ms, activity, gap_id) including synthetic idle spans.
    let mut spans: Vec<(i64, i64, String, Option<String>)> = Vec::new(); // (start_ms, end_ms, activity, gap_id)

    for window in events.windows(2) {
        let cur = &window[0];
        let next = &window[1];
        let activity = classify(cur);
        let gap_id = non_empty(&cur.gap_id);
        spans.push((cur.ts_ms, next.ts_ms, activity, gap_id));

        // Inject idle segment if the gap between events is large.
        let gap = next.ts_ms - cur.ts_ms;
        if gap > IDLE_GAP_MS {
            spans.push((cur.ts_ms + 1, next.ts_ms - 1, "idle".into(), None));
        }
    }

    // Handle the last event as an open-ended segment.
    if let Some(last) = events.last() {
        spans.push((
            last.ts_ms,
            last.ts_ms,
            classify(last),
            non_empty(&last.gap_id),
        ));
    }

    // Collapse consecutive same-activity spans into segments.
    // Each collapsed segment gets event_count = number of source events.
    let mut segments: Vec<(i64, i64, String, Option<String>, i64)> = Vec::new();
    // (start_ms, end_ms, activity, gap_id, event_count)

    for (start, end, activity, gap_id) in spans {
        if let Some(last) = segments.last_mut() {
            if last.2 == activity {
                last.1 = end;
                last.4 += 1;
                // Prefer the most-recent non-None gap_id.
                if gap_id.is_some() {
                    last.3 = gap_id;
                }
                continue;
            }
        }
        segments.push((start, end, activity, gap_id, 1));
    }

    // Upsert each segment.
    for (start_ms, end_ms, activity, gap_id, event_count) in segments {
        // end_ts_ms = None for the very last segment if it has no end (open).
        let end = if end_ms == start_ms {
            None
        } else {
            Some(end_ms)
        };
        store.upsert_segment(
            session_id,
            start_ms,
            end,
            &activity,
            gap_id.as_deref(),
            event_count,
        )?;
    }

    Ok(())
}

/// Classify a single event into an activity label.
///
/// Rules are evaluated in priority order (documented at module top).
fn classify(event: &EventRow) -> String {
    let kind = event.event_kind.as_str();
    let payload_lower = event.payload.to_lowercase();

    // 1. claim / intent
    if kind == "claim" || kind == "INTENT" {
        return "claim".into();
    }

    // 2. merge / done
    if kind == "DONE" || kind.contains("merge") {
        return "merge".into();
    }

    // 3. blocked
    if kind == "STUCK" || kind == "WARN" || kind == "ALERT" {
        return "blocked".into();
    }

    // 4. push — bash_call with git push / gh pr / bot-merge in payload
    if kind == "bash_call"
        && (payload_lower.contains("git push")
            || payload_lower.contains("gh pr")
            || payload_lower.contains("bot-merge"))
    {
        return "push".into();
    }

    // 5. edit — bash_call with cargo in payload
    if kind == "bash_call" && payload_lower.contains("cargo") {
        return "edit".into();
    }

    // 6. edit — explicit Edit event kind
    if kind == "Edit" {
        return "edit".into();
    }

    // 7. fallback
    "edit".into()
}

fn non_empty(s: &str) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}
