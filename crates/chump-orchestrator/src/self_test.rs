//! AUTO-013 step 5 — synthetic end-to-end harness.
//!
//! `run_self_test` drives the full orchestrator pipeline against the
//! 4-gap synthetic backlog at `docs/test-fixtures/synthetic-backlog.yaml`
//! using injected mocks for both the subprocess spawner and the PR
//! provider. No real `claude` CLI invocation, no GitHub API calls, no
//! linked worktrees — pure in-process loop exercise.
//!
//! Two callers share this module:
//!   - `chump-orchestrator --self-test` (the CLI smoke a human can run
//!     manually to verify the orchestrator loop is healthy).
//!   - `crates/chump-orchestrator/tests/e2e_smoke.rs` (the cargo-test
//!     gating the same flow in CI).
//!
//! Acceptance contract:
//!   - 4 dummy files appear under `<scratch>/synth-test/<GAP-ID>` (one per gap).
//!   - 4 reflection rows captured by the in-memory writer, one per gap,
//!     all with `outcome = "shipped"`.
//!   - Wall time well under 10 seconds (the monitor uses millisecond ticks
//!     for tests).

use crate::dispatch::{dispatch_gap_with, DispatchHandle, SpawnResult, Spawner};
use crate::monitor::{DispatchOutcome, MonitorLoop, PrProvider, PrStatus, WatchEntry};
use crate::reflect::{DispatchReflection, MemoryReflectionWriter, ReflectionWriter};
use crate::{load_gaps, pickable_gaps, Gap};
use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// One row in the self-test result summary.
#[derive(Debug, Clone)]
pub struct SelfTestRow {
    pub gap_id: String,
    pub branch: String,
    pub outcome: DispatchOutcome,
}

/// Aggregate result of [`run_self_test`].
#[derive(Debug)]
pub struct SelfTestReport {
    pub rows: Vec<SelfTestRow>,
    pub reflections: Vec<DispatchReflection>,
    pub dummy_files: Vec<PathBuf>,
    pub elapsed: Duration,
    /// Where the dummy files were dropped (one per gap).
    pub scratch_dir: PathBuf,
}

impl SelfTestReport {
    /// All gaps shipped, all dummy files written, one reflection per gap.
    pub fn passed(&self) -> bool {
        let n = self.rows.len();
        n > 0
            && self
                .rows
                .iter()
                .all(|r| matches!(r.outcome, DispatchOutcome::Shipped(_)))
            && self.reflections.len() == n
            && self.dummy_files.len() == n
            && self.dummy_files.iter().all(|p| p.exists())
    }
}

/// Test spawner: doesn't fork `claude`, just `touch`es the dummy file for
/// the gap and "succeeds". The dummy file is the proof the dispatcher reached
/// the spawn step for this gap.
pub struct TestSpawner {
    /// Where dummy files land (one per gap).
    scratch_dir: PathBuf,
}

impl TestSpawner {
    pub fn new(scratch_dir: PathBuf) -> Self {
        Self { scratch_dir }
    }
}

impl Spawner for TestSpawner {
    fn create_worktree(&self, _worktree: &Path, _branch: &str, _base: &str) -> Result<()> {
        // No-op: the test runs entirely in-process; we never make real
        // git worktrees. Returning Ok lets the dispatch flow proceed
        // through claim → spawn.
        Ok(())
    }

    fn claim_gap(&self, _worktree: &Path, _gap_id: &str) -> Result<()> {
        // No-op: lease writes are out of scope for the synthetic loop.
        Ok(())
    }

    fn spawn_claude(&self, worktree: &Path, _prompt: &str) -> Result<SpawnResult> {
        // The "subagent" is just: touch the dummy file. No process is
        // forked; we return (None, None) so the monitor's poll_child_exit
        // returns None and the PR provider drives termination.
        std::fs::create_dir_all(&self.scratch_dir).with_context(|| {
            format!(
                "creating scratch dir {} for self-test",
                self.scratch_dir.display()
            )
        })?;
        // Derive the gap id from the worktree path slug (last component
        // matches `dispatch_paths` lowercased).
        let slug = worktree
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown");
        let dummy = self.scratch_dir.join(slug.to_ascii_uppercase());
        std::fs::write(&dummy, b"synthetic-shipped\n")
            .with_context(|| format!("writing dummy file {} for self-test", dummy.display()))?;
        Ok((None, None))
    }
}

/// PR provider that returns `Shipped(N)` immediately for every known branch.
/// `next_pr_number` increments per branch so each gap gets a unique PR #.
pub struct InstantMergedPrProvider {
    next: std::sync::atomic::AtomicU32,
    table: std::sync::Mutex<HashMap<String, u32>>,
}

impl InstantMergedPrProvider {
    pub fn new(start: u32) -> Self {
        Self {
            next: std::sync::atomic::AtomicU32::new(start),
            table: std::sync::Mutex::new(HashMap::new()),
        }
    }
}

