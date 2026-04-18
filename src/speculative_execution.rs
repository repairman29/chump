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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// INFRA-001a observability: process-lifetime counter of write-tool
/// invocations that ran inside a speculative branch which then ROLLED
/// BACK. The branch's in-process state was reverted; the file/network
/// side effects were NOT. Quantifies the "product pain" gate criterion
/// in INFRA-001 — when this number gets non-trivial, INFRA-001b
/// (sandbox routing) earns its complexity.
///
/// Callers (typically tool_middleware after a speculative rollback)
/// invoke `record_unrolled_side_effect()` per leaked write-tool call.
/// Today no caller wires this up — the counter sits at 0 until
/// INFRA-001a-wire (separate gap) lands. The metric infrastructure
/// is here so the wiring change is one-line; doc + plumbing already
/// exist.
static UNROLLED_SIDE_EFFECTS: AtomicU64 = AtomicU64::new(0);
static UNROLLED_SIDE_EFFECTS_LAST_TOOL: Mutex<Option<String>> = Mutex::new(None);

/// Record one write-tool invocation that wasn't rolled back when its
/// containing speculative branch reverted. Bumps the counter, stashes
/// the tool name for the most-recent metric, and emits a tracing::warn.
pub fn record_unrolled_side_effect(tool_name: &str) {
    UNROLLED_SIDE_EFFECTS.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut last) = UNROLLED_SIDE_EFFECTS_LAST_TOOL.lock() {
        *last = Some(tool_name.to_string());
    }
    tracing::warn!(
        tool = tool_name,
        unrolled_total = UNROLLED_SIDE_EFFECTS.load(Ordering::Relaxed),
        "speculation: write-tool side effect persisted across rollback (INFRA-001a)"
    );
}

/// Snapshot the unrolled-side-effect counter for /api/health.
pub fn unrolled_side_effects_metrics() -> serde_json::Value {
    let last = UNROLLED_SIDE_EFFECTS_LAST_TOOL
        .lock()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| "(none yet)".to_string());
    serde_json::json!({
        "total": UNROLLED_SIDE_EFFECTS.load(Ordering::Relaxed),
        "last_tool": last,
        "note": "Increments on every write-tool call that ran inside a rolled-back speculative branch (INFRA-001a). Wiring from tool_middleware is INFRA-001a-wire (separate gap)."
    })
}

#[cfg(test)]
fn reset_unrolled_side_effects_for_tests() {
    UNROLLED_SIDE_EFFECTS.store(0, Ordering::Relaxed);
    if let Ok(mut g) = UNROLLED_SIDE_EFFECTS_LAST_TOOL.lock() {
        *g = None;
    }
}

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
///
/// If `CHUMP_SANDBOX_SPECULATION=1`, also creates a sandbox git worktree so
/// write tools can direct their side effects there. The sandbox is committed or
/// torn down by [`commit`] / [`rollback`].
pub fn fork() -> Snapshot {
    let (tool_beliefs, task_belief) = crate::belief_state::snapshot_inner();
    let blackboard = crate::blackboard::global().capture_restore_state();
    let neuromod = crate::neuromodulation::levels();
    let surprisal_ema_at_fork = crate::surprise_tracker::current_surprisal_ema();

    // INFRA-001b: create sandbox worktree when opt-in flag is set.
    if sandbox_speculation_enabled() {
        match create_sandbox_worktree() {
            Ok(path) => {
                if let Ok(mut guard) = SPECULATIVE_SANDBOX_PATH.lock() {
                    // If there's already a sandbox (leaked from a previous fork), clean it up.
                    if let Some(old) = guard.take() {
                        tracing::warn!(
                            old_path = %old.display(),
                            "INFRA-001b: replacing leaked sandbox from previous fork"
                        );
                        remove_sandbox_worktree(&old);
                    }
                    *guard = Some(path);
                }
            }
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "INFRA-001b: failed to create sandbox worktree — proceeding WITHOUT sandbox isolation"
                );
            }
        }
    }

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

// ── INFRA-001b: sandbox speculation ──────────────────────────────────────────

/// Whether sandbox speculation is enabled.
pub fn sandbox_speculation_enabled() -> bool {
    std::env::var("CHUMP_SANDBOX_SPECULATION")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// The sandbox root for the current speculative branch.
/// Returns Some(path) when `CHUMP_SANDBOX_SPECULATION=1` and a fork is active.
/// Write tools should redirect their working directory here.
static SPECULATIVE_SANDBOX_PATH: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);

/// Return the sandbox root for the active speculative branch, or None.
///
/// Tools in the **sandboxed** policy class check this before writing:
/// if Some(root), they should remap their working directory to `root`
/// (e.g. by prefixing file paths relative to repo root).
pub fn speculative_sandbox_root() -> Option<std::path::PathBuf> {
    SPECULATIVE_SANDBOX_PATH.lock().ok().and_then(|g| g.clone())
}

