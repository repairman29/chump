//! Speculative execution: fork-then-commit pattern for multi-step plans.
//!
//! Before executing a multi-step plan, the agent snapshots the belief state and
//! blackboard, runs the plan speculatively, and either commits the new state or
//! rolls back to the snapshot if verification fails.
//!
//! **Status: prototype / not yet wired into the agent loop.**
//! This module is tested in isolation but has no production callers.
//! Known limitations:
//! - `commit()` is a no-op (the closure already mutated globals).
//! - `rollback()` restores belief_state and neuromod but does NOT restore the
//!   blackboard to its pre-fork state.
//! - `evaluate()` reads global surprisal EMA, not surprise accumulated during
//!   the speculative window specifically.
//!
//! Wiring into the agent loop requires solving the "globals-already-mutated"
//! problem, likely by running speculative closures against cloned state rather
//! than process-wide singletons.
//!
//! Part of the Synthetic Consciousness Framework, Section 3.7.

use crate::belief_state::{TaskBelief, ToolBelief};
use std::collections::HashMap;

/// A frozen snapshot of the system state before speculative execution begins.
#[derive(Debug, Clone)]
pub struct Snapshot {
    /// Belief state: per-tool reliabilities.
    tool_beliefs: HashMap<String, ToolBelief>,
    /// Belief state: task trajectory.
    task_belief: TaskBelief,
    /// Blackboard entry IDs and their content hashes (for cheap diffing).
    blackboard_entries: Vec<(u64, String, f64)>, // (id, source, salience)
    /// Neuromodulator levels at fork time.
    neuromod: crate::neuromodulation::NeuromodState,
    /// Timestamp of snapshot creation.
    created_at: std::time::Instant,
}

/// Result of evaluating a speculative execution.
#[derive(Debug, Clone)]
pub struct SpeculativeResult {
    /// Did the plan succeed according to verification criteria?
    pub success: bool,
    /// Confidence delta: how much did trajectory confidence change?
    pub confidence_delta: f64,
    /// Number of steps executed.
    pub steps_executed: u32,
    /// Steps that failed.
    pub failures: Vec<String>,
    /// Surprise accumulated during speculation.
    pub accumulated_surprise: f64,
}

/// Outcome of a commit/rollback decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resolution {
    Committed,
    RolledBack,
}

/// Take a snapshot of the current belief state and blackboard.
pub fn fork() -> Snapshot {
    let (tool_beliefs, task_belief) = crate::belief_state::snapshot_inner();
    let bb = crate::blackboard::global();
    let bb_entries = bb.broadcast_entries();
    let blackboard_entries: Vec<_> = bb_entries
        .iter()
        .map(|e| (e.id, e.source.to_string(), e.salience))
        .collect();
    let neuromod = crate::neuromodulation::levels();

    Snapshot {
        tool_beliefs,
        task_belief,
        blackboard_entries,
        neuromod,
        created_at: std::time::Instant::now(),
    }
}

/// Evaluate whether the speculative execution should be committed.
///
/// Criteria:
/// - trajectory confidence improved or stayed stable
/// - no catastrophic surprise spike
/// - fewer than half the steps failed
pub fn evaluate(
    snapshot: &Snapshot,
    steps_attempted: u32,
    failures: &[String],
) -> SpeculativeResult {
    let current_task = crate::belief_state::task_belief();
    let confidence_delta =
        current_task.trajectory_confidence - snapshot.task_belief.trajectory_confidence;
    let accumulated_surprise = crate::surprise_tracker::current_surprisal_ema();

    let failure_ratio = if steps_attempted > 0 {
        failures.len() as f64 / steps_attempted as f64
    } else {
        0.0
    };

    let success = confidence_delta >= -0.1 && failure_ratio < 0.5 && accumulated_surprise < 0.7;

    SpeculativeResult {
        success,
        confidence_delta,
        steps_executed: steps_attempted,
        failures: failures.to_vec(),
        accumulated_surprise,
    }
}

