//! META-082 (META-073 slice): cost tracking for coordination actions.
//!
//! Every coordination action (broadcast/route change, lesson fetch/publish,
//! inbox read, ...) records CPU-time-proxy + an estimated resource cost into
//! a bounded in-memory ring buffer. Aggregates are exposed via
//! `GET /api/coordination-costs` (see `metrics::snapshot` for the rollup into
//! `/api/metrics`).
//!
//! v1 scope is process-local + non-persistent, matching the precedent set by
//! the META-080 lesson store (`LESSON_STORE` in web_server.rs) — a
//! durable/NATS-backed store is a follow-up once this shape proves useful.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Cap on retained per-action records so the buffer stays bounded without a
/// background reaper.
const MAX_RECORDS: usize = 2000;

/// Estimated USD cost per millisecond of coordination-action wall time.
/// A coarse proxy (not a billed figure) — good enough to rank which action
/// types/agents are the expensive ones.
const EST_COST_USD_PER_MS: f64 = 0.000_01;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct CoordinationActionRecord {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost_usd: f64,
    pub ts_ms: i64,
}

static STORE: std::sync::OnceLock<Mutex<Vec<CoordinationActionRecord>>> =
    std::sync::OnceLock::new();

fn store() -> &'static Mutex<Vec<CoordinationActionRecord>> {
    STORE.get_or_init(|| Mutex::new(Vec::new()))
}

fn now_ms_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Record one coordination action's cost. `agent_id` falls back to
/// `"unknown"` when the caller has no X-Session-ID (e.g. unauthenticated
/// probes) so aggregates never silently drop a sample.
pub fn record_action(agent_id: Option<&str>, action_type: &str, duration: Duration) {
    let duration_ms = duration.as_millis() as u64;
    let record = CoordinationActionRecord {
        agent_id: agent_id
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("unknown")
            .to_string(),
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost_usd: duration_ms as f64 * EST_COST_USD_PER_MS,
        ts_ms: now_ms_epoch(),
    };
    let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
    guard.push(record);
    let excess = guard.len().saturating_sub(MAX_RECORDS);
    if excess > 0 {
        guard.drain(0..excess);
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct ActionTypeAggregate {
    pub count: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_usd: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct CoordinationCostSnapshot {
    pub total_actions: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_usd: f64,
    pub by_action_type: HashMap<String, ActionTypeAggregate>,
    pub by_agent: HashMap<String, ActionTypeAggregate>,
    pub recent: Vec<CoordinationActionRecord>,
}

/// Aggregate everything currently retained in the ring buffer. `recent`
/// returns at most the last 50 records, newest last.
pub fn snapshot() -> CoordinationCostSnapshot {
    let guard = store().lock().unwrap_or_else(|e| e.into_inner());
    let mut by_action_type: HashMap<String, ActionTypeAggregate> = HashMap::new();
    let mut by_agent: HashMap<String, ActionTypeAggregate> = HashMap::new();
    let mut total_duration_ms = 0u64;
    let mut total_estimated_cost_usd = 0.0f64;

    for rec in guard.iter() {
        total_duration_ms += rec.duration_ms;
        total_estimated_cost_usd += rec.estimated_cost_usd;

        let by_type = by_action_type.entry(rec.action_type.clone()).or_default();
        by_type.count += 1;
        by_type.total_duration_ms += rec.duration_ms;
        by_type.total_estimated_cost_usd += rec.estimated_cost_usd;

        let by_agent_entry = by_agent.entry(rec.agent_id.clone()).or_default();
        by_agent_entry.count += 1;
        by_agent_entry.total_duration_ms += rec.duration_ms;
        by_agent_entry.total_estimated_cost_usd += rec.estimated_cost_usd;
    }

    let recent_start = guard.len().saturating_sub(50);
    let recent = guard[recent_start..].to_vec();

    CoordinationCostSnapshot {
        total_actions: guard.len() as u64,
        total_duration_ms,
        total_estimated_cost_usd,
        by_action_type,
        by_agent,
        recent,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_snapshot_roundtrip() {
        record_action(
            Some("agent-a"),
            "test_action_meta082",
            Duration::from_millis(10),
        );
        record_action(None, "test_action_meta082", Duration::from_millis(20));
        let snap = snapshot();
        assert!(snap.total_actions >= 2);
        let agg = snap
            .by_action_type
            .get("test_action_meta082")
            .expect("action type present");
        assert!(agg.count >= 2);
        assert!(agg.total_duration_ms >= 30);
        assert!(snap.by_agent.contains_key("unknown"));
    }
}
