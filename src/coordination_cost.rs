//! META-082: cost tracking for coordination actions (META-073 slice).
//!
//! Coordination actions (route changes via /api/broadcast, lesson
//! fetches/publishes via /api/lessons, etc.) are cheap individually but add
//! up across a fleet of agents. This module gives them a bounded in-memory
//! ledger — agent id, action type, duration, estimated resource cost — so
//! the aggregate overhead is visible via `/api/metrics` instead of being
//! invisible fleet tax.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Bound on retained records so the in-memory ledger stays flat under
/// sustained load; oldest records are dropped first.
const MAX_RECORDS: usize = 2000;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct CoordinationActionRecord {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost: f64,
    pub recorded_at_ms: i64,
}

static ACTION_LOG: std::sync::OnceLock<Mutex<Vec<CoordinationActionRecord>>> =
    std::sync::OnceLock::new();

fn action_log() -> &'static Mutex<Vec<CoordinationActionRecord>> {
    ACTION_LOG.get_or_init(|| Mutex::new(Vec::new()))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Record a coordination action's CPU/time/cost metrics.
pub fn record_action(agent_id: &str, action_type: &str, duration_ms: u64, estimated_cost: f64) {
    let record = CoordinationActionRecord {
        agent_id: agent_id.to_string(),
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost,
        recorded_at_ms: now_ms(),
    };
    let mut log = action_log().lock().unwrap_or_else(|e| e.into_inner());
    log.push(record);
    if log.len() > MAX_RECORDS {
        let excess = log.len() - MAX_RECORDS;
        log.drain(0..excess);
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct ActionTypeBreakdown {
    pub action_type: String,
    pub count: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct CoordinationCostMetrics {
    pub total_actions: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost: f64,
    pub by_action_type: Vec<ActionTypeBreakdown>,
}

/// Aggregate snapshot of the ledger, grouped by action type.
pub fn snapshot() -> CoordinationCostMetrics {
    let log = action_log().lock().unwrap_or_else(|e| e.into_inner());
    let mut by_type: BTreeMap<String, ActionTypeBreakdown> = BTreeMap::new();
    let mut total_duration_ms = 0u64;
    let mut total_estimated_cost = 0.0f64;
    for rec in log.iter() {
        total_duration_ms += rec.duration_ms;
        total_estimated_cost += rec.estimated_cost;
        let entry = by_type
            .entry(rec.action_type.clone())
            .or_insert_with(|| ActionTypeBreakdown {
                action_type: rec.action_type.clone(),
                ..Default::default()
            });
        entry.count += 1;
        entry.total_duration_ms += rec.duration_ms;
        entry.total_estimated_cost += rec.estimated_cost;
    }
    CoordinationCostMetrics {
        total_actions: log.len() as u64,
        total_duration_ms,
        total_estimated_cost,
        by_action_type: by_type.into_values().collect(),
    }
}

/// Most recent `limit` raw records, newest first.
pub fn recent(limit: usize) -> Vec<CoordinationActionRecord> {
    let log = action_log().lock().unwrap_or_else(|e| e.into_inner());
    log.iter().rev().take(limit).cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_aggregates_by_action_type() {
        record_action("agent-a", "route_change", 10, 0.001);
        record_action("agent-b", "route_change", 20, 0.002);
        record_action("agent-a", "lesson_fetch", 5, 0.0005);
        let snap = snapshot();
        assert!(snap.total_actions >= 3);
        let route_change = snap
            .by_action_type
            .iter()
            .find(|b| b.action_type == "route_change")
            .expect("route_change breakdown present");
        assert!(route_change.count >= 2);
    }
}
