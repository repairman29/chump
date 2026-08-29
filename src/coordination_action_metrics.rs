//! META-082: cost tracking for coordination actions (META-073 slice).
//!
//! Coordination actions (A2A broadcasts/route changes, lesson fetches, ...)
//! were invisible cost-wise — no record of how long they took or what they
//! cost to run. This module gives every coordination call site a one-line
//! `record()` hook and exposes the accumulated data via
//! `GET /api/metrics/coordination-actions` (wired in web_server.rs).
//!
//! In-memory + process-local, same v1 scope as the META-080 lesson store
//! (docs/design/LESSON_PROPAGATION_FORMAT.md storage-layout note) — a
//! persisted/NATS-backed store is future work once this shape proves out.

use serde::Serialize;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Cap on retained records so a busy fleet can't grow this unbounded.
const MAX_RECORDS: usize = 1000;

/// Rough cost model: dollars per millisecond of coordination-action
/// wall-clock time. A placeholder until real CPU-time/token accounting is
/// wired in — good enough to rank actions by relative cost today.
const ESTIMATED_COST_PER_MS: f64 = 0.000_01;

#[derive(Clone, Serialize)]
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

/// Records one coordination action's cost metrics (AC-1/AC-2). Call this
/// with the agent id, an action-type label (e.g. "route_change",
/// "lesson_fetch", "lesson_publish"), and how long the action took.
pub fn record(agent_id: &str, action_type: &str, duration_ms: u64) {
    let record = CoordinationActionRecord {
        agent_id: agent_id.to_string(),
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost_usd: duration_ms as f64 * ESTIMATED_COST_PER_MS,
        ts_ms: now_ms_epoch(),
    };
    let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
    guard.push(record);
    if guard.len() > MAX_RECORDS {
        let drop = guard.len() - MAX_RECORDS;
        guard.drain(0..drop);
    }
}

#[derive(Serialize)]
pub struct ActionTypeSummary {
    pub action_type: String,
    pub count: usize,
    pub total_duration_ms: u64,
    pub total_estimated_cost_usd: f64,
}

/// Snapshot for the /metrics surface (AC-3): raw records plus a per-action-type
/// rollup so an operator can see cost without summing client-side.
pub fn snapshot() -> serde_json::Value {
    let guard = store().lock().unwrap_or_else(|e| e.into_inner());
    let records: Vec<&CoordinationActionRecord> = guard.iter().collect();

    let mut by_type: std::collections::BTreeMap<String, (usize, u64, f64)> =
        std::collections::BTreeMap::new();
    for r in &records {
        let entry = by_type.entry(r.action_type.clone()).or_insert((0, 0, 0.0));
        entry.0 += 1;
        entry.1 += r.duration_ms;
        entry.2 += r.estimated_cost_usd;
    }
    let by_action_type: Vec<ActionTypeSummary> = by_type
        .into_iter()
        .map(|(action_type, (count, total_duration_ms, total_estimated_cost_usd))| {
            ActionTypeSummary {
                action_type,
                count,
                total_duration_ms,
                total_estimated_cost_usd,
            }
        })
        .collect();

    serde_json::json!({
        "count": records.len(),
        "by_action_type": by_action_type,
        "records": records,
    })
}