impl PrProvider for InstantMergedPrProvider {
    fn latest_pr(&self, branch: &str) -> Result<Option<PrStatus>> {
        let mut t = self
            .table
            .lock()
            .map_err(|e| anyhow::anyhow!("pr provider lock poisoned: {e}"))?;
        let n = *t
            .entry(branch.to_string())
            .or_insert_with(|| self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        Ok(Some(PrStatus {
            number: n,
            state: "MERGED".into(),
            merge_state_status: String::new(),
        }))
    }
}

/// Drive the full orchestrator pipeline against the synthetic backlog.
///
/// `backlog_path` should point at `docs/test-fixtures/synthetic-backlog.yaml`
/// (or any equivalent fixture). `scratch_dir` is where the test spawner
/// drops dummy files. `max_parallel` caps how many gaps the picker hands
/// the dispatcher per call (the loop calls the picker repeatedly until
/// the backlog drains).
pub fn run_self_test(
    backlog_path: &Path,
    scratch_dir: PathBuf,
    max_parallel: usize,
) -> Result<SelfTestReport> {
    let started = Instant::now();
    let _ = std::fs::remove_dir_all(&scratch_dir); // clean slate
    std::fs::create_dir_all(&scratch_dir)
        .with_context(|| format!("creating scratch dir {}", scratch_dir.display()))?;

    let all_gaps = load_gaps(backlog_path)
        .with_context(|| format!("loading synthetic backlog at {}", backlog_path.display()))?;
    if all_gaps.is_empty() {
        bail!("synthetic backlog at {} is empty", backlog_path.display());
    }

    let spawner = TestSpawner::new(scratch_dir.clone());
    let provider = InstantMergedPrProvider::new(1000);
    let writer = Arc::new(MemoryReflectionWriter::new());

    // Track gaps that have shipped so the picker advances each round.
    let mut shipped: std::collections::HashSet<String> = std::collections::HashSet::new();
    // For the picker's "done" filter we need a HashSet of done IDs that
    // includes anything pre-marked done in the fixture (none in the synthetic
    // case) PLUS anything we shipped this run.
    let mut all_rows: Vec<SelfTestRow> = Vec::new();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .context("building tokio runtime for self-test")?;

    // Cap iterations defensively so a bug can't hang CI forever. Four gaps
    // at max_parallel=2 needs 2 rounds; 8 is generous slack.
    let max_rounds = all_gaps.len() + 4;
    for round in 0..max_rounds {
        // Build the "done" set for this round = pre-existing dones + shipped.
        let mut done: std::collections::HashSet<String> = all_gaps
            .iter()
            .filter(|g| g.status == "done")
            .map(|g| g.id.clone())
            .collect();
        done.extend(shipped.iter().cloned());

        // Filter out anything we've already shipped from the open pool.
        let still_open: Vec<Gap> = all_gaps
            .iter()
            .filter(|g| !shipped.contains(&g.id))
            .cloned()
            .collect();
        let picked: Vec<&Gap> = pickable_gaps(&still_open, max_parallel, &done);
        if picked.is_empty() {
            break;
        }

        let mut handles: Vec<DispatchHandle> = Vec::with_capacity(picked.len());
        let mut efforts: HashMap<String, String> = HashMap::new();
        for gap in &picked {
            efforts.insert(gap.id.clone(), gap.effort.clone());
            let h = dispatch_gap_with(&spawner, gap, Path::new("/tmp/synth-repo"), "origin/main")
                .with_context(|| format!("dispatching {}", gap.id))?;
            handles.push(h);
        }

        let entries: Vec<WatchEntry> = handles
            .into_iter()
            .map(|h| {
                let effort = efforts
                    .get(&h.gap_id)
                    .cloned()
                    .unwrap_or_else(|| "m".into());
                WatchEntry {
                    soft_deadline_secs: 60,
                    handle: h,
                    effort,
                }
            })
            .collect();

        struct ArcAdapter(Arc<MemoryReflectionWriter>);
        impl ReflectionWriter for ArcAdapter {
            fn write(&self, r: &DispatchReflection) -> Result<()> {
                self.0.write(r)
            }
        }
        let monitor = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp/synth-repo"),
            Duration::from_millis(2),
            &provider,
        )
        .with_reflection_writer(Box::new(ArcAdapter(Arc::clone(&writer))));

        let outcomes = runtime.block_on(monitor.watch_until_done());
        for (branch, outcome) in outcomes {
            // Recover gap_id from branch name: branches are `claude/<slug>`
            // and slug = lowercase(gap_id with _ → -).
            let slug = branch.trim_start_matches("claude/");
            let gap_id = picked
                .iter()
                .find(|g| g.id.to_ascii_lowercase().replace('_', "-") == slug)
                .map(|g| g.id.clone())
                .unwrap_or_else(|| slug.to_ascii_uppercase());
            if let DispatchOutcome::Shipped(_) = outcome {
                shipped.insert(gap_id.clone());
            }
            all_rows.push(SelfTestRow {
                gap_id,
                branch,
                outcome,
            });
        }
        let _ = round; // reserved for telemetry
    }

    // Collect the dummy files we actually wrote.
    let dummy_files: Vec<PathBuf> = std::fs::read_dir(&scratch_dir)
        .with_context(|| format!("reading scratch dir {}", scratch_dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .collect();

    Ok(SelfTestReport {
        rows: all_rows,
        reflections: writer.snapshot(),
        dummy_files,
        elapsed: started.elapsed(),
        scratch_dir,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|p| p.parent())
            .expect("workspace root")
            .join("docs/test-fixtures/synthetic-backlog.yaml")
    }

    fn unique_scratch(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "chump-self-test-{label}-{pid}-{nanos}",
            pid = std::process::id(),
            nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn self_test_drains_synthetic_backlog() {
        let backlog = fixture_path();
        if !backlog.exists() {
            panic!("missing fixture at {}", backlog.display());
        }
        let scratch = unique_scratch("unit");
        let report = run_self_test(&backlog, scratch.clone(), 2).expect("self-test runs clean");
        assert!(report.passed(), "self-test report failed: {report:?}");
        assert_eq!(report.rows.len(), 4, "expected 4 outcomes");
        assert_eq!(report.reflections.len(), 4, "expected 4 reflections");
        assert_eq!(report.dummy_files.len(), 4, "expected 4 dummy files");
        assert!(
            report.elapsed < Duration::from_secs(10),
            "self-test wall time {:?} exceeded 10s budget",
            report.elapsed
        );
        let _ = std::fs::remove_dir_all(&scratch);
    }
}