/// Create a git worktree for the current speculative branch.
/// Returns the worktree path on success.
fn create_sandbox_worktree() -> anyhow::Result<std::path::PathBuf> {
    use std::process::Command;
    let repo_root = crate::repo_path::repo_root();
    let wt_name = format!(
        ".chump-spec-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    );
    let wt_path = repo_root.join(&wt_name);
    let out = Command::new("git")
        .current_dir(&repo_root)
        .args(["worktree", "add", "--detach"])
        .arg(&wt_path)
        .output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow::anyhow!(
            "git worktree add failed: {}",
            stderr.trim()
        ));
    }
    tracing::info!(path = %wt_path.display(), "INFRA-001b: speculative sandbox worktree created");
    Ok(wt_path)
}

/// Remove the sandbox worktree at `path`, best-effort.
fn remove_sandbox_worktree(path: &std::path::Path) {
    let root = crate::repo_path::repo_root();
    let git_remove_ok = std::process::Command::new("git")
        .current_dir(&root)
        .args(["worktree", "remove", "--force"])
        .arg(path)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if !git_remove_ok {
        // Fallback: just rm -rf the directory.
        let _ = std::fs::remove_dir_all(path);
    }
    tracing::info!(path = %path.display(), "INFRA-001b: speculative sandbox worktree removed");
}

/// Copy files modified in the sandbox back to the real working tree.
///
/// Uses `git diff --name-only HEAD` inside the sandbox worktree to find
/// changed (unstaged + staged) files, then copies them to the repo root.
/// Also copies any untracked files that were created inside the sandbox.
fn commit_sandbox_to_real(sandbox_path: &std::path::Path) -> anyhow::Result<()> {
    use std::process::Command;

    // Collect changed tracked files (unstaged + staged diffs vs HEAD).
    let diff_out = Command::new("git")
        .current_dir(sandbox_path)
        .args(["diff", "--name-only", "HEAD"])
        .output()?;
    let staged_out = Command::new("git")
        .current_dir(sandbox_path)
        .args(["diff", "--name-only", "--cached"])
        .output()?;
    // Also collect untracked files.
    let untracked_out = Command::new("git")
        .current_dir(sandbox_path)
        .args(["ls-files", "--others", "--exclude-standard"])
        .output()?;

    let repo_root = crate::repo_path::repo_root();
    let mut files: Vec<String> = Vec::new();
    for bytes in [diff_out.stdout, staged_out.stdout, untracked_out.stdout] {
        for line in String::from_utf8_lossy(&bytes).lines() {
            let l = line.trim().to_string();
            if !l.is_empty() && !files.contains(&l) {
                files.push(l);
            }
        }
    }

    let mut copied = 0usize;
    for rel_path in &files {
        let src = sandbox_path.join(rel_path);
        let dst = repo_root.join(rel_path);
        if src.exists() {
            if let Some(parent) = dst.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::copy(&src, &dst)?;
            copied += 1;
        }
    }

    tracing::info!(
        files_copied = copied,
        sandbox = %sandbox_path.display(),
        "INFRA-001b: sandbox committed — {} file(s) copied to real tree",
        copied
    );
    Ok(())
}

/// Commit the speculative execution: the current state becomes the real state.
/// If `CHUMP_SANDBOX_SPECULATION=1`, copies sandbox changes to the real working tree
/// and removes the sandbox worktree.
pub fn commit(_snapshot: Snapshot) -> Resolution {
    if let Ok(mut guard) = SPECULATIVE_SANDBOX_PATH.lock() {
        if let Some(sandbox) = guard.take() {
            if let Err(e) = commit_sandbox_to_real(&sandbox) {
                tracing::warn!(error = %e, "INFRA-001b: sandbox commit copy failed — rolling back instead");
                remove_sandbox_worktree(&sandbox);
                return Resolution::RolledBack;
            }
            remove_sandbox_worktree(&sandbox);
        }
    }
    Resolution::Committed
}

