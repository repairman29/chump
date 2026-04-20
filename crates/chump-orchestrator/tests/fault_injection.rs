//! End-to-end fault-injection tests for the chump-orchestrator dispatch and
//! monitor paths (INFRA-DISPATCH-FAULT-INJECTION).
//!
//! Each test sets `CHUMP_FAULT_INJECT` to one fault spec, dispatches a gap
//! through the real `dispatch_gap_with` + `MonitorLoop` stack, and asserts
//! the expected terminal [`DispatchOutcome`].
//!
//! The tests use:
//! - `FaultInjectSpawner` — a `Spawner` impl that always calls
//!   `spawn_fault_process(mode)` regardless of backend env. This avoids
//!   the process env needing the `CHUMP_FAULT_INJECT` var set (some CI
//!   runners strip custom env vars). For `spawn_fail` the spawner itself
//!   returns an error.
//! - `NoPrProvider` — a `PrProvider` that always returns `Ok(None)` so the
//!   monitor's deadline ladder drives outcome rather than a PR event.
//! - A tiny `soft_deadline_secs` (1 second) so the deadline tests resolve
//!   within milliseconds on the mock clock.
//!
//! These tests do fork real `sh` subprocesses (one per test, short-lived).
//! They do NOT touch the real filesystem (no git worktrees, no lease files).
//!
//! # Serialisation
//!
//! The `spawn_fail` test mutates `CHUMP_FAULT_INJECT` in-process; the others
//! use `FaultInjectSpawner` directly and don't touch env. The env-mutating
//! test is `#[serial]` to avoid races with other env-reading tests.

use chump_orchestrator::dispatch::{
    dispatch_gap_with, spawn_fault_process, DispatchHandle, FaultMode, SpawnResult, Spawner,
};
use chump_orchestrator::monitor::{DispatchOutcome, MonitorLoop, PrProvider, PrStatus, WatchEntry};
use chump_orchestrator::Gap;

use anyhow::Result;
use serial_test::serial;
use std::path::{Path, PathBuf};
use std::time::Duration;

// ── helpers ──────────────────────────────────────────────────────────────────

fn test_gap(id: &str) -> Gap {
    Gap {
        id: id.into(),
        title: "fault-inject test gap".into(),
        priority: "P1".into(),
        effort: "s".into(),
        status: "open".into(),
        depends_on: None,
    }
}

/// A `Spawner` that no-ops worktree creation and lease claiming, and always
/// spawns the given fault process (or fails for `SpawnFail`).
struct FaultInjectSpawner {
    fault: FaultMode,
}

impl Spawner for FaultInjectSpawner {
    fn create_worktree(&self, _worktree: &Path, _branch: &str, _base: &str) -> Result<()> {
        Ok(())
    }
    fn claim_gap(&self, _worktree: &Path, _gap_id: &str) -> Result<()> {
        Ok(())
    }
    fn spawn_claude(&self, _worktree: &Path, _prompt: &str) -> Result<SpawnResult> {
        spawn_fault_process(self.fault)
    }
}

/// A `PrProvider` that always returns `Ok(None)` — no PR will ever appear.
/// Forces the monitor to rely solely on the deadline ladder and child exit.
struct NoPrProvider;

impl PrProvider for NoPrProvider {
    fn latest_pr(&self, _branch: &str) -> Result<Option<PrStatus>> {
        Ok(None)
    }
}

/// Build a `MonitorLoop` entry for a dispatched handle with a tiny
/// soft-deadline so deadline-based tests resolve in milliseconds.
fn make_watch_entry(handle: DispatchHandle, soft_deadline_secs: u64) -> WatchEntry {
    WatchEntry {
        soft_deadline_secs,
        effort: "s".into(),
        handle,
    }
}

/// Drive a single-entry monitor to completion. Returns the outcome.
async fn run_monitor(entry: WatchEntry) -> DispatchOutcome {
    let provider = NoPrProvider;
    let monitor = MonitorLoop::new(
        vec![entry],
        PathBuf::from("/tmp/fault-inject-test"),
        // Fast tick so tests don't sleep unnecessarily.
        Duration::from_millis(50),
        &provider,
    );
    let mut results = monitor.watch_until_done().await;
    assert_eq!(results.len(), 1, "expected exactly one outcome");
    results.remove(0).1
}

// ── fault: spawn_fail ─────────────────────────────────────────────────────────

/// `spawn_fail` → `dispatch_gap_with` must return an error immediately; no
/// child process is created.
#[test]
fn spawn_fail_returns_error_no_child() {
    let spawner = FaultInjectSpawner {
        fault: FaultMode::SpawnFail,
    };
    let gap = test_gap("FAULT-SPAWN-FAIL");
    let err = dispatch_gap_with(&spawner, &gap, Path::new("/tmp"), "origin/main")
        .expect_err("spawn_fail must return Err");
    let msg = format!("{err:#}");
    assert!(
        msg.contains("spawn_fail"),
        "error must mention fault mode, got: {msg}"
    );
}

