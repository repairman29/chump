//! META-082: cost tracking for coordination actions (META-073 slice).
//!
//! Every coordination action (route change, lesson fetch, etc.) records a
//! sample — agent id, action type, duration, and an estimated resource
//! cost — to the ambient log as `kind=coordination_action_cost`. The
//! `/metrics` endpoint (see `crate::metrics`) reads the log back and
//! aggregates it so the operator can see coordination overhead alongside
//! PR/gap/fleet metrics.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write as IoWrite;
use std::time::Instant;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

fn ambient_log_path() -> String {
    std::env::var("CHUMP_AMBIENT_LOG").unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string())
}

/// Wall-clock timer for one coordination action. Start it before the
/// action begins, then call `finish` with the agent id + action type once
/// it completes to record + emit the sample.
pub struct ActionTimer {
    started: Instant,
}

impl ActionTimer {
    pub fn start() -> Self {
        Self {
            started: Instant::now(),
        }
    }

    pub fn finish(
        self,
        agent_id: impl Into<String>,
        action_type: impl Into<String>,
    ) -> Result<CoordinationActionCost> {
        let duration_ms = u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX);
        record_coordination_action(agent_id, action_type, duration_ms)
    }
}

/// One recorded coordination-action cost sample.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoordinationActionCost {
    pub ts: String,
    pub agent_id: String,
    pub action_type: String,
    pub duration_ms: u64,
    pub estimated_cost_units: f64,
}

/// Coordination actions are dominated by wall-clock (network/db round
/// trips), not CPU, so the cost model is a straight scaling of duration:
/// 100ms == 1 cost unit, applied uniformly across action types.
fn estimate_cost_units(duration_ms: u64) -> f64 {
    duration_ms as f64 / 100.0
}

/// Record + emit one coordination-action cost sample. Appends
/// `kind=coordination_action_cost` to the ambient log (AC #1, #2).
pub fn record_coordination_action(
    agent_id: impl Into<String>,
    action_type: impl Into<String>,
    duration_ms: u64,
) -> Result<CoordinationActionCost> {
    let sample = CoordinationActionCost {
        ts: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        agent_id: agent_id.into(),
        action_type: action_type.into(),
        duration_ms,
        estimated_cost_units: estimate_cost_units(duration_ms),
    };
    append_ambient_line(&sample)?;
    Ok(sample)
}

fn append_ambient_line(sample: &CoordinationActionCost) -> Result<()> {
    let ambient_path = ambient_log_path();
    let entry = serde_json::json!({
        "ts": sample.ts,
        "kind": "coordination_action_cost",
        "agent_id": sample.agent_id,
        "action_type": sample.action_type,
        "duration_ms": sample.duration_ms,
        "estimated_cost_units": sample.estimated_cost_units,
    });
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .with_context(|| format!("opening ambient log at {ambient_path}"))?;
    writeln!(file, "{}", entry).with_context(|| format!("writing ambient log at {ambient_path}"))
}

/// Aggregate summary of `coordination_action_cost` samples, broken down by
/// action type. Exposed via `/metrics` (AC #3).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CoordinationCostSummary {
    pub sample_count: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_units: f64,
    pub by_action_type: BTreeMap<String, ActionTypeSummary>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ActionTypeSummary {
    pub sample_count: u64,
    pub total_duration_ms: u64,
    pub total_estimated_cost_units: f64,
}

/// Read the ambient log and aggregate every `coordination_action_cost`
/// entry found there. A missing log file just means no coordination
/// activity has been recorded yet — returns an empty summary, not an
/// error.
pub fn summarize() -> CoordinationCostSummary {
    let ambient_path = ambient_log_path();
    let mut summary = CoordinationCostSummary::default();
    let Ok(contents) = fs::read_to_string(&ambient_path) else {
        return summary;
    };
    for line in contents.lines() {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if value.get("kind").and_then(|k| k.as_str()) != Some("coordination_action_cost") {
            continue;
        }
        let duration_ms = value
            .get("duration_ms")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let cost = value
            .get("estimated_cost_units")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let action_type = value
            .get("action_type")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();

        summary.sample_count += 1;
        summary.total_duration_ms += duration_ms;
        summary.total_estimated_cost_units += cost;

        let entry = summary.by_action_type.entry(action_type).or_default();
        entry.sample_count += 1;
        entry.total_duration_ms += duration_ms;
        entry.total_estimated_cost_units += cost;
    }
    summary
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn records_and_summarizes_a_sample() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);

        record_coordination_action("agent-1", "route_change", 250).unwrap();
        record_coordination_action("agent-2", "lesson_fetch", 50).unwrap();
        record_coordination_action("agent-1", "route_change", 150).unwrap();

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"coordination_action_cost\""));
        assert!(contents.contains("\"action_type\":\"route_change\""));

        let summary = summarize();
        assert_eq!(summary.sample_count, 3);
        assert_eq!(summary.total_duration_ms, 450);
        assert!((summary.total_estimated_cost_units - 4.5).abs() < f64::EPSILON);

        let route_change = summary.by_action_type.get("route_change").unwrap();
        assert_eq!(route_change.sample_count, 2);
        assert_eq!(route_change.total_duration_ms, 400);

        let lesson_fetch = summary.by_action_type.get("lesson_fetch").unwrap();
        assert_eq!(lesson_fetch.sample_count, 1);
        assert_eq!(lesson_fetch.total_duration_ms, 50);

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    fn summarize_on_missing_log_is_empty() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::set_var("CHUMP_AMBIENT_LOG", "/tmp/does-not-exist-coord-cost.jsonl");
        let summary = summarize();
        assert_eq!(summary.sample_count, 0);
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    fn action_timer_records_elapsed_duration() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);

        let timer = ActionTimer::start();
        let sample = timer.finish("agent-3", "route_change").unwrap();
        assert_eq!(sample.agent_id, "agent-3");
        assert_eq!(sample.action_type, "route_change");

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }
}
