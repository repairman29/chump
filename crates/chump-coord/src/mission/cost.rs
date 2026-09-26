//! Per-objective (mission-step) cost tracking + operator telemetry reporting.
//!
//! [`MissionCostTracker`] accumulates token usage and execution duration for
//! each [`super::Objective`] as the mission's orchestrator runs it, then
//! [`MissionCostTracker::report_to_telemetry`] appends one JSON line to
//! `ambient.jsonl` (the fleet's operator telemetry stream, see
//! `src/session_ledger.rs` for the sibling per-session convention) summarizing
//! total token usage, duration, and estimated USD cost for the whole mission —
//! called once on mission completion or failure (MISSION-095).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

/// Token usage + wall-clock duration recorded for a single mission step
/// (one [`super::Objective`] execution).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepCost {
    pub objective_id: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub duration_secs: u64,
}

impl StepCost {
    pub fn total_tokens(&self) -> u64 {
        self.input_tokens.saturating_add(self.output_tokens)
    }
}

/// Accumulates [`StepCost`] entries across every step of one mission run.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MissionCostTracker {
    pub mission_id: String,
    pub steps: Vec<StepCost>,
}

impl MissionCostTracker {
    pub fn new(mission_id: impl Into<String>) -> Self {
        Self {
            mission_id: mission_id.into(),
            steps: Vec::new(),
        }
    }

    /// Record one mission step's usage. Multiple calls for the same
    /// `objective_id` (e.g. a retried step) are kept as separate entries so
    /// aggregation reflects actual spend, not just the final attempt.
    pub fn record_step(
        &mut self,
        objective_id: impl Into<String>,
        input_tokens: u64,
        output_tokens: u64,
        duration_secs: u64,
    ) {
        self.steps.push(StepCost {
            objective_id: objective_id.into(),
            input_tokens,
            output_tokens,
            duration_secs,
        });
    }

    pub fn total_input_tokens(&self) -> u64 {
        self.steps.iter().map(|s| s.input_tokens).sum()
    }

    pub fn total_output_tokens(&self) -> u64 {
        self.steps.iter().map(|s| s.output_tokens).sum()
    }

    pub fn total_tokens(&self) -> u64 {
        self.total_input_tokens()
            .saturating_add(self.total_output_tokens())
    }

    pub fn total_duration_secs(&self) -> u64 {
        self.steps.iter().map(|s| s.duration_secs).sum()
    }

    /// Estimated USD cost given a per-1k-token rate for input and output
    /// tokens respectively. Callers own the rate lookup (e.g. from
    /// `chump_cost_tracker::cost_usd_from_tokens`'s model-rate table); this
    /// tracker only owns the token/duration aggregation.
    pub fn estimated_cost_usd(&self, input_rate_per_1k: f64, output_rate_per_1k: f64) -> f64 {
        let input_cost = (self.total_input_tokens() as f64 / 1000.0) * input_rate_per_1k;
        let output_cost = (self.total_output_tokens() as f64 / 1000.0) * output_rate_per_1k;
        input_cost + output_cost
    }

    /// Append a `kind=mission_cost_report` line to `<repo_root>/.chump-locks/ambient.jsonl`,
    /// the fleet's operator telemetry stream. `outcome` should be
    /// `"completed"` or `"failed"` — call this once the mission reaches a
    /// terminal state, not per-step.
    pub fn report_to_telemetry(
        &self,
        repo_root: &Path,
        outcome: &str,
        input_rate_per_1k: f64,
        output_rate_per_1k: f64,
    ) -> Result<()> {
        let lock_dir = repo_root.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir)
            .with_context(|| format!("create {}", lock_dir.display()))?;
        let ambient = lock_dir.join("ambient.jsonl");

