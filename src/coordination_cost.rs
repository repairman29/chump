//! META-082: Cost tracking for coordination actions (META-073 slice).
//!
//! Coordination actions — route decisions (META-078), lesson publish/fetch
//! (META-080), and similar cross-agent plumbing — are cheap local
//! operations with no LLM call behind them, so "cost" here is a nominal
//! CPU/wall-clock proxy rather than a billed API cost. Records are kept in
//! a bounded in-memory ring buffer and surfaced via GET /api/metrics
//! (`crate::metrics`).

use serde::{Deserialize, Serialize};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// Nominal per-millisecond compute-cost proxy, in USD. Not a billed cost —
/// coordination actions don't call an LLM — just a consistent unit so
/// relative cost across action types is comparable at a glance.
const EST_COST_PER_MS_USD: f64 = 0.000002;

const MAX_RECORDS: usize = 500;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct CoordinationActionMetric {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost_usd: f64,
    pub timestamp_utc: String,
}

static STORE: OnceLock<Mutex<Vec<CoordinationActionMetric>>> = OnceLock::new();

fn store() -> &'static Mutex<Vec<CoordinationActionMetric>> {
    STORE.get_or_init(|| Mutex::new(Vec::new()))
}

fn now_epoch_secs() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}

/// Record one coordination action's cost metrics (AC #1, #2). Call this
/// from any coordination call site — route decision, lesson fetch, lesson
/// publish, etc. — right after the action completes, passing its measured
/// wall-clock duration.
pub fn record_action(agent_id: &str, action_type: &str, duration_ms: u64) {
    let record = CoordinationActionMetric {
        agent_id: agent_id.to_string(),
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost_usd: duration_ms as f64 * EST_COST_PER_MS_USD,
        timestamp_utc: now_epoch_secs(),
    };
    let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
    guard.push(record);
    if guard.len() > MAX_RECORDS {
        let excess = guard.len() - MAX_RECORDS;
        guard.drain(0..excess);
    }
}

/// Rollup + recent records for the /api/metrics endpoint (AC #3).
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct CoordinationCostSnapshot {
    pub total_actions: usize,
    pub total_estimated_cost_usd: f64,
    pub recent: Vec<CoordinationActionMetric>,
}

pub fn snapshot() -> CoordinationCostSnapshot {
    let guard = store().lock().unwrap_or_else(|e| e.into_inner());
    let total_actions = guard.len();
    let total_estimated_cost_usd = guard.iter().map(|r| r.estimated_cost_usd).sum();
    let recent: Vec<CoordinationActionMetric> = guard.iter().rev().take(50).cloned().collect();
    CoordinationCostSnapshot {
        total_actions,
        total_estimated_cost_usd,
        recent,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_snapshot_roundtrip() {
        record_action("agent-test-1", "route_decision", 12);
        record_action("agent-test-1", "lesson_fetch", 3);
        let snap = snapshot();
        assert!(snap.total_actions >= 2);
        assert!(snap.total_estimated_cost_usd >= 0.0);
        assert!(snap
            .recent
            .iter()
            .any(|r| r.action_type == "route_decision"));
    }

    #[test]
    fn ring_buffer_bounded() {
        for i in 0..(MAX_RECORDS + 10) {
            record_action("agent-bound-test", "lesson_fetch", i as u64);
        }
        let guard = store().lock().unwrap();
        assert!(guard.len() <= MAX_RECORDS);
    }
}
