//! META-082: Cost tracking for coordination actions (META-073 slice).
//!
//! Coordination actions (route change, lesson fetch/publish, etc.) aren't
//! LLM calls — `cost_tracker.rs` already covers those — but they still burn
//! wall-time and CPU, and today that overhead is invisible. This module is a
//! lightweight in-memory recorder + aggregator, surfaced via
//! `GET /api/metrics` (`metrics::handle_metrics`).

use std::sync::{Mutex, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Rough CPU-time-to-dollar conversion for coordination actions. These are
/// local compute (routing scoring, ambient log I/O, in-memory lookups), not
/// billed API calls — this constant exists so relative costs are comparable
/// across action types, not as an invoice figure.
const ESTIMATED_COST_PER_MS_USD: f64 = 0.000_001;

/// Bounds the in-memory ring buffer so a busy fleet can't grow this
/// unbounded; oldest records are dropped first.
const MAX_RECORDS: usize = 2_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoordinationActionRecord {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: f64,
    pub estimated_cost_usd: f64,
    pub recorded_at_ms: i64,
}

fn store() -> &'static Mutex<Vec<CoordinationActionRecord>> {
    static STORE: OnceLock<Mutex<Vec<CoordinationActionRecord>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(Vec::new()))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Records one coordination action's cost and emits `kind=coordination_action_cost`
/// to the ambient stream for cross-agent/cross-session visibility.
pub fn record_action(
    agent_id: &str,
    action_type: &str,
    duration_ms: f64,
) -> CoordinationActionRecord {
    let record = CoordinationActionRecord {
        agent_id: agent_id.to_string(),
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost_usd: duration_ms * ESTIMATED_COST_PER_MS_USD,
        recorded_at_ms: now_ms(),
    };

    {
        let mut records = store().lock().unwrap_or_else(|e| e.into_inner());
        records.push(record.clone());
        if records.len() > MAX_RECORDS {
            let overflow = records.len() - MAX_RECORDS;
            records.drain(0..overflow);
        }
    }

    // scanner-anchor: "kind":"coordination_action_cost"
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "coordination_action_cost".to_string(),
        fields: vec![
            ("agent_id".to_string(), record.agent_id.clone()),
            ("action_type".to_string(), record.action_type.clone()),
            (
                "duration_ms".to_string(),
                format!("{:.3}", record.duration_ms),
            ),
            (
                "estimated_cost_usd".to_string(),
                format!("{:.9}", record.estimated_cost_usd),
            ),
        ],
        ..Default::default()
    });

    record
}

/// Measures `f`'s wall-time and records it as one coordination action for
/// `agent_id`/`action_type`. Convenience wrapper for call sites that don't
/// want to manage an `Instant` themselves.
pub fn time_action<T>(agent_id: &str, action_type: &str, f: impl FnOnce() -> T) -> T {
    let start = Instant::now();
    let result = f();
    record_action(
        agent_id,
        action_type,
        start.elapsed().as_secs_f64() * 1000.0,
    );
    result
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ActionTypeSummary {
    pub action_type: String,
    pub count: u64,
    pub total_duration_ms: f64,
    pub total_estimated_cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CoordinationCostSnapshot {
    pub total_actions: u64,
    pub total_duration_ms: f64,
    pub total_estimated_cost_usd: f64,
    pub by_action_type: Vec<ActionTypeSummary>,
}

/// Aggregates the in-memory ring buffer into a summary suitable for
/// `/api/metrics` (AC #3).
pub fn snapshot() -> CoordinationCostSnapshot {
    let records = store().lock().unwrap_or_else(|e| e.into_inner());
    let mut by_type: std::collections::BTreeMap<String, ActionTypeSummary> =
        std::collections::BTreeMap::new();
    let mut total = CoordinationCostSnapshot::default();

    for r in records.iter() {
        total.total_actions += 1;
        total.total_duration_ms += r.duration_ms;
        total.total_estimated_cost_usd += r.estimated_cost_usd;

        let entry = by_type
            .entry(r.action_type.clone())
            .or_insert_with(|| ActionTypeSummary {
                action_type: r.action_type.clone(),
                ..Default::default()
            });
        entry.count += 1;
        entry.total_duration_ms += r.duration_ms;
        entry.total_estimated_cost_usd += r.estimated_cost_usd;
    }

    total.by_action_type = by_type.into_values().collect();
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_and_aggregates() {
        record_action("agent-a", "unit_test_action_x", 12.5);
        record_action("agent-b", "unit_test_action_x", 7.5);
        let snap = snapshot();
        let entry = snap
            .by_action_type
            .iter()
            .find(|e| e.action_type == "unit_test_action_x")
            .expect("recorded action type present");
        assert_eq!(entry.count, 2);
        assert!((entry.total_duration_ms - 20.0).abs() < 1e-6);
        assert!(entry.total_estimated_cost_usd > 0.0);
        assert!(snap.total_actions >= 2);
    }

    #[test]
    fn time_action_measures_duration() {
        let out = time_action("agent-c", "unit_test_action_y", || {
            std::thread::sleep(std::time::Duration::from_millis(5));
            42
        });
        assert_eq!(out, 42);
        let snap = snapshot();
        let entry = snap
            .by_action_type
            .iter()
            .find(|e| e.action_type == "unit_test_action_y")
            .expect("recorded action type present");
        assert!(entry.total_duration_ms >= 4.0);
    }
}