/// Commit the speculative execution: the current state becomes the real state.
/// The snapshot is discarded.
pub fn commit(_snapshot: Snapshot) -> Resolution {
    Resolution::Committed
}

/// Roll back to the snapshot, restoring belief state and neuromodulator levels.
pub fn rollback(snapshot: Snapshot) -> Resolution {
    crate::belief_state::restore_from_snapshot(snapshot.tool_beliefs, snapshot.task_belief);
    crate::neuromodulation::restore(snapshot.neuromod);
    Resolution::RolledBack
}

/// High-level: fork, run a closure, evaluate, and auto-resolve.
///
/// The closure receives a mutable step tracker and returns a list of failures.
/// Returns the resolution and the speculative result.
pub fn speculate<F>(plan_steps: u32, execute_fn: F) -> (Resolution, SpeculativeResult)
where
    F: FnOnce() -> Vec<String>,
{
    let snapshot = fork();
    let failures = execute_fn();
    let result = evaluate(&snapshot, plan_steps, &failures);

    if result.success {
        (commit(snapshot), result)
    } else {
        (rollback(snapshot), result)
    }
}

/// JSON metrics for the health endpoint.
pub fn metrics_json(last_result: Option<&SpeculativeResult>) -> serde_json::Value {
    match last_result {
        Some(r) => serde_json::json!({
            "last_success": r.success,
            "confidence_delta": (r.confidence_delta * 1000.0).round() / 1000.0,
            "steps_executed": r.steps_executed,
            "failures": r.failures.len(),
            "accumulated_surprise": (r.accumulated_surprise * 1000.0).round() / 1000.0,
        }),
        None => serde_json::json!({
            "status": "no speculative execution yet"
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fork_creates_snapshot() {
        let snap = fork();
        assert!(snap.created_at.elapsed().as_secs() < 1);
    }

    #[test]
    fn test_evaluate_no_failures_succeeds() {
        let snap = fork();
        let result = evaluate(&snap, 3, &[]);
        assert!(result.success, "no failures should succeed");
        assert_eq!(result.steps_executed, 3);
        assert!(result.failures.is_empty());
    }

    #[test]
    fn test_evaluate_many_failures_rolls_back() {
        let snap = fork();
        let failures = vec![
            "step1 failed".to_string(),
            "step2 failed".to_string(),
            "step3 failed".to_string(),
        ];
        let result = evaluate(&snap, 4, &failures);
        assert!(!result.success, "75% failure rate should not succeed");
    }

    #[test]
    fn test_commit_returns_committed() {
        let snap = fork();
        assert_eq!(commit(snap), Resolution::Committed);
    }

    #[test]
    fn test_rollback_returns_rolled_back() {
        let snap = fork();
        assert_eq!(rollback(snap), Resolution::RolledBack);
    }

    #[test]
    fn test_speculate_happy_path() {
        let (resolution, result) = speculate(2, || vec![]);
        assert_eq!(resolution, Resolution::Committed);
        assert!(result.success);
    }

    #[test]
    fn test_speculate_failure_path() {
        let (resolution, result) = speculate(2, || vec!["fail1".to_string(), "fail2".to_string()]);
        assert_eq!(resolution, Resolution::RolledBack);
        assert!(!result.success);
    }

    #[test]
    fn test_metrics_json_with_result() {
        let result = SpeculativeResult {
            success: true,
            confidence_delta: 0.05,
            steps_executed: 3,
            failures: vec![],
            accumulated_surprise: 0.2,
        };
        let j = metrics_json(Some(&result));
        assert_eq!(j["last_success"], true);
        assert_eq!(j["steps_executed"], 3);
    }

    #[test]
    fn test_metrics_json_without_result() {
        let j = metrics_json(None);
        assert!(j.get("status").is_some());
    }
}
