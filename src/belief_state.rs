//! REMOVAL-003 stub — belief_state experiment was NEUTRAL on EVAL-001
//! (delta=+0.020), so the implementation crate `chump-belief-state` (666 LOC)
//! has been removed. This module preserves the public call surface as inert
//! no-ops so callsites don't churn in this PR.
//!
//! Decision matrix: `docs/eval/REMOVAL-001-decision-matrix.md`.
//!
//! What this means at runtime:
//! - all writes (`update_tool_belief`, `decay_turn`, `nudge_trajectory`,
//!   `restore_from_snapshot`) are silent no-ops
//! - all reads (`task_belief`, `tool_belief`, `tool_reliability`,
//!   `score_tools`, `should_escalate_epistemic`, `metrics_json`,
//!   `context_summary`) return inert defaults / empty values
//!
//! Old on-disk `AutonomySnapshot` checkpoints continue to deserialize because
//! the shadow `ToolBelief` / `TaskBelief` structs below keep the same field
//! names and `serde(default)` on every field. Restored values are read into
//! the structs and then dropped on the floor when handed back to
//! `restore_from_snapshot`.
//!
//! Follow-up gap (TBD): mechanical sweep of the ~47 callsites — this PR
//! intentionally keeps them so the diff is small and revertible.

use std::collections::HashMap;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ToolBelief {
    #[serde(default = "one")]
    pub alpha: f64,
    #[serde(default = "one")]
    pub beta: f64,
    #[serde(default)]
    pub latency_mean_ms: f64,
    #[serde(default)]
    pub latency_var_ms: f64,
    #[serde(default)]
    pub sample_count: u64,
}

fn one() -> f64 {
    1.0
}

impl ToolBelief {
    pub fn reliability(&self) -> f64 {
        let denom = self.alpha + self.beta;
        if denom == 0.0 {
            0.5
        } else {
            self.alpha / denom
        }
    }
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct TaskBelief {
    #[serde(default = "half")]
    pub trajectory_confidence: f64,
    #[serde(default = "one")]
    pub model_freshness: f64,
    #[serde(default)]
    pub streak_successes: u32,
    #[serde(default)]
    pub streak_failures: u32,
}

fn half() -> f64 {
    0.5
}

impl TaskBelief {
    /// Inert: always returns 0.0. Callers that gate on `> 0.55` thresholds
    /// (precision_controller) are now permanently below threshold.
    pub fn uncertainty(&self) -> f64 {
        0.0
    }
}

#[derive(Debug, Clone)]
pub struct EFEScore {
    pub tool_name: String,
    pub ambiguity: f64,
    pub risk: f64,
    pub pragmatic_value: f64,
    pub g: f64,
}

pub fn belief_state_enabled() -> bool {
    false
}
pub fn update_tool_belief(_tool_name: &str, _success: bool, _latency_ms: u64) {}
pub fn decay_turn() {}
pub fn nudge_trajectory(_delta: f64) {}
pub fn tool_belief(_tool_name: &str) -> Option<ToolBelief> {
    None
}
pub fn task_belief() -> TaskBelief {
    TaskBelief::default()
}
pub fn snapshot_inner() -> (HashMap<String, ToolBelief>, TaskBelief) {
    (HashMap::new(), TaskBelief::default())
}
pub fn restore_from_snapshot(_tool_beliefs: HashMap<String, ToolBelief>, _task_belief: TaskBelief) {
}
pub fn score_tools(_candidate_tools: &[&str]) -> Vec<EFEScore> {
    Vec::new()
}
pub fn score_tools_except(_excluded: &str) -> Vec<EFEScore> {
    Vec::new()
}
pub fn should_escalate_epistemic() -> bool {
    false
}
pub fn context_summary() -> String {
    String::new()
}
pub fn metrics_json() -> serde_json::Value {
    serde_json::json!({ "status": "removed (REMOVAL-003)" })
}
pub fn tool_reliability(_tool_name: &str) -> f64 {
    0.5
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies old on-disk JSON with the full belief field set still
    /// round-trips through the shadow structs.
    #[test]
    fn legacy_snapshot_deserializes() {
        let json = r#"{
            "alpha": 5.0,
            "beta": 2.0,
            "latency_mean_ms": 120.0,
            "latency_var_ms": 400.0,
            "sample_count": 7
        }"#;
        let tb: ToolBelief = serde_json::from_str(json).expect("legacy ToolBelief");
        assert_eq!(tb.sample_count, 7);
        assert!((tb.reliability() - 5.0 / 7.0).abs() < 1e-9);

        let json = r#"{
            "trajectory_confidence": 0.8,
            "model_freshness": 0.9,
            "streak_successes": 2,
            "streak_failures": 0
        }"#;
        let task: TaskBelief = serde_json::from_str(json).expect("legacy TaskBelief");
        assert_eq!(task.streak_successes, 2);
        assert_eq!(task.uncertainty(), 0.0);
    }

    #[test]
    fn missing_fields_use_defaults() {
        let tb: ToolBelief = serde_json::from_str("{}").expect("empty ToolBelief");
        assert_eq!(tb.alpha, 1.0);
        assert_eq!(tb.beta, 1.0);
        assert_eq!(tb.sample_count, 0);
    }

    #[test]
    fn reads_are_inert() {
        assert!(!belief_state_enabled());
        assert!(tool_belief("anything").is_none());
        assert_eq!(tool_reliability("anything"), 0.5);
        assert!(score_tools(&["a", "b"]).is_empty());
        assert!(!should_escalate_epistemic());
    }
}
