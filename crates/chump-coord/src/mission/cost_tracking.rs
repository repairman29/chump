//! Per-step cost + duration tracking and operator telemetry reporting for a
//! running [`super::persistence::Mission`] (MISSION-095, MISSION-001 slice).
//!
//! The agent runner that executes a mission's objectives calls
//! [`MissionCostTracker::record_step`] once per completed objective with the
//! token usage and wall-clock duration it observed, then calls
//! [`MissionCostTracker::report`] / [`MissionCostTracker::report_to_console`]
//! when the mission finishes (successfully or not) so the operator sees an
//! accurate roll-up rather than having to reconstruct it from per-step logs.

use std::fmt;

/// Token usage + duration recorded for a single mission objective.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StepCost {
    pub objective_id: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub duration_secs: u64,
}

/// Whether the mission finished successfully or not, for the telemetry line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MissionOutcome {
    Completed,
    Failed,
}

impl fmt::Display for MissionOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MissionOutcome::Completed => write!(f, "completed"),
            MissionOutcome::Failed => write!(f, "failed"),
        }
    }
}

/// Accumulates [`StepCost`] records for one mission run and produces an
/// operator-facing cost report on completion or failure.
#[derive(Clone, Debug, Default)]
pub struct MissionCostTracker {
    mission_id: String,
    steps: Vec<StepCost>,
}

impl MissionCostTracker {
    pub fn new(mission_id: impl Into<String>) -> Self {
        Self {
            mission_id: mission_id.into(),
            steps: Vec::new(),
        }
    }

    pub fn mission_id(&self) -> &str {
        &self.mission_id
    }

    /// Record token usage + duration for one completed (or failed)
    /// objective. Safe to call multiple times for the same `objective_id`
    /// (e.g. a retried step) — each call adds a new entry rather than
    /// overwriting, so the total reflects every attempt actually made.
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

    /// Number of step records collected (including repeated attempts on the
    /// same objective).
    pub fn step_count(&self) -> usize {
        self.steps.len()
    }

    pub fn total_input_tokens(&self) -> u64 {
        self.steps.iter().map(|s| s.input_tokens).sum()
    }

    pub fn total_output_tokens(&self) -> u64 {
        self.steps.iter().map(|s| s.output_tokens).sum()
    }

    /// Input + output tokens across every recorded step.
    pub fn total_tokens(&self) -> u64 {
        self.total_input_tokens() + self.total_output_tokens()
    }

    /// Wall-clock duration across every recorded step, in seconds.
    pub fn total_duration_secs(&self) -> u64 {
        self.steps.iter().map(|s| s.duration_secs).sum()
    }

    /// Estimated USD cost given per-1k-token rates. Rates are the caller's
    /// responsibility (model pricing varies); this just does the arithmetic.
    pub fn estimated_cost_usd(
        &self,
        input_rate_per_1k_usd: f64,
        output_rate_per_1k_usd: f64,
    ) -> f64 {
        let input_cost = (self.total_input_tokens() as f64 / 1000.0) * input_rate_per_1k_usd;
        let output_cost = (self.total_output_tokens() as f64 / 1000.0) * output_rate_per_1k_usd;
        input_cost + output_cost
    }

    /// Human-readable operator telemetry line summarizing the whole mission.
    pub fn report(&self, outcome: MissionOutcome) -> String {
        format!(
            "mission {} {}: {} steps, {} tokens ({} in / {} out), {}s total duration",
            self.mission_id,
            outcome,
            self.step_count(),
            self.total_tokens(),
            self.total_input_tokens(),
            self.total_output_tokens(),
            self.total_duration_secs(),
        )
    }

    /// Emit the report to the operator console (stderr) — called by the
    /// agent runner on mission completion or failure.
    pub fn report_to_console(&self, outcome: MissionOutcome) {
        eprintln!("{}", self.report(outcome));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_step_accumulates_tokens_and_duration_across_steps() {
        let mut t = MissionCostTracker::new("m-1");
        t.record_step("step-a", 100, 50, 10);
        t.record_step("step-b", 200, 150, 20);
        t.record_step("step-c", 10, 5, 1);

        assert_eq!(t.step_count(), 3);
        assert_eq!(t.total_input_tokens(), 310);
        assert_eq!(t.total_output_tokens(), 205);
        assert_eq!(t.total_tokens(), 515);
        assert_eq!(t.total_duration_secs(), 31);
    }

    #[test]
    fn repeated_attempts_on_same_objective_both_count() {
        // A retried step should add to the total, not overwrite it — the
        // operator needs the true cost of every attempt that ran.
        let mut t = MissionCostTracker::new("m-retry");
        t.record_step("flaky-step", 100, 50, 5);
        t.record_step("flaky-step", 100, 50, 5);

        assert_eq!(t.step_count(), 2);
        assert_eq!(t.total_tokens(), 300);
        assert_eq!(t.total_duration_secs(), 10);
    }

    #[test]
    fn empty_tracker_reports_zero() {
        let t = MissionCostTracker::new("m-empty");
        assert_eq!(t.step_count(), 0);
        assert_eq!(t.total_tokens(), 0);
        assert_eq!(t.total_duration_secs(), 0);
        assert_eq!(t.estimated_cost_usd(1.0, 1.0), 0.0);
    }

    #[test]
    fn estimated_cost_usd_applies_separate_input_output_rates() {
        let mut t = MissionCostTracker::new("m-cost");
        t.record_step("step-a", 1000, 2000, 1);
        // $3/1k input, $15/1k output — rough Claude-Sonnet-class rates.
        let cost = t.estimated_cost_usd(3.0, 15.0);
        assert!((cost - 33.0).abs() < 1e-9, "got {cost}");
    }

    #[test]
    fn report_includes_mission_id_outcome_and_totals() {
        let mut t = MissionCostTracker::new("m-report");
        t.record_step("step-a", 100, 50, 10);
        t.record_step("step-b", 200, 150, 20);

        let completed = t.report(MissionOutcome::Completed);
        assert!(completed.contains("m-report"));
        assert!(completed.contains("completed"));
        assert!(completed.contains("2 steps"));
        assert!(completed.contains("500 tokens"));
        assert!(completed.contains("30s total duration"));

        let failed = t.report(MissionOutcome::Failed);
        assert!(failed.contains("failed"));
    }

    #[test]
    fn mission_id_accessor_returns_constructed_id() {
        let t = MissionCostTracker::new("m-id-check");
        assert_eq!(t.mission_id(), "m-id-check");
    }
}
