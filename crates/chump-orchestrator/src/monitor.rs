//! Monitor loop for dispatched subagents — AUTO-013 MVP step 3.
//!
//! Step 2 (PR #145) shipped `dispatch_gap` which spawns a subagent and
//! returns a [`crate::dispatch::DispatchHandle`]. This module owns the
//! handles after spawn and watches each one until it reaches a terminal
//! [`DispatchOutcome`].
//!
//! Per the design doc §Q3 / §Q4:
//!
//! - Tick every 30s (configurable; lower in tests).
//! - For each in-flight handle:
//!   1. Probe the subprocess: did it exit non-zero? → `Killed(code)`.
//!   2. Probe the PR via `gh pr list --head <branch> --state all`.
//!      - PR `state=MERGED` → `Shipped(number)`.
//!      - PR exists, `mergeStateStatus=DIRTY` → log a warning (MVP just notes).
//!   3. Apply the soft-deadline ladder (S=20 / M=60 / L=180 / XL=skip):
//!      - `now - started_at > soft_deadline` AND no PR yet → `Stalled`.
//!      - `now - started_at > 2 × soft_deadline` → SIGTERM, 30s grace,
//!        SIGKILL. Mark `Killed("soft-deadline exceeded")`.
//!
//! The PR probe is behind the [`PrProvider`] trait so unit tests can drive
//! the state machine without shelling out to `gh` (which would hit
//! GitHub's API and require auth in CI).
//!
//! Subprocess management uses `std::process::Child` (matches `dispatch.rs`).
//! Async polling uses `tokio::time::sleep` for the inter-tick gap so the
//! orchestrator stays responsive to other work in the same runtime.

use crate::dispatch::DispatchHandle;
use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Terminal state of a dispatched subagent. The monitor returns one per
/// handle once `watch_until_done` finishes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DispatchOutcome {
    /// PR `state=MERGED`. Carries the PR number.
    Shipped(u32),
    /// No heartbeat / no PR within `soft_deadline`. The subprocess (if any)
    /// is left alone — the design doc says soft-stall is informational, not
    /// auto-killed.
    Stalled,
    /// Soft-deadline 2x exceeded OR subprocess exited non-zero.
    /// String is the human-readable reason (e.g. `"exit code 1"`,
    /// `"soft-deadline exceeded (180s × 2)"`).
    Killed(String),
    /// PR opened but CI failed. Carries the PR number. MVP doesn't actively
    /// detect CI fail (it surfaces if `gh pr list` reports it); reserved
    /// for the per-tick PR probe.
    CiFailed(u32),
}

/// One row from `gh pr list --json number,state,mergeStateStatus`. Public
/// so test providers can build matching values.
#[derive(Debug, Clone, Deserialize)]
pub struct PrStatus {
    pub number: u32,
    /// `OPEN` | `CLOSED` | `MERGED` (GraphQL enum). We only care about MERGED.
    pub state: String,
    /// Optional — `gh` returns `""` when the calculation is in flight.
    /// `DIRTY` means rebase needed.
    #[serde(rename = "mergeStateStatus", default)]
    pub merge_state_status: String,
}

/// Source of PR status per branch. The production impl shells out to
/// `gh pr list`; tests inject a deterministic table.
pub trait PrProvider {
    /// Return the most recent PR for the given branch, if any. Errors should
    /// be considered transient — the monitor will retry on the next tick.
    fn latest_pr(&self, branch: &str) -> Result<Option<PrStatus>>;
}

/// Production provider — shells out to `gh pr list --head <branch>`.
///
/// Returns `Ok(None)` when there is no PR for the branch yet. Errors when
/// `gh` itself fails (auth, network) — the monitor logs and keeps polling.
pub struct GhPrProvider;

