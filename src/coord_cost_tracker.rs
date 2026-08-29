//! META-082 (META-073 slice): cost tracking for coordination actions.
//!
//! Coordination actions (HANDOFF/route changes, lesson fetch/publish, etc.)
//! are cheap individually but run at fleet scale — this gives a rough
//! CPU-time/cost accounting so the operator can see where coordination
//! overhead concentrates. In-memory, process-local, same pattern as the
//! META-080 lesson store (bounded ring buffer, no persistence).

use serde::Serialize;
use std::collections::{BTreeMap, VecDeque};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Ring-buffer cap — bounds memory without needing a background reaper.
const MAX_RECORDS: usize = 2_000;

/// Placeholder cost model: $/ms of coordination-action wall-clock time.
/// Coarse stand-in until real CPU-accounting lands; keeps the AC's
/// "estimated resource cost" field non-zero and comparable across actions.
const COST_PER_MS_USD: f64 = 0.0000005;

#[derive(Clone, Serialize, Debug)]
pub struct CoordActionRecord {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost_usd: f64,
    pub ts_ms: i64,
}

#[derive(Default, Serialize, Debug)]
pub struct ActionTypeAgg {
    pub count: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_usd: f64,
}

#[derive(Serialize, Debug)]
pub struct CoordCostSnapshot {
    pub total_actions: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_usd: f64,
    pub by_action_type: BTreeMap<String, ActionTypeAgg>,
    pub recent: Vec<CoordActionRecord>,
}

static STORE: std::sync::OnceLock<Mutex<VecDeque<CoordActionRecord>>> = std::sync::OnceLock::new();

fn store() -> &'static Mutex<VecDeque<CoordActionRecord>> {
    STORE.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn now_ms_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Record one coordination action's cost. Cheap (in-memory push + optional
/// ambient emit); safe to call inline on the hot path of a coordination
/// handler.
pub fn record(agent_id: &str, action_type: &str, duration_ms: u64) {
    let estimated_cost_usd = duration_ms as f64 * COST_PER_MS_USD;
    let record = CoordActionRecord {
        agent_id: if agent_id.trim().is_empty() {
            "unknown".to_string()
        } else {
            agent_id.trim().to_string()
        },
        action_type: action_type.to_string(),
        duration_ms,
        estimated_cost_usd,
        ts_ms: now_ms_epoch(),
    };

    {
        let mut s = store().lock().unwrap_or_else(|e| e.into_inner());
        if s.len() >= MAX_RECORDS {
            s.pop_front();
        }
        s.push_back(record.clone());
    }

    // scanner-anchor: "kind":"coordination_action_cost"
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "coordination_action_cost".to_string(),
        fields: vec![
            ("agent_id".to_string(), record.agent_id.clone()),
            ("action_type".to_string(), record.action_type.clone()),
            ("duration_ms".to_string(), record.duration_ms.to_string()),
            (
                "estimated_cost_usd".to_string(),
                format!("{:.8}", record.estimated_cost_usd),
            ),
        ],
        ..Default::default()
    });
}

/// Aggregate snapshot for the /metrics endpoint (META-082 AC3).
pub fn snapshot() -> CoordCostSnapshot {
    let s = store().lock().unwrap_or_else(|e| e.into_inner());
    let mut by_action_type: BTreeMap<String, ActionTypeAgg> = BTreeMap::new();
    let mut total_duration_ms: u64 = 0;
    let mut total_estimated_cost_usd: f64 = 0.0;

    for r in s.iter() {
        let agg = by_action_type.entry(r.action_type.clone()).or_default();
        agg.count += 1;
        agg.total_duration_ms += r.duration_ms;
        agg.total_estimated_cost_usd += r.estimated_cost_usd;
        total_duration_ms += r.duration_ms;
        total_estimated_cost_usd += r.estimated_cost_usd;
    }

    CoordCostSnapshot {
        total_actions: s.len() as u64,
        total_duration_ms,
        total_estimated_cost_usd,
        by_action_type,
        recent: s.iter().rev().take(50).cloned().collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_snapshot_aggregates_by_action_type() {
        // Isolated store per test process would require DI; instead assert
        // relative deltas so this is safe to run alongside other tests that
        // touch the same process-global store.
        let before = snapshot().total_actions;
        record("agent-1", "lesson_fetch", 10);
        record("agent-2", "lesson_fetch", 20);
        record("agent-1", "route_change", 5);
        let after = snapshot();
        assert_eq!(after.total_actions, before + 3);
        let lesson_agg = after.by_action_type.get("lesson_fetch").unwrap();
        assert!(lesson_agg.count >= 2);
        assert!(lesson_agg.total_duration_ms >= 30);
        let route_agg = after.by_action_type.get("route_change").unwrap();
        assert!(route_agg.count >= 1);
    }

    #[test]
    fn record_computes_nonzero_estimated_cost_for_nonzero_duration() {
        record("agent-x", "test_action_cost", 100);
        let snap = snapshot();
        let found = snap
            .recent
            .iter()
            .find(|r| r.action_type == "test_action_cost")
            .expect("record present in recent window");
        assert!(found.estimated_cost_usd > 0.0);
    }

    #[test]
    fn record_defaults_empty_agent_id_to_unknown() {
        record("   ", "test_action_agent_default", 1);
        let snap = snapshot();
        let found = snap
            .recent
            .iter()
            .find(|r| r.action_type == "test_action_agent_default")
            .expect("record present");
        assert_eq!(found.agent_id, "unknown");
    }
}