        let line = serde_json::json!({
            "ts": chrono::Utc::now().to_rfc3339(),
            "kind": "mission_cost_report",
            "mission_id": self.mission_id,
            "outcome": outcome,
            "step_count": self.steps.len(),
            "total_input_tokens": self.total_input_tokens(),
            "total_output_tokens": self.total_output_tokens(),
            "total_tokens": self.total_tokens(),
            "total_duration_secs": self.total_duration_secs(),
            "estimated_cost_usd": self.estimated_cost_usd(input_rate_per_1k, output_rate_per_1k),
        });

        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient)
            .with_context(|| format!("open {}", ambient.display()))?;
        writeln!(f, "{}", line).with_context(|| format!("write {}", ambient.display()))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aggregates_totals_across_multi_step_workflow() {
        let mut tracker = MissionCostTracker::new("mission-095-demo");
        tracker.record_step("step-a", 1000, 200, 10);
        tracker.record_step("step-b", 2000, 500, 25);
        tracker.record_step("step-c", 500, 100, 5);

        assert_eq!(tracker.steps.len(), 3);
        assert_eq!(tracker.total_input_tokens(), 3500);
        assert_eq!(tracker.total_output_tokens(), 800);
        assert_eq!(tracker.total_tokens(), 4300);
        assert_eq!(tracker.total_duration_secs(), 40);
    }

    #[test]
    fn aggregates_repeated_steps_from_retries() {
        let mut tracker = MissionCostTracker::new("mission-095-retry");
        tracker.record_step("step-a", 100, 20, 5);
        tracker.record_step("step-a", 150, 30, 7); // retry of the same objective

        assert_eq!(tracker.steps.len(), 2);
        assert_eq!(tracker.total_tokens(), 300);
        assert_eq!(tracker.total_duration_secs(), 12);
    }

    #[test]
    fn estimated_cost_uses_per_1k_rates() {
        let mut tracker = MissionCostTracker::new("mission-095-cost");
        tracker.record_step("step-a", 1000, 1000, 1);
        // $1 per 1k input, $2 per 1k output -> $1 + $2 = $3
        let cost = tracker.estimated_cost_usd(1.0, 2.0);
        assert!((cost - 3.0).abs() < 1e-9);
    }

    #[test]
    fn empty_tracker_has_zero_totals() {
        let tracker = MissionCostTracker::new("mission-095-empty");
        assert_eq!(tracker.total_tokens(), 0);
        assert_eq!(tracker.total_duration_secs(), 0);
        assert_eq!(tracker.estimated_cost_usd(5.0, 5.0), 0.0);
    }

    #[test]
    fn report_to_telemetry_writes_one_json_line_per_call() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut tracker = MissionCostTracker::new("mission-095-telemetry");
        tracker.record_step("step-a", 1000, 200, 10);
        tracker.record_step("step-b", 500, 100, 5);

        tracker
            .report_to_telemetry(tmp.path(), "completed", 1.0, 2.0)
            .expect("report succeeds");

        let ambient = tmp.path().join(".chump-locks/ambient.jsonl");
        let contents = std::fs::read_to_string(&ambient).expect("ambient.jsonl exists");
        let lines: Vec<&str> = contents.lines().collect();
        assert_eq!(lines.len(), 1);

        let parsed: serde_json::Value = serde_json::from_str(lines[0]).expect("valid json");
        assert_eq!(parsed["kind"], "mission_cost_report");
        assert_eq!(parsed["mission_id"], "mission-095-telemetry");
        assert_eq!(parsed["outcome"], "completed");
        assert_eq!(parsed["step_count"], 2);
        assert_eq!(parsed["total_input_tokens"], 1500);
        assert_eq!(parsed["total_output_tokens"], 300);
        assert_eq!(parsed["total_tokens"], 1800);
        assert_eq!(parsed["total_duration_secs"], 15);

        // A second report (e.g. failure after a partial re-run) appends,
        // it does not clobber the first line.
        tracker
            .report_to_telemetry(tmp.path(), "failed", 1.0, 2.0)
            .expect("second report succeeds");
        let contents = std::fs::read_to_string(&ambient).expect("ambient.jsonl exists");
        assert_eq!(contents.lines().count(), 2);
    }
}