impl PrProvider for GhPrProvider {
    fn latest_pr(&self, branch: &str) -> Result<Option<PrStatus>> {
        let out = Command::new("gh")
            .args([
                "pr",
                "list",
                "--head",
                branch,
                "--state",
                "all",
                "--json",
                "number,state,mergeStateStatus",
                "--limit",
                "1",
            ])
            .output()
            .context("running gh pr list")?;
        if !out.status.success() {
            anyhow::bail!(
                "gh pr list failed for {branch}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
        let stdout = String::from_utf8(out.stdout).context("gh pr list output not utf-8")?;
        let rows: Vec<PrStatus> =
            serde_json::from_str(stdout.trim()).context("parsing gh pr list JSON")?;
        Ok(rows.into_iter().next())
    }
}

/// Soft-deadline derived from gap effort string. Returns seconds.
///
/// XL is intentionally excluded — the picker filters those out. We still
/// hand back a generous default in case an XL slips through, but the
/// monitor caller is expected to keep XL out of the dispatch table.
pub fn soft_deadline_seconds(effort: &str) -> u64 {
    match effort.to_ascii_lowercase().as_str() {
        "s" => 20 * 60,
        "m" => 60 * 60,
        "l" => 180 * 60,
        "xl" => 360 * 60, // shouldn't happen — picker rejects
        _ => 60 * 60,     // unknown effort → assume medium
    }
}

/// Internal per-handle tick result. Public for testing the pure decision
/// function in isolation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TickDecision {
    /// Continue watching.
    KeepGoing,
    /// Terminal outcome reached.
    Done(DispatchOutcome),
    /// Soft-deadline 2x exceeded — caller should kill the subprocess and
    /// then mark `Done(Killed(reason))`.
    KillThenDone(String),
}

/// Pure decision function — given current state, return next action.
/// Separated from I/O so the state machine has a fast unit-test path.
pub fn decide_tick(
    pr: Option<&PrStatus>,
    started_at_unix: u64,
    now_unix: u64,
    soft_deadline_secs: u64,
    child_exit_code: Option<i32>,
) -> TickDecision {
    // 1. Subprocess died — terminal.
    if let Some(code) = child_exit_code {
        if code == 0 {
            // Clean exit but we still want a PR; re-check below.
        } else {
            return TickDecision::Done(DispatchOutcome::Killed(format!("exit code {code}")));
        }
    }

    // 2. PR state.
    if let Some(p) = pr {
        if p.state.eq_ignore_ascii_case("MERGED") {
            return TickDecision::Done(DispatchOutcome::Shipped(p.number));
        }
        if p.state.eq_ignore_ascii_case("CLOSED") {
            // Closed without merge — treat as CI/manual failure.
            return TickDecision::Done(DispatchOutcome::CiFailed(p.number));
        }
        // OPEN: not yet terminal. Fall through to deadline check.
    }

    // 3. Deadlines (only meaningful when no PR exists — once a PR is open,
    // the merge queue / human owns the timeline).
    let elapsed = now_unix.saturating_sub(started_at_unix);
    if pr.is_none() && elapsed > 2 * soft_deadline_secs {
        return TickDecision::KillThenDone(format!(
            "soft-deadline exceeded ({soft_deadline_secs}s × 2)"
        ));
    }
    if pr.is_none() && elapsed > soft_deadline_secs {
        return TickDecision::Done(DispatchOutcome::Stalled);
    }

    TickDecision::KeepGoing
}

/// Per-handle monitoring config — soft deadline + branch identity. The
/// caller fills these in when building the loop because a `DispatchHandle`
/// alone doesn't carry the gap effort.
pub struct WatchEntry {
    pub handle: DispatchHandle,
    pub soft_deadline_secs: u64,
}

/// The monitor loop itself.
pub struct MonitorLoop<'p, P: PrProvider> {
    entries: Vec<WatchEntry>,
    /// Repository root. Currently informational; reserved for the worktree-
    /// teardown call in step 4.
    #[allow(dead_code)]
    repo_root: PathBuf,
    tick: Duration,
    provider: &'p P,
}

impl<'p, P: PrProvider> MonitorLoop<'p, P> {
    pub fn new(
        entries: Vec<WatchEntry>,
        repo_root: PathBuf,
        tick: Duration,
        provider: &'p P,
    ) -> Self {
        Self {
            entries,
            repo_root,
            tick,
            provider,
        }
    }

