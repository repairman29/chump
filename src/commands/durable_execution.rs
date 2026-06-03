//! RESILIENT-059: DurableExecutor — Temporal/DBOS-style activity wrapper.
//!
//! A [`DurableExecutor`] wraps a gap-execution session. Each logical step is
//! modelled as a named **activity**: calling `executor.activity("step-name", f)`
//! the first time executes `f`, journals the result, and returns it. On any
//! subsequent call with the same `(gap_id, run_id, step_name)` — including
//! after a process kill and restart — the cached journal value is returned and
//! `f` is **never called again**.
//!
//! # Usage
//!
//! ```rust,ignore
//! // Fresh execution.
//! let exec = DurableExecutor::new("INFRA-1234")?;
//!
//! let count = exec.activity("count-files", || {
//!     Ok(std::fs::read_dir(".")?.count())
//! })?;
//!
//! // If the process is killed here and restarted with resume=true, count
//! // is replayed from the journal and the closure is not called again.
//! let exec2 = DurableExecutor::resume("INFRA-1234")?;
//! let count_again = exec2.activity("count-files", || {
//!     // This closure is never reached on resume.
//!     Ok(0usize)
//! })?;
//! assert_eq!(count, count_again);
//! ```
//!
//! # Activity constraints
//!
//! - The result type `T` must implement `serde::Serialize + serde::DeserializeOwned`.
//! - The closure `f` must be `FnOnce() -> anyhow::Result<T>`.
//! - Activities are identified by `step_name` within `(gap_id, run_id)`. Use
//!   stable names (avoid including loop indices in the name; prefer indexed names
//!   like `"fetch-pr-3"` over dynamic strings derived from runtime data).
//!
//! # Cross-run isolation
//!
//! Results from run N are invisible to run N+1. Each [`DurableExecutor::new`]
//! allocates a fresh `run_id`; [`DurableExecutor::resume`] reattaches to the
//! most recent incomplete run.

use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Serialize};

use super::durable_execution_journal::Journal;

// ── DurableExecutor ──────────────────────────────────────────────────────────

/// An execution context for a single gap run. Thread-safe within a single
/// process (the underlying SQLite connection uses WAL mode + busy_timeout).
pub struct DurableExecutor {
    journal: Journal,
    gap_id: String,
    run_id: u64,
    /// Number of steps replayed from the journal on resume.
    replayed_count: usize,
}

impl DurableExecutor {
    /// Start a **fresh** execution for `gap_id`. Always allocates a new `run_id`.
    ///
    /// Use this when the operator invokes `chump --execute-gap <ID>` for the
    /// first time, or when the operator explicitly wants a clean re-run.
    pub fn new(gap_id: &str) -> Result<Self> {
        let journal = Journal::open().with_context(|| format!("open journal for {gap_id}"))?;
        let run_id = journal.next_run_id(gap_id, false)?;
        Ok(Self {
            journal,
            gap_id: gap_id.to_owned(),
            run_id,
            replayed_count: 0,
        })
    }

    /// **Resume** the most recent incomplete execution for `gap_id`.
    ///
    /// If there is no incomplete run, behaves identically to [`Self::new`].
    /// Emits `kind=durable_journal_resumed` when a prior run is found.
    pub fn resume(gap_id: &str) -> Result<Self> {
        let journal =
            Journal::open().with_context(|| format!("open journal for resume of {gap_id}"))?;
        let run_id = journal.next_run_id(gap_id, true)?;

        // Count already-completed steps so we can emit the resumed event.
        let completed = journal.completed_steps(gap_id, run_id)?;
        let replayed_count = completed.len();

        if replayed_count > 0 {
            journal.emit_resumed(gap_id, run_id, replayed_count);
        }

        Ok(Self {
            journal,
            gap_id: gap_id.to_owned(),
            run_id,
            replayed_count,
        })
    }

    /// Create a `DurableExecutor` backed by an explicit [`Journal`]. Used by
    /// tests to inject a temp-DB journal without touching the production state.db.
    pub fn with_journal(gap_id: &str, journal: Journal, resume: bool) -> Result<Self> {
        let run_id = journal.next_run_id(gap_id, resume)?;
        let replayed_count = if resume {
            journal.completed_steps(gap_id, run_id)?.len()
        } else {
            0
        };
        if resume && replayed_count > 0 {
            journal.emit_resumed(gap_id, run_id, replayed_count);
        }
        Ok(Self {
            journal,
            gap_id: gap_id.to_owned(),
            run_id,
            replayed_count,
        })
    }