/// Roll back to the snapshot, restoring belief state and neuromodulator levels.
/// If `CHUMP_SANDBOX_SPECULATION=1`, removes the sandbox worktree (no file changes applied).
pub fn rollback(snapshot: Snapshot) -> Resolution {
    crate::belief_state::restore_from_snapshot(snapshot.tool_beliefs, snapshot.task_belief);
    crate::neuromodulation::restore(snapshot.neuromod);
    crate::blackboard::global().restore_from_state(snapshot.blackboard);
    // INFRA-001b: discard sandbox worktree if one was created.
    if let Ok(mut guard) = SPECULATIVE_SANDBOX_PATH.lock() {
        if let Some(sandbox) = guard.take() {
            remove_sandbox_worktree(&sandbox);
        }
    }
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
    let mut base = match last_result {
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
    };
    // INFRA-001a: include unrolled-side-effect telemetry on every metrics
    // emission so /api/health surfaces it whether or not a spec batch
    // has run this process lifetime.
    if let Some(obj) = base.as_object_mut() {
        obj.insert(
            "unrolled_side_effects".to_string(),
            unrolled_side_effects_metrics(),
        );
    }
    base
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

    // ── INFRA-001a: unrolled-side-effect counter ──────────────────────

    #[test]
    #[serial(unrolled_se)]
    fn unrolled_side_effect_starts_at_zero() {
        reset_unrolled_side_effects_for_tests();
        let m = unrolled_side_effects_metrics();
        assert_eq!(m["total"], 0);
        assert_eq!(m["last_tool"], "(none yet)");
    }

    #[test]
    #[serial(unrolled_se)]
    fn record_unrolled_side_effect_increments() {
        reset_unrolled_side_effects_for_tests();
        record_unrolled_side_effect("write_file");
        record_unrolled_side_effect("patch_file");
        record_unrolled_side_effect("write_file");
        let m = unrolled_side_effects_metrics();
        assert_eq!(m["total"], 3);
        // last_tool is the most recent one
        assert_eq!(m["last_tool"], "write_file");
    }

    #[test]
    #[serial(unrolled_se)]
    fn metrics_json_includes_unrolled_side_effects() {
        reset_unrolled_side_effects_for_tests();
        record_unrolled_side_effect("git_push");
        let metrics = metrics_json(None);
        let unrolled = &metrics["unrolled_side_effects"];
        assert!(unrolled.is_object(), "should be a sub-object");
        assert_eq!(unrolled["total"], 1);
        assert_eq!(unrolled["last_tool"], "git_push");
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

    // ── INFRA-001b: sandbox speculation tests ──────────────────────────

    /// Helper: clear the global sandbox path between tests.
    fn clear_sandbox_state() {
        if let Ok(mut guard) = SPECULATIVE_SANDBOX_PATH.lock() {
            *guard = None;
        }
    }

    #[test]
    #[serial]
    fn sandbox_disabled_by_default() {
        std::env::remove_var("CHUMP_SANDBOX_SPECULATION");
        assert!(!sandbox_speculation_enabled());
        assert!(speculative_sandbox_root().is_none());
    }

    #[test]
    #[serial]
    fn sandbox_enabled_by_env_var() {
        std::env::set_var("CHUMP_SANDBOX_SPECULATION", "1");
        assert!(sandbox_speculation_enabled());
        std::env::remove_var("CHUMP_SANDBOX_SPECULATION");
    }

    #[test]
    #[serial]
    fn fork_without_sandbox_env_does_not_create_worktree() {
        std::env::remove_var("CHUMP_SANDBOX_SPECULATION");
        clear_sandbox_state();
        let snap = fork();
        // No sandbox should be set.
        assert!(speculative_sandbox_root().is_none());
        // Rollback should succeed without any worktree ops.
        let _ = rollback(snap);
        clear_sandbox_state();
    }

    #[test]
    #[serial]
    fn fork_with_sandbox_creates_worktree() {
        std::env::set_var("CHUMP_SANDBOX_SPECULATION", "1");
        clear_sandbox_state();
        let snap = fork();
        let sandbox = speculative_sandbox_root();
        std::env::remove_var("CHUMP_SANDBOX_SPECULATION");

        if let Some(ref path) = sandbox {
            // The worktree should exist on disk.
            assert!(
                path.exists(),
                "sandbox worktree should be created: {}",
                path.display()
            );
            // Rollback should remove it.
            let _ = rollback(snap);
            // After rollback, the directory should be gone.
            assert!(
                !path.exists(),
                "sandbox should be removed after rollback: {}",
                path.display()
            );
        } else {
            // git may not be available in this test env; just verify no crash.
            let _ = rollback(snap);
        }
        clear_sandbox_state();
    }

    #[test]
    #[serial]
    fn commit_without_sandbox_is_noop() {
        std::env::remove_var("CHUMP_SANDBOX_SPECULATION");
        clear_sandbox_state();
        let snap = fork();
        let res = commit(snap);
        assert_eq!(res, Resolution::Committed);
        clear_sandbox_state();
    }

    #[test]
    #[serial]
    fn rollback_without_sandbox_restores_state_only() {
        std::env::remove_var("CHUMP_SANDBOX_SPECULATION");
        clear_sandbox_state();
        let snap = fork();
        let res = rollback(snap);
        assert_eq!(res, Resolution::RolledBack);
        assert!(speculative_sandbox_root().is_none());
    }

    #[test]
    #[serial]
    fn sandbox_root_returns_none_when_disabled() {
        std::env::remove_var("CHUMP_SANDBOX_SPECULATION");
        clear_sandbox_state();
        // Even if someone set the path directly, sandbox_root should reflect disabled state.
        // (In practice disabled means no fork created one.)
        assert!(speculative_sandbox_root().is_none());
    }
}