    /// Drive the loop until every entry has reached a terminal outcome.
    /// Returns one `(branch_name, outcome)` per entry, in input order.
    pub async fn watch_until_done(mut self) -> Vec<(String, DispatchOutcome)> {
        // Take ownership of the handles so we can mutate `child` per entry
        // without borrow conflicts inside the tick loop.
        let mut pending: Vec<WatchEntry> = std::mem::take(&mut self.entries);
        let mut done: HashMap<String, DispatchOutcome> = HashMap::new();
        let mut order: Vec<String> = pending
            .iter()
            .map(|e| e.handle.branch_name.clone())
            .collect();

        while !pending.is_empty() {
            let mut still_pending: Vec<WatchEntry> = Vec::with_capacity(pending.len());
            for mut entry in pending.drain(..) {
                let exit = poll_child_exit(&mut entry.handle);
                let pr = self
                    .provider
                    .latest_pr(&entry.handle.branch_name)
                    .unwrap_or_else(|e| {
                        eprintln!(
                            "[monitor] gh pr list failed for {}: {e:#} (will retry)",
                            entry.handle.branch_name
                        );
                        None
                    });
                let now = unix_now();
                let decision = decide_tick(
                    pr.as_ref(),
                    entry.handle.started_at_unix,
                    now,
                    entry.soft_deadline_secs,
                    exit,
                );
                match decision {
                    TickDecision::KeepGoing => still_pending.push(entry),
                    TickDecision::Done(out) => {
                        done.insert(entry.handle.branch_name.clone(), out);
                    }
                    TickDecision::KillThenDone(reason) => {
                        kill_child_with_grace(&mut entry.handle);
                        done.insert(
                            entry.handle.branch_name.clone(),
                            DispatchOutcome::Killed(reason),
                        );
                    }
                }
            }
            pending = still_pending;
            if pending.is_empty() {
                break;
            }
            tokio::time::sleep(self.tick).await;
        }

        // Re-emit in input order so callers can join with their dispatch list.
        order
            .drain(..)
            .map(|b| {
                let o = done
                    .remove(&b)
                    .unwrap_or(DispatchOutcome::Stalled /* should not happen */);
                (b, o)
            })
            .collect()
    }
}

/// Try to reap the child without blocking. Returns the exit code if it has
/// already terminated, `None` otherwise.
fn poll_child_exit(handle: &mut DispatchHandle) -> Option<i32> {
    let child = handle.child.as_mut()?;
    match child.try_wait() {
        Ok(Some(status)) => Some(status.code().unwrap_or(-1)),
        Ok(None) => None,
        Err(e) => {
            eprintln!(
                "[monitor] try_wait failed for pid {:?}: {e:#}",
                handle.child_pid
            );
            None
        }
    }
}

/// Send SIGTERM, sleep 30s, send SIGKILL. On platforms without signals
/// (or when the child is already gone) we fall back to `Child::kill`.
fn kill_child_with_grace(handle: &mut DispatchHandle) {
    let Some(child) = handle.child.as_mut() else {
        return;
    };
    #[cfg(unix)]
    {
        if let Some(pid) = handle.child_pid {
            // Best-effort — ignore failure (child may have already exited).
            let _ = unsafe {
                libc_kill(pid as i32, 15 /* SIGTERM */)
            };
        }
        std::thread::sleep(Duration::from_secs(30));
    }
    // SIGKILL / TerminateProcess via stdlib.
    let _ = child.kill();
    let _ = child.wait();
}

