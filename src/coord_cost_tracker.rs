//! META-082 (META-073 slice): cost tracking for coordination actions.
//!
//! Coordination actions (broadcasts, lesson publish/fetch, etc.) are cheap
//! individually but run at fleet scale — this gives a lightweight in-memory
//! ledger of who did what, how long it took, and an estimated resource cost,
//! surfaced via `/api/metrics`.

use serde::Serialize;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Bound the in-memory ledger so long-lived servers don't grow unbounded.
const MAX_RECORDS: usize = 2000;

/// Rough cost proxy: 1 unit per millisecond of wall-clock spent in the
/// handler. Not a billing figure — a relative signal for spotting expensive
/// coordination actions.
const COST_UNITS_PER_MS: f64 = 1.0;

#[derive(Clone, Debug, Serialize)]
pub struct CoordActionRecord {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost_units: f64,
    pub ts_ms: i64,
}

static LEDGER: std::sync::OnceLock<Mutex<VecDeque<CoordActionRecord>>> = std::sync::OnceLock::new();

fn ledger() -> &'static Mutex<VecDeque<CoordActionRecord>> {
    LEDGER.get_or_init(|| Mutex::new(VecDeque::with_capacity(MAX_RECORDS)))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Record one coordination action. `agent_id` falls back to "unknown" when
/// the caller has no session/agent identity (e.g. unauthenticated probes
/// never reach here since handlers check_auth first).
pub fn record(agent_id: &str, action_type: &str, duration_ms: u64) {
    let rec = CoordActionRecord {
        agent_id: if agent_id.trim().is_empty() {
            "unknown".to_string()
        } else {
            agent_id.trim().to_string()
        },
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost_units: duration_ms as f64 * COST_UNITS_PER_MS,
        ts_ms: now_ms(),
    };
    let mut store = ledger().lock().unwrap_or_else(|e| e.into_inner());
    if store.len() >= MAX_RECORDS {
        store.pop_front();
    }
    store.push_back(rec);
}

#[derive(Clone, Debug, Serialize, Default)]
pub struct CoordCostMetrics {
    pub total_actions: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_units: f64,
    pub by_action_type: HashMap<String, u64>,
    pub recent: Vec<CoordActionRecord>,
}

/// Summarize the ledger for `/api/metrics`. `recent` caps at 20 entries so
/// the metrics payload stays small even at MAX_RECORDS.
pub fn snapshot() -> CoordCostMetrics {
    let store = ledger().lock().unwrap_or_else(|e| e.into_inner());
    let mut metrics = CoordCostMetrics {
        total_actions: store.len() as u64,
        ..Default::default()
    };
    for rec in store.iter() {
        metrics.total_duration_ms += rec.duration_ms;
        metrics.total_estimated_cost_units += rec.estimated_cost_units;
        *metrics
            .by_action_type
            .entry(rec.action_type.clone())
            .or_insert(0) += 1;
    }
    metrics.recent = store.iter().rev().take(20).cloned().collect();
    metrics
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_snapshot_roundtrip() {
        record("agent-1", "broadcast:INTENT", 12);
        record("agent-2", "lesson_fetch", 3);
        let snap = snapshot();
        assert!(snap.total_actions >= 2);
        assert!(snap.by_action_type.contains_key("broadcast:INTENT"));
        assert!(snap.by_action_type.contains_key("lesson_fetch"));
        assert!(snap.total_duration_ms >= 15);
    }

    #[test]
    fn empty_agent_id_falls_back_to_unknown() {
        record("", "lesson_publish", 5);
        let snap = snapshot();
        assert!(snap.recent.iter().any(|r| r.agent_id == "unknown"));
    }
}
