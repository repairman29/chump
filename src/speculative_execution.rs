//! Speculative execution: snapshot around multi-tool batches in the agent loop.
//!
//! **Production caller:** [`crate::agent_loop`] when a model returns **≥3** tool calls in one
//! turn (`CHUMP_SPECULATIVE_BATCH=0` disables). Tools **run for real** before evaluate/rollback;
//! there is no dry-run layer.
//!
//! **What rollback restores:** in-process [`crate::belief_state`], [`crate::neuromodulation`],
//! and [`crate::blackboard`] (entries, ids, novelty hashes, read counts, subscriptions via
//! [`BlackboardRestoreState`]). **Not restored:** any external side effects (files, SQLite via
//! tools, HTTP, Discord, etc.).
//!
//! **What `commit()` does:** intentionally nothing—state was already updated by tool execution.
//!
//! **Evaluation:** [`evaluate`] compares surprisal EMA **after** the batch to the value **at
//! `fork()`** (`surprisal_ema_delta`). Threshold overridable with `CHUMP_SPECULATIVE_SURPRISE_DELTA_MAX`.
//!
//! For true transactional speculation (undoable tool effects), see the repo doc
//! `docs/ADR-001-transactional-tool-speculation.md`.
//!
//! Part of the Synthetic Consciousness Framework, Section 3.7.

use crate::belief_state::{TaskBelief, ToolBelief};
use crate::blackboard::BlackboardRestoreState;
use std::collections::HashMap;
use std::sync::Mutex;

/// A frozen snapshot of the system state before speculative execution begins.
#[derive(Debug, Clone)]
pub struct Snapshot {
    /// Belief state: per-tool reliabilities.
    tool_beliefs: HashMap<String, ToolBelief>,
    /// Belief state: task trajectory.
    task_belief: TaskBelief,
    /// Full blackboard snapshot (entries, ids, novelty hashes, read counts, subscriptions).
    blackboard: BlackboardRestoreState,
    /// Neuromodulator levels at fork time.
    neuromod: crate::neuromodulation::NeuromodState,
    /// Global surprisal EMA at `fork()` (for batch-local delta in `evaluate`).
    surprisal_ema_at_fork: f64,
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
    /// Increase in global surprisal EMA since `fork()` (`max(0, ema_now - ema_at_fork)`).
    pub surprisal_ema_delta: f64,
}

/// Outcome of a commit/rollback decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resolution {
    Committed,
    RolledBack,
}

static LAST_SPECULATIVE_BATCH: Mutex<Option<(Resolution, SpeculativeResult)>> = Mutex::new(None);

/// Record the most recent ≥3-tool batch evaluation (for `/health` and ops).
pub fn record_last_speculative_batch(resolution: Resolution, result: SpeculativeResult) {
    if let Ok(mut g) = LAST_SPECULATIVE_BATCH.lock() {
        *g = Some((resolution, result));
    }
}

/// Last batch metrics for `GET /health` → `consciousness_dashboard.speculative_batch`.
pub fn last_speculative_metrics_json() -> serde_json::Value {
    let guard = LAST_SPECULATIVE_BATCH.lock().ok();
    let pair = guard.as_ref().and_then(|g| g.as_ref());
    match pair {
        Some((res, r)) => serde_json::json!({
            "resolution": match res {
                Resolution::Committed => "committed",
                Resolution::RolledBack => "rolled_back",
            },
            "last_success": r.success,
            "confidence_delta": (r.confidence_delta * 1000.0).round() / 1000.0,
            "steps_executed": r.steps_executed,
            "failures": r.failures.len(),
            "surprisal_ema_delta": (r.surprisal_ema_delta * 1000.0).round() / 1000.0,
        }),
        None => serde_json::json!({
            "status": "no speculative batch evaluated in this process yet"
        }),
    }
}

fn speculative_surprise_delta_max() -> f64 {
    std::env::var("CHUMP_SPECULATIVE_SURPRISE_DELTA_MAX")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0)
        .unwrap_or(0.25)
}

/// Take a snapshot of the current belief state and blackboard.
pub fn fork() -> Snapshot {
    let (tool_beliefs, task_belief) = crate::belief_state::snapshot_inner();
    let blackboard = crate::blackboard::global().capture_restore_state();
    let neuromod = crate::neuromodulation::levels();
    let surprisal_ema_at_fork = crate::surprise_tracker::current_surprisal_ema();

    Snapshot {
        tool_beliefs,
        task_belief,
        blackboard,
        neuromod,
        surprisal_ema_at_fork,
        created_at: std::time::Instant::now(),
    }
}