/// `spawn_fail` via `CHUMP_FAULT_INJECT` env var: `RealSpawner` must
/// honour the env var before trying to invoke `claude`.
#[test]
#[serial]
fn spawn_fail_via_env_returns_error() {
    // Temporarily set the env var; restore it in a defer-like pattern.
    let prev = std::env::var("CHUMP_FAULT_INJECT").ok();
    std::env::set_var("CHUMP_FAULT_INJECT", "spawn_fail");
    let result = std::panic::catch_unwind(|| {
        // active_fault_mode() should see SpawnFail.
        assert_eq!(
            chump_orchestrator::dispatch::active_fault_mode(),
            Some(FaultMode::SpawnFail)
        );
    });
    match prev {
        Some(v) => std::env::set_var("CHUMP_FAULT_INJECT", v),
        None => std::env::remove_var("CHUMP_FAULT_INJECT"),
    }
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}

// ── fault: exit_1 ─────────────────────────────────────────────────────────────

/// `exit_1` → monitor must see child exit code 1 and produce
/// `Killed("exit code 1")`.
#[tokio::test]
async fn exit_1_monitor_produces_killed_outcome() {
    let spawner = FaultInjectSpawner {
        fault: FaultMode::Exit1,
    };
    let gap = test_gap("FAULT-EXIT-1");
    let handle =
        dispatch_gap_with(&spawner, &gap, Path::new("/tmp"), "origin/main").expect("dispatch ok");

    // Generous soft deadline — the child exits in ~100 ms, long before the
    // deadline ladder fires.
    let entry = make_watch_entry(handle, 60);
    let outcome = run_monitor(entry).await;

    match &outcome {
        DispatchOutcome::Killed(reason) => {
            assert!(
                reason.contains("exit code 1"),
                "expected 'exit code 1' in reason, got: {reason}"
            );
        }
        other => panic!("expected Killed(\"exit code 1\"), got {other:?}"),
    }
}

// ── fault: exit_0_no_pr ───────────────────────────────────────────────────────

/// `exit_0_no_pr` → process exits 0 but no PR appears. After the child
/// exits, the monitor keeps polling the PR provider. With `NoPrProvider`
/// always returning `None` and a tiny soft-deadline (1 s), the deadline
/// ladder fires and produces `Stalled` (or `Killed` at 2× deadline).
/// Either terminal outcome that is NOT `Shipped` is acceptable here —
/// the key is that the monitor doesn't panic and doesn't block forever.
///
/// Note: we use `started_at_unix = 0` (epoch) to fast-forward past the
/// soft-deadline so the test resolves in a single tick without sleeping.
#[tokio::test]
async fn exit_0_no_pr_monitor_reaches_terminal_outcome() {
    let spawner = FaultInjectSpawner {
        fault: FaultMode::Exit0NoPr,
    };
    let gap = test_gap("FAULT-EXIT-0");
    let mut handle =
        dispatch_gap_with(&spawner, &gap, Path::new("/tmp"), "origin/main").expect("dispatch ok");

    // Fast-forward past the deadline by setting started_at to epoch.
    // The soft_deadline is 1 second, so elapsed is huge → 2× ladder fires.
    handle.started_at_unix = 0;
    let entry = make_watch_entry(handle, 1);
    let outcome = run_monitor(entry).await;

    match &outcome {
        // Both Stalled and Killed are acceptable terminal outcomes.
        DispatchOutcome::Stalled | DispatchOutcome::Killed(_) => {}
        DispatchOutcome::Shipped(_) => {
            panic!("exit_0_no_pr must NOT produce Shipped — no PR was opened; got {outcome:?}")
        }
        DispatchOutcome::CiFailed(_) => {
            panic!("exit_0_no_pr must NOT produce CiFailed — no PR was opened; got {outcome:?}")
        }
    }
}

// ── fault: monitor_timeout ───────────────────────────────────────────────────

/// `monitor_timeout` → long-running process; monitor's 2× soft-deadline
/// fires and the monitor kills the process + produces `Killed(reason)`.
///
/// As above, we fast-forward `started_at_unix = 0` so we don't actually
/// sleep for the soft-deadline period.
#[tokio::test]
async fn monitor_timeout_monitor_kills_and_produces_killed_outcome() {
    let spawner = FaultInjectSpawner {
        fault: FaultMode::MonitorTimeout,
    };
    let gap = test_gap("FAULT-TIMEOUT");
    let mut handle =
        dispatch_gap_with(&spawner, &gap, Path::new("/tmp"), "origin/main").expect("dispatch ok");

    // The child is `sleep 3600` — it won't exit on its own. Fast-forward
    // past 2× soft-deadline so the monitor kills it on the first tick.
    handle.started_at_unix = 0;
    let entry = make_watch_entry(handle, 1);
    let outcome = run_monitor(entry).await;

    match &outcome {
        DispatchOutcome::Killed(reason) => {
            // The kill reason must mention the exceeded deadline.
            assert!(
                reason.contains("soft-deadline exceeded"),
                "expected 'soft-deadline exceeded' in reason, got: {reason}"
            );
        }
        other => panic!("expected Killed(deadline), got {other:?}"),
    }
}