    /// The current `run_id`. Useful for logging / telemetry.
    pub fn run_id(&self) -> u64 {
        self.run_id
    }

    /// Number of steps replayed from the journal on this resume. Zero for a
    /// fresh execution.
    pub fn replayed_count(&self) -> usize {
        self.replayed_count
    }

    /// Execute a named activity.
    ///
    /// 1. Check the journal: if `(gap_id, run_id, step_name)` has a completed
    ///    entry, deserialise and return it — `f` is **not called**.
    /// 2. Otherwise: insert an in-flight row, call `f`, persist the result, and
    ///    return it.
    ///
    /// On error from `f`: the in-flight row is left as-is (NULL `completed_at`).
    /// A subsequent resume will skip this step on replay (because it was never
    /// completed) and retry it from scratch.
    pub fn activity<F, T>(&self, step_name: &str, f: F) -> Result<T>
    where
        F: FnOnce() -> Result<T>,
        T: Serialize + DeserializeOwned,
    {
        // ── 1. Cache hit ──────────────────────────────────────────────────────
        if let Some(cached_json) = self
            .journal
            .lookup_completed(&self.gap_id, self.run_id, step_name)
            .with_context(|| format!("journal lookup for step={step_name}"))?
        {
            let value: T = serde_json::from_str(&cached_json)
                .with_context(|| format!("deserialise cached result for step={step_name}"))?;
            return Ok(value);
        }

        // ── 2. Start the step ─────────────────────────────────────────────────
        let step_id = self
            .journal
            .start_step(&self.gap_id, self.run_id, step_name)
            .with_context(|| format!("start_step for step={step_name}"))?;

        // ── 3. Execute ────────────────────────────────────────────────────────
        let result = f();

        // ── 4. Persist on success ─────────────────────────────────────────────
        match result {
            Ok(value) => {
                let json = serde_json::to_string(&value)
                    .with_context(|| format!("serialise result for step={step_name}"))?;
                self.journal
                    .complete_step(step_id, &json)
                    .with_context(|| format!("complete_step for step={step_name}"))?;
                Ok(value)
            }
            Err(e) => {
                // Increment attempt count so we know this step was tried and failed.
                let _ = self.journal.increment_attempt(step_id);
                Err(e)
            }
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::durable_execution_journal::Journal;
    use std::sync::{Arc, Mutex};
    use tempfile::NamedTempFile;

    /// Helper: open an isolated temp-DB journal and disable ambient writes.
    fn temp_exec(gap_id: &str, resume: bool) -> DurableExecutor {
        let f = NamedTempFile::new().unwrap();
        let path = f.path().to_owned();
        std::mem::forget(f);
        unsafe {
            std::env::set_var("CHUMP_DURABLE_AMBIENT_DISABLE", "1");
        }
        let j = Journal::open_at(&path).unwrap();
        DurableExecutor::with_journal(gap_id, j, resume).unwrap()
    }

    /// Helper: open a second executor that shares the same DB file.
    fn reopen_exec(gap_id: &str, db_path: &std::path::Path, resume: bool) -> DurableExecutor {
        let j = Journal::open_at(db_path).unwrap();
        DurableExecutor::with_journal(gap_id, j, resume).unwrap()
    }

    /// Helper: create an executor and return its DB path for later reopen.
    fn temp_exec_with_path(gap_id: &str) -> (DurableExecutor, std::path::PathBuf) {
        let f = NamedTempFile::new().unwrap();
        let path = f.path().to_owned();
        std::mem::forget(f);
        unsafe {
            std::env::set_var("CHUMP_DURABLE_AMBIENT_DISABLE", "1");
        }
        let j = Journal::open_at(&path).unwrap();
        let exec = DurableExecutor::with_journal(gap_id, j, false).unwrap();
        (exec, path)
    }

    // ── Test 1: basic journaling ─────────────────────────────────────────────

    #[test]
    fn basic_three_step_journaling() {
        let exec = temp_exec("TEST-BASIC", false);

        let a: String = exec.activity("step-a", || Ok("alpha".to_string())).unwrap();
        let b: u64 = exec.activity("step-b", || Ok(42u64)).unwrap();
        let c: bool = exec.activity("step-c", || Ok(true)).unwrap();

        assert_eq!(a, "alpha");
        assert_eq!(b, 42);
        assert!(c);

        // Verify journal has 3 completed rows.
        let steps = exec
            .journal
            .completed_steps("TEST-BASIC", exec.run_id())
            .unwrap();
        assert_eq!(steps.len(), 3, "journal must have 3 completed steps");
    }

    // ── Test 3: LLM call dedup (same (gap,run,step) → executes once) ─────────

    #[test]
    fn activity_dedup_same_step_name() {
        let counter = Arc::new(Mutex::new(0u32));

        let (exec, db_path) = temp_exec_with_path("TEST-DEDUP");

        // First call — executes the closure.
        let c2 = counter.clone();
        let _v1: u32 = exec
            .activity("llm-call", move || {
                let mut guard = c2.lock().unwrap();
                *guard += 1;
                Ok(*guard)
            })
            .unwrap();

        // Open a second executor on the SAME DB, same run_id (resume=true).
        let exec2 = reopen_exec("TEST-DEDUP", &db_path, true);

        // Second call — must return cached value, closure must NOT run.
        let c3 = counter.clone();
        let _v2: u32 = exec2
            .activity("llm-call", move || {
                // This should never execute.
                let mut guard = c3.lock().unwrap();
                *guard += 100; // sentinel: if this runs, counter jumps.
                Ok(*guard)
            })
            .unwrap();

        let final_count = *counter.lock().unwrap();
        assert_eq!(
            final_count, 1,
            "closure must execute exactly once; counter={final_count}"
        );
    }

    // ── Test 4: cross-run separation ─────────────────────────────────────────

    #[test]
    fn cross_run_separation() {
        let counter = Arc::new(Mutex::new(0u32));

        let (exec1, db_path) = temp_exec_with_path("TEST-CROSSRUN");

        let c = counter.clone();
        let _: u32 = exec1
            .activity("step-x", move || {
                let mut g = c.lock().unwrap();
                *g += 1;
                Ok(*g)
            })
            .unwrap();

        // Fresh run (resume=false) — must allocate a new run_id.
        let exec2 = reopen_exec("TEST-CROSSRUN", &db_path, false);
        assert_ne!(
            exec1.run_id(),
            exec2.run_id(),
            "fresh run must have distinct run_id"
        );

        let c2 = counter.clone();
        let _: u32 = exec2
            .activity("step-x", move || {
                // This SHOULD execute because run_id is different.
                let mut g = c2.lock().unwrap();
                *g += 1;
                Ok(*g)
            })
            .unwrap();

        let final_count = *counter.lock().unwrap();
        assert_eq!(
            final_count, 2,
            "step-x must execute once per run; counter={final_count}"
        );
    }

    // ── Resume correctness ────────────────────────────────────────────────────

    #[test]
    fn resume_skips_completed_steps() {
        let (exec1, db_path) = temp_exec_with_path("TEST-RESUME");

        // Complete step-a.
        let _: String = exec1
            .activity("step-a", || Ok("done-a".to_string()))
            .unwrap();
        // Leave step-b in-flight (started but not completed) — simulate crash
        // by just not calling activity for it (the row won't exist yet either;
        // the crash is simulated by dropping exec1 before step-b starts).
        drop(exec1);

        // Reopen with resume=true.
        let exec2 = reopen_exec("TEST-RESUME", &db_path, true);
        assert_eq!(exec2.run_id(), 1, "should resume run 1");
        assert_eq!(
            exec2.replayed_count(),
            1,
            "step-a should be counted as replayed"
        );

        // Calling step-a again must return cached value without re-running closure.
        let sentinel = Arc::new(Mutex::new(false));
        let s2 = sentinel.clone();
        let v: String = exec2
            .activity("step-a", move || {
                *s2.lock().unwrap() = true; // sentinel: must not fire
                Ok("re-executed-a".to_string())
            })
            .unwrap();

        assert_eq!(v, "done-a", "must return cached journal value");
        assert!(
            !*sentinel.lock().unwrap(),
            "closure must not execute for replayed step"
        );
    }

    // ── Error path: failed activity leaves row in-flight ─────────────────────

    #[test]
    fn failed_activity_increments_attempt_count() {
        let exec = temp_exec("TEST-ERR", false);
        let result: Result<u32> =
            exec.activity("failing-step", || Err(anyhow::anyhow!("simulated failure")));
        assert!(result.is_err());

        // The step must NOT appear in completed_steps.
        let done = exec
            .journal
            .completed_steps("TEST-ERR", exec.run_id())
            .unwrap();
        assert!(done.is_empty(), "failed step must not appear as completed");
    }
}
