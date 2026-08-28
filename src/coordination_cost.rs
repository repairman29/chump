//! META-082: Cost tracking for coordination actions (META-073 slice).
//!
//! Any coordination action (route change, lesson fetch, collision check,
//! etc.) can call [`record_action`] to log its resource footprint: which
//! agent performed it, what kind of action it was, how long it took, and
//! its estimated USD cost. Entries are kept in-process (capped ring
//! buffer) so [`summary`] can serve `/api/metrics` cheaply, and each entry
//! is also appended to `ambient.jsonl` as `kind=coordination_action_cost`
//! for durable, cross-session visibility.

use std::collections::HashMap;
use std::fs;
use std::io::Write as IoWrite;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Ring-buffer cap for the in-process history — bounds memory while still
/// giving `/api/metrics` a useful recent window.
const MAX_RECORDED_ACTIONS: usize = 1000;

/// One coordination action's cost record (AC #2: agent ID, action type,
/// duration, estimated resource cost).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionCost {
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost_usd: f64,
    pub ts_epoch_secs: u64,
}

/// Aggregated totals for one `action_type` bucket.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ActionTypeTotals {
    pub count: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_usd: f64,
}

/// Rollup served via `/api/metrics` (AC #3).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CoordinationCostSummary {
    pub total_actions: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_usd: f64,
    pub by_action_type: HashMap<String, ActionTypeTotals>,
}

fn history() -> &'static Mutex<Vec<ActionCost>> {
    static HISTORY: OnceLock<Mutex<Vec<ActionCost>>> = OnceLock::new();
    HISTORY.get_or_init(|| Mutex::new(Vec::new()))
}

fn ambient_log_path() -> String {
    std::env::var("CHUMP_AMBIENT_LOG").unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string())
}

fn append_ambient_line(entry: &serde_json::Value) -> Result<()> {
    let ambient_path = ambient_log_path();
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .with_context(|| format!("opening ambient log at {ambient_path}"))?;
    writeln!(file, "{}", entry).with_context(|| format!("writing ambient log at {ambient_path}"))
}

/// Record one coordination action's cost (AC #1 + #2): stores it in the
/// in-process ring buffer for `/api/metrics` and emits
/// `kind=coordination_action_cost` to `ambient.jsonl`.
///
/// `action_type` is caller-defined (e.g. `"route_change"`, `"lesson_fetch"`,
/// `"collision_check"`) — no closed enum here since the set of coordination
/// action kinds grows as new META-073 slices land.
pub fn record_action(
    agent_id: impl Into<String>,
    action_type: impl Into<String>,
    duration_ms: u64,
    estimated_cost_usd: f64,
) -> ActionCost {
    let ts_epoch_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let record = ActionCost {
        agent_id: agent_id.into(),
        action_type: action_type.into(),
        duration_ms,
        estimated_cost_usd,
        ts_epoch_secs,
    };

    if let Ok(mut buf) = history().lock() {
        if buf.len() >= MAX_RECORDED_ACTIONS {
            buf.remove(0);
        }
        buf.push(record.clone());
    }

    let entry = serde_json::json!({
        "ts": ts_epoch_secs,
        "kind": "coordination_action_cost",
        "agent_id": record.agent_id,
        "action_type": record.action_type,
        "duration_ms": record.duration_ms,
        "estimated_cost_usd": record.estimated_cost_usd,
    });
    // Cost logging must never block or fail the coordination action itself.
    let _ = append_ambient_line(&entry);

    record
}

/// Most recent recorded actions, newest last, capped at `limit`.
pub fn recent(limit: usize) -> Vec<ActionCost> {
    let buf = match history().lock() {
        Ok(b) => b,
        Err(_) => return Vec::new(),
    };
    let start = buf.len().saturating_sub(limit);
    buf[start..].to_vec()
}

/// Aggregate totals across all recorded actions (bounded by the in-process
/// ring buffer), broken down by `action_type`.
pub fn summary() -> CoordinationCostSummary {
    let buf = match history().lock() {
        Ok(b) => b,
        Err(_) => return CoordinationCostSummary::default(),
    };

    let mut out = CoordinationCostSummary {
        total_actions: buf.len() as u64,
        ..Default::default()
    };
    for record in buf.iter() {
        out.total_duration_ms += record.duration_ms;
        out.total_estimated_cost_usd += record.estimated_cost_usd;
        let entry = out
            .by_action_type
            .entry(record.action_type.clone())
            .or_default();
        entry.count += 1;
        entry.total_duration_ms += record.duration_ms;
        entry.total_estimated_cost_usd += record.estimated_cost_usd;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;
    use tempfile::TempDir;

    // Serializes tests that touch the process-global history + env var.
    static TEST_LOCK: StdMutex<()> = StdMutex::new(());

    fn reset_history() {
        if let Ok(mut buf) = history().lock() {
            buf.clear();
        }
    }

    #[test]
    fn record_action_updates_summary_totals() {
        let _guard = TEST_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        reset_history();

        record_action("agent-a", "route_change", 12, 0.001);
        record_action("agent-b", "lesson_fetch", 8, 0.0005);
        record_action("agent-a", "route_change", 20, 0.002);

        let summary = summary();
        assert_eq!(summary.total_actions, 3);
        assert_eq!(summary.total_duration_ms, 40);
        assert!((summary.total_estimated_cost_usd - 0.0035).abs() < 1e-9);

        let route = summary.by_action_type.get("route_change").unwrap();
        assert_eq!(route.count, 2);
        assert_eq!(route.total_duration_ms, 32);

        let lesson = summary.by_action_type.get("lesson_fetch").unwrap();
        assert_eq!(lesson.count, 1);
        assert_eq!(lesson.total_duration_ms, 8);

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        reset_history();
    }

    #[test]
    fn record_action_emits_ambient_event() {
        let _guard = TEST_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        reset_history();

        record_action("agent-c", "collision_check", 5, 0.0001);

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"coordination_action_cost\""));
        assert!(contents.contains("\"agent_id\":\"agent-c\""));
        assert!(contents.contains("\"action_type\":\"collision_check\""));

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        reset_history();
    }

    #[test]
    fn recent_returns_bounded_newest_slice() {
        let _guard = TEST_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        reset_history();

        for i in 0..5 {
            record_action("agent-d", "route_change", i, 0.0);
        }

        let last_two = recent(2);
        assert_eq!(last_two.len(), 2);
        assert_eq!(last_two[0].duration_ms, 3);
        assert_eq!(last_two[1].duration_ms, 4);

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        reset_history();
    }
}