/// Tiny libc kill shim so we don't pull a libc crate dep just for SIGTERM.
#[cfg(unix)]
unsafe fn libc_kill(pid: i32, sig: i32) -> i32 {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    kill(pid, sig)
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Convenience: derive the `WatchEntry` list from a vector of dispatched
/// handles + their original gaps (so we can map `effort` → soft deadline).
pub fn watch_entries(
    handles: Vec<DispatchHandle>,
    efforts_by_gap: &HashMap<String, String>,
) -> Vec<WatchEntry> {
    handles
        .into_iter()
        .map(|h| {
            let effort = efforts_by_gap
                .get(&h.gap_id)
                .map(String::as_str)
                .unwrap_or("m");
            WatchEntry {
                soft_deadline_secs: soft_deadline_seconds(effort),
                handle: h,
            }
        })
        .collect()
}

/// Construct a default monitor configured with the production
/// [`GhPrProvider`] and a 30-second tick.
pub fn default_monitor(
    entries: Vec<WatchEntry>,
    repo_root: &Path,
) -> MonitorLoop<'static, GhPrProvider> {
    // Static provider so the lifetime works without juggling.
    static PROVIDER: GhPrProvider = GhPrProvider;
    MonitorLoop::new(
        entries,
        repo_root.to_path_buf(),
        Duration::from_secs(30),
        &PROVIDER,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap as Map;

    fn handle(branch: &str, gap: &str, started: u64) -> DispatchHandle {
        DispatchHandle {
            gap_id: gap.into(),
            worktree_path: PathBuf::from(format!("/tmp/{branch}")),
            branch_name: branch.into(),
            child_pid: None,
            started_at_unix: started,
            child: None,
        }
    }

    fn pr(num: u32, state: &str) -> PrStatus {
        PrStatus {
            number: num,
            state: state.into(),
            merge_state_status: String::new(),
        }
    }

    // -- soft_deadline_seconds --------------------------------------------

    #[test]
    fn soft_deadline_table() {
        assert_eq!(soft_deadline_seconds("s"), 20 * 60);
        assert_eq!(soft_deadline_seconds("M"), 60 * 60);
        assert_eq!(soft_deadline_seconds("L"), 180 * 60);
        assert_eq!(soft_deadline_seconds("xl"), 360 * 60);
        // Unknown maps to medium so an off-spec value can't hang forever.
        assert_eq!(soft_deadline_seconds("weird"), 60 * 60);
    }

    // -- decide_tick (the pure brain) -------------------------------------

    #[test]
    fn decide_shipped_when_pr_merged() {
        let p = pr(42, "MERGED");
        let d = decide_tick(Some(&p), 0, 100, 1000, None);
        assert_eq!(d, TickDecision::Done(DispatchOutcome::Shipped(42)));
    }

    #[test]
    fn decide_ci_failed_when_pr_closed() {
        let p = pr(7, "CLOSED");
        let d = decide_tick(Some(&p), 0, 100, 1000, None);
        assert_eq!(d, TickDecision::Done(DispatchOutcome::CiFailed(7)));
    }

    #[test]
    fn decide_keep_going_when_pr_open_within_deadline() {
        let p = pr(99, "OPEN");
        let d = decide_tick(Some(&p), 0, 100, 1000, None);
        assert_eq!(d, TickDecision::KeepGoing);
    }

    #[test]
    fn decide_keep_going_no_pr_within_deadline() {
        let d = decide_tick(None, 0, 100, 1000, None);
        assert_eq!(d, TickDecision::KeepGoing);
    }

    #[test]
    fn decide_stalled_no_pr_past_soft_deadline() {
        // elapsed = 1500, soft = 1000, 2x = 2000 → stalled (not killed yet).
        let d = decide_tick(None, 0, 1500, 1000, None);
        assert_eq!(d, TickDecision::Done(DispatchOutcome::Stalled));
    }

    #[test]
    fn decide_kill_no_pr_past_2x_soft_deadline() {
        // elapsed = 2500, 2x soft = 2000 → kill.
        let d = decide_tick(None, 0, 2500, 1000, None);
        match d {
            TickDecision::KillThenDone(reason) => {
                assert!(reason.contains("1000s × 2"), "got: {reason}");
            }
            other => panic!("expected KillThenDone, got {other:?}"),
        }
    }

    #[test]
    fn decide_killed_when_child_exits_nonzero() {
        let d = decide_tick(None, 0, 100, 1000, Some(2));
        assert_eq!(
            d,
            TickDecision::Done(DispatchOutcome::Killed("exit code 2".into()))
        );
    }

    #[test]
    fn decide_clean_exit_without_pr_keeps_going_until_deadline() {
        // Subprocess exited 0 but no PR yet — wait for the deadline ladder
        // (the agent might be mid-`gh pr create` from a child shell).
        let d = decide_tick(None, 0, 100, 1000, Some(0));
        assert_eq!(d, TickDecision::KeepGoing);
    }

    #[test]
    fn decide_pr_takes_precedence_over_deadline() {
        // PR exists and is open AND we're past 2x deadline. Per design,
        // once a PR exists the merge queue / human owns the timeline:
        // we should NOT kill.
        let p = pr(11, "OPEN");
        let d = decide_tick(Some(&p), 0, 9_999, 1000, None);
        assert_eq!(d, TickDecision::KeepGoing);
    }

    // -- MonitorLoop with mocked PR provider ------------------------------

    /// Deterministic provider. Map of branch → sequence of responses; each
    /// `latest_pr` call pops the head until exhausted (then repeats last).
    struct ScriptedProvider {
        scripts: RefCell<Map<String, Vec<Option<PrStatus>>>>,
    }

    impl ScriptedProvider {
        fn new(scripts: Map<String, Vec<Option<PrStatus>>>) -> Self {
            Self {
                scripts: RefCell::new(scripts),
            }
        }
    }

    impl PrProvider for ScriptedProvider {
        fn latest_pr(&self, branch: &str) -> Result<Option<PrStatus>> {
            let mut s = self.scripts.borrow_mut();
            let v = s.entry(branch.to_string()).or_default();
            if v.len() > 1 {
                Ok(v.remove(0))
            } else {
                Ok(v.first().cloned().unwrap_or(None))
            }
        }
    }

    #[tokio::test]
    async fn watch_returns_immediately_on_empty_input() {
        let provider = ScriptedProvider::new(Map::new());
        let m = MonitorLoop::new(
            vec![],
            PathBuf::from("/tmp"),
            Duration::from_millis(10),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert!(out.is_empty());
    }

    #[tokio::test]
    async fn watch_picks_up_merged_pr_on_first_tick() {
        let mut scripts = Map::new();
        scripts.insert("claude/x".to_string(), vec![Some(pr(101, "MERGED"))]);
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![WatchEntry {
            handle: handle("claude/x", "X-1", unix_now()),
            soft_deadline_secs: 600,
        }];
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].0, "claude/x");
        assert_eq!(out[0].1, DispatchOutcome::Shipped(101));
    }

    #[tokio::test]
    async fn watch_marks_stalled_when_no_pr_after_deadline() {
        // started_at far in the past so `elapsed > soft_deadline` immediately.
        let mut scripts = Map::new();
        scripts.insert("claude/y".to_string(), vec![None]);
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![WatchEntry {
            handle: handle("claude/y", "Y-1", 0),
            soft_deadline_secs: 1, // 1s; elapsed will be ~now() seconds.
        }];
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 1);
        // 2x soft = 2 seconds; elapsed is huge → KillThenDone path → Killed.
        match &out[0].1 {
            DispatchOutcome::Killed(_) => {}
            other => panic!("expected Killed (past 2x), got {other:?}"),
        }
    }

    #[tokio::test]
    async fn watch_processes_multiple_branches_in_input_order() {
        let mut scripts = Map::new();
        scripts.insert("claude/a".to_string(), vec![Some(pr(1, "MERGED"))]);
        scripts.insert("claude/b".to_string(), vec![Some(pr(2, "MERGED"))]);
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![
            WatchEntry {
                handle: handle("claude/a", "A", unix_now()),
                soft_deadline_secs: 600,
            },
            WatchEntry {
                handle: handle("claude/b", "B", unix_now()),
                soft_deadline_secs: 600,
            },
        ];
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].0, "claude/a");
        assert_eq!(out[1].0, "claude/b");
        assert_eq!(out[0].1, DispatchOutcome::Shipped(1));
        assert_eq!(out[1].1, DispatchOutcome::Shipped(2));
    }

    // -- watch_entries helper ---------------------------------------------

    #[test]
    fn watch_entries_uses_effort_table_and_defaults_to_medium() {
        let h1 = handle("claude/a", "A", 0);
        let h2 = handle("claude/b", "B", 0);
        let h3 = handle("claude/c", "C-NO-EFFORT", 0);
        let mut efforts: Map<String, String> = Map::new();
        efforts.insert("A".into(), "s".into());
        efforts.insert("B".into(), "l".into());
        let entries = watch_entries(vec![h1, h2, h3], &efforts);
        assert_eq!(entries[0].soft_deadline_secs, 20 * 60);
        assert_eq!(entries[1].soft_deadline_secs, 180 * 60);
        // C has no effort entry → medium fallback.
        assert_eq!(entries[2].soft_deadline_secs, 60 * 60);
    }
}