/// Evaluate whether the speculative execution should be committed.
///
/// Criteria:
/// - trajectory confidence improved or stayed stable
/// - surprisal EMA did not spike too much **since `fork()`** (not absolute global EMA)
/// - fewer than half the steps failed
pub fn evaluate(
    snapshot: &Snapshot,
    steps_attempted: u32,
    failures: &[String],
) -> SpeculativeResult {
    let current_task = crate::belief_state::task_belief();
    let confidence_delta =
        current_task.trajectory_confidence - snapshot.task_belief.trajectory_confidence;
    let ema_now = crate::surprise_tracker::current_surprisal_ema();
    let surprisal_ema_delta = (ema_now - snapshot.surprisal_ema_at_fork).max(0.0);
    let delta_cap = speculative_surprise_delta_max();

    let failure_ratio = if steps_attempted > 0 {
        failures.len() as f64 / steps_attempted as f64
    } else {
        0.0
    };

    let success =
        confidence_delta >= -0.1 && failure_ratio < 0.5 && surprisal_ema_delta < delta_cap;

    SpeculativeResult {
        success,
        confidence_delta,
        steps_executed: steps_attempted,
        failures: failures.to_vec(),
        surprisal_ema_delta,
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
    crate::blackboard::global().restore_from_state(snapshot.blackboard);
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
            "surprisal_ema_delta": (r.surprisal_ema_delta * 1000.0).round() / 1000.0,
        }),
        None => serde_json::json!({
            "status": "no speculative execution yet"
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blackboard::{Module, SalienceFactors};
    use serial_test::serial;

    // Any test that calls fork/rollback/speculate mutates the global blackboard; keep these
    // serialized so they do not interleave with #[serial] blackboard assertions below.
    #[test]
    #[serial]
    fn test_fork_creates_snapshot() {
        let snap = fork();
        assert!(snap.created_at.elapsed().as_secs() < 1);
    }

    #[test]
    #[serial]
    fn test_evaluate_no_failures_succeeds() {
        let snap = fork();
        let result = evaluate(&snap, 3, &[]);
        assert!(result.success, "no failures should succeed");
        assert_eq!(result.steps_executed, 3);
        assert!(result.failures.is_empty());
    }

    #[test]
    #[serial]
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
    #[serial]
    fn test_commit_returns_committed() {
        let snap = fork();
        assert_eq!(commit(snap), Resolution::Committed);
    }

    #[test]
    #[serial]
    fn test_rollback_returns_rolled_back() {
        let snap = fork();
        assert_eq!(rollback(snap), Resolution::RolledBack);
    }

    #[test]
    #[serial]
    fn test_speculate_happy_path() {
        let (resolution, result) = speculate(2, std::vec::Vec::new);
        assert_eq!(resolution, Resolution::Committed);
        assert!(result.success);
    }

    #[test]
    #[serial]
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
            surprisal_ema_delta: 0.2,
        };
        let j = metrics_json(Some(&result));
        assert_eq!(j["last_success"], true);
        assert_eq!(j["steps_executed"], 3);
        assert_eq!(j["surprisal_ema_delta"], 0.2);
    }

    #[test]
    fn test_metrics_json_without_result() {
        let j = metrics_json(None);
        assert!(j.get("status").is_some());
    }

    #[test]
    #[serial]
    fn test_rollback_restores_blackboard_after_post() {
        let snap = fork();
        let marker = format!("rollback_marker_pid_{}", std::process::id());
        let factors = SalienceFactors {
            novelty: 1.0,
            uncertainty_reduction: 0.6,
            goal_relevance: 0.7,
            urgency: 0.3,
        };
        crate::blackboard::post(Module::Memory, marker.clone(), factors);
        let ctx_before = crate::blackboard::global().broadcast_context(20, 50_000);
        assert!(
            ctx_before.contains(&marker),
            "marker should appear in broadcast context: {}",
            ctx_before
        );
        rollback(snap);
        let ctx_after = crate::blackboard::global().broadcast_context(20, 50_000);
        assert!(
            !ctx_after.contains(&marker),
            "rollback should remove post-fork blackboard entry; still see: {}",
            ctx_after
        );
    }

    #[test]
    #[serial]
    fn test_evaluate_fails_when_surprisal_ema_spikes_since_fork() {
        crate::surprise_tracker::set_surprisal_ema_for_test(0.0);
        let snap = fork();
        assert_eq!(snap.surprisal_ema_at_fork, 0.0);
        crate::surprise_tracker::set_surprisal_ema_for_test(0.5);
        let result = evaluate(&snap, 3, &[]);
        assert!(
            !result.success,
            "EMA delta 0.5 should exceed default cap 0.25: {:?}",
            result
        );
        assert!((result.surprisal_ema_delta - 0.5).abs() < 1e-9);
    }

    #[test]
    #[serial]
    fn test_rollback_restores_subscriptions() {
        let factors = SalienceFactors {
            novelty: 1.0,
            uncertainty_reduction: 0.6,
            goal_relevance: 0.7,
            urgency: 0.3,
        };
        let mem_mark = format!("subrestore_mem_{}", std::process::id());
        let ep_mark = format!("subrestore_ep_{}", std::process::id());
        let bb = crate::blackboard::global();

        bb.subscribe(Module::Autonomy, vec![Module::Memory]);
        crate::blackboard::post(Module::Memory, mem_mark.clone(), factors.clone());
        let snap = fork();

        bb.subscribe(Module::Autonomy, vec![Module::Episode]);
        crate::blackboard::post(Module::Episode, ep_mark.clone(), factors);

        let mid: Vec<_> = bb
            .read_subscribed(&Module::Autonomy)
            .into_iter()
            .map(|e| e.content)
            .collect();
        assert!(mid.iter().any(|c| c == &ep_mark), "mid {:?}", mid);
        assert!(!mid.iter().any(|c| c == &mem_mark));

        rollback(snap);

        let after: Vec<_> = bb
            .read_subscribed(&Module::Autonomy)
            .into_iter()
            .map(|e| e.content)
            .collect();
        assert!(
            after.iter().any(|c| c == &mem_mark),
            "expected memory post after rollback: {:?}",
            after
        );
        assert!(!after.iter().any(|c| c == &ep_mark));
    }
}