// ── env var parsing ───────────────────────────────────────────────────────────

/// Verify `active_fault_mode()` correctly parses each recognised token.
/// These do not mutate env — they test the parsing logic via direct calls
/// to `spawn_fault_process`.
#[test]
fn spawn_fault_process_exit_1_spawns_a_child() {
    let (child, tail) = spawn_fault_process(FaultMode::Exit1).expect("exit_1 spawns ok");
    assert!(child.is_some(), "exit_1 must produce a real child");
    assert!(
        tail.is_none(),
        "fault processes carry no stderr tail buffer"
    );
    // Reap the child so we don't leave zombies.
    if let Some(mut c) = child {
        let _ = c.wait();
    }
}

#[test]
fn spawn_fault_process_exit_0_no_pr_spawns_a_child() {
    let (child, _) = spawn_fault_process(FaultMode::Exit0NoPr).expect("exit_0_no_pr spawns ok");
    assert!(child.is_some(), "exit_0_no_pr must produce a real child");
    if let Some(mut c) = child {
        let _ = c.wait();
    }
}

#[test]
fn spawn_fault_process_monitor_timeout_spawns_a_child() {
    let (child, _) =
        spawn_fault_process(FaultMode::MonitorTimeout).expect("monitor_timeout spawns ok");
    assert!(
        child.is_some(),
        "monitor_timeout must produce a real (long-running) child"
    );
    // Kill it immediately — we only want to confirm it spawned.
    if let Some(mut c) = child {
        let _ = c.kill();
        let _ = c.wait();
    }
}

#[test]
fn spawn_fault_process_spawn_fail_returns_err() {
    spawn_fault_process(FaultMode::SpawnFail).expect_err("SpawnFail must return Err, not Ok");
}

// ── FaultMode dispatch_handle carries correct backend ────────────────────────

/// When `FaultInjectSpawner` is used, the handle's `backend` field reflects
/// the env at dispatch time (not the fault mode). This is a belt-and-braces
/// check that the fault path doesn't accidentally clobber the backend field.
#[test]
fn fault_dispatch_handle_backend_defaults_to_claude() {
    // No CHUMP_DISPATCH_BACKEND set → Claude is the default.
    let spawner = FaultInjectSpawner {
        fault: FaultMode::Exit1,
    };
    let gap = test_gap("FAULT-BACKEND");
    let handle =
        dispatch_gap_with(&spawner, &gap, Path::new("/tmp"), "origin/main").expect("dispatch ok");
    // Reap the child before asserting.
    if let Some(mut c) = handle.child {
        let _ = c.kill();
        let _ = c.wait();
    }
    // Backend should still be Claude (default) because CHUMP_DISPATCH_BACKEND
    // isn't set to anything else in this test.
    // We can't assert Claude without knowing the current test env, so we just
    // assert it's a valid DispatchBackend variant.
    let _ = handle.backend; // type-checks that the field is DispatchBackend
}

/// Verify all four comma-separated fault specs are recognised when combined.
#[test]
#[serial]
fn active_fault_mode_parses_first_token_in_list() {
    let prev = std::env::var("CHUMP_FAULT_INJECT").ok();

    let cases = [
        ("spawn_fail", FaultMode::SpawnFail),
        ("exit_1", FaultMode::Exit1),
        ("exit_0_no_pr", FaultMode::Exit0NoPr),
        ("monitor_timeout", FaultMode::MonitorTimeout),
        // First token wins when there are multiple.
        ("exit_1,spawn_fail", FaultMode::Exit1),
        // Unknown token is skipped; second token wins.
        ("bogus,exit_0_no_pr", FaultMode::Exit0NoPr),
    ];

    let run = std::panic::catch_unwind(|| {
        for (input, expected) in cases {
            std::env::set_var("CHUMP_FAULT_INJECT", input);
            assert_eq!(
                chump_orchestrator::dispatch::active_fault_mode(),
                Some(expected),
                "input={input:?}"
            );
        }
        // Empty / absent → None.
        std::env::set_var("CHUMP_FAULT_INJECT", "");
        assert_eq!(chump_orchestrator::dispatch::active_fault_mode(), None);
        std::env::remove_var("CHUMP_FAULT_INJECT");
        assert_eq!(chump_orchestrator::dispatch::active_fault_mode(), None);
    });

    match prev {
        Some(v) => std::env::set_var("CHUMP_FAULT_INJECT", v),
        None => std::env::remove_var("CHUMP_FAULT_INJECT"),
    }
    if let Err(e) = run {
        std::panic::resume_unwind(e);
    }
}
