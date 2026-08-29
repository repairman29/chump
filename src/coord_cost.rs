//! META-082 (META-073 slice): cost tracking for coordination actions.
//!
//! Coordination actions (skill-aware route selection, lesson fetch/publish,
//! etc.) are cheap individually but run at fleet scale — this module gives
//! each one a single call site (`record_action`) that logs agent ID, action
//! type, duration, and an estimated resource cost, then rolls the log up
//! into a bounded in-memory summary exposed via `/api/metrics`.
//!
//! Process-local, non-persistent — same v1 scope as the META-080 lesson
//! store (src/web_server.rs). A durable/NATS-backed store is a follow-up
//! once this shape proves useful.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Cap on retained records so the in-memory store stays bounded without a
/// background reaper.
const MAX_RECORDS: usize = 2000;
/// How many of the most recent records to surface verbatim in the summary.
const RECENT_WINDOW: usize = 20;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CoordActionRecord {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost: f64,
    pub timestamp_ms: i64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ActionTypeStats {
    pub count: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CoordCostSummary {
    pub total_actions: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost: f64,
    pub by_action_type: HashMap<String, ActionTypeStats>,
    pub recent: Vec<CoordActionRecord>,
}

static STORE: std::sync::OnceLock<Mutex<Vec<CoordActionRecord>>> = std::sync::OnceLock::new();

fn store() -> &'static Mutex<Vec<CoordActionRecord>> {
    STORE.get_or_init(|| Mutex::new(Vec::new()))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Very rough resource-cost estimate: coordination actions are dominated by
/// wall-clock (I/O, subprocess spawn), so cost scales linearly with
/// duration. $0.0001 per ms (~$0.36/CPU-hour) is a placeholder constant
/// until real CPU-time accounting lands.
const COST_PER_MS: f64 = 0.0001;

pub fn estimate_cost(duration_ms: u64) -> f64 {
    duration_ms as f64 * COST_PER_MS
}

/// Log one coordination action. Call this at each coordination call site
/// (route selection, lesson fetch/publish, ...) with the agent that
/// triggered it, a short action-type tag, and the measured duration.
pub fn record_action(agent_id: &str, action_type: &str, duration_ms: u64) {
    let record = CoordActionRecord {
        agent_id: agent_id.to_string(),
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost: estimate_cost(duration_ms),
        timestamp_ms: now_ms(),
    };
    let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
    guard.push(record);
    if guard.len() > MAX_RECORDS {
        let overflow = guard.len() - MAX_RECORDS;
        guard.drain(0..overflow);
    }
}

/// Roll the bounded log up into a summary for `/api/metrics`.
pub fn snapshot() -> CoordCostSummary {
    let guard = store().lock().unwrap_or_else(|e| e.into_inner());
    let mut by_action_type: HashMap<String, ActionTypeStats> = HashMap::new();
    let mut total_duration_ms = 0u64;
    let mut total_estimated_cost = 0.0f64;
    for r in guard.iter() {
        let entry = by_action_type.entry(r.action_type.clone()).or_default();
        entry.count += 1;
        entry.total_duration_ms += r.duration_ms;
        entry.total_estimated_cost += r.estimated_cost;
        total_duration_ms += r.duration_ms;
        total_estimated_cost += r.estimated_cost;
    }
    let recent = guard
        .iter()
        .rev()
        .take(RECENT_WINDOW)
        .cloned()
        .collect::<Vec<_>>();
    CoordCostSummary {
        total_actions: guard.len() as u64,
        total_duration_ms,
        total_estimated_cost,
        by_action_type,
        recent,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tests share the process-global STORE, so serialize them to avoid
    // cross-test count pollution.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn records_action_and_rolls_up_by_type() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        store().lock().unwrap_or_else(|e| e.into_inner()).clear();

        record_action("agent-1", "route_change", 12);
        record_action("agent-2", "lesson_fetch", 5);
        record_action("agent-1", "route_change", 8);

        let summary = snapshot();
        assert_eq!(summary.total_actions, 3);
        assert_eq!(summary.total_duration_ms, 25);
        let route_stats = summary.by_action_type.get("route_change").unwrap();
        assert_eq!(route_stats.count, 2);
        assert_eq!(route_stats.total_duration_ms, 20);
        let lesson_stats = summary.by_action_type.get("lesson_fetch").unwrap();
        assert_eq!(lesson_stats.count, 1);
        assert_eq!(summary.recent.len(), 3);
        assert_eq!(summary.recent[0].agent_id, "agent-1");
        assert_eq!(summary.recent[0].action_type, "route_change");
    }

    #[test]
    fn estimate_cost_scales_with_duration() {
        assert!(estimate_cost(1000) > estimate_cost(10));
        assert_eq!(estimate_cost(0), 0.0);
    }

    #[test]
    fn bounds_store_to_max_records() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        store().lock().unwrap_or_else(|e| e.into_inner()).clear();
        for i in 0..(MAX_RECORDS + 50) {
            record_action("agent-x", "route_change", i as u64);
        }
        let summary = snapshot();
        assert_eq!(summary.total_actions, MAX_RECORDS as u64);
    }
}
