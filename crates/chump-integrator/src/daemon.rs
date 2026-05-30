//! Integration daemon — lifecycle orchestrator.
//!
//! Runs a polling loop; each iteration:
//!
//! 1. **CLAIM** — lock the integration slot in NATS KV (atomic CAS).  Falls
//!    back to an advisory file lock when NATS is unavailable.
//!    1b. **SAMPLING** — deterministic hash of `cycle_id` decides live vs dry-run
//!        (Phase 2 gate, INFRA-2139). Emits `cycle_sampling_decision`.
//! 2. **SELECT** — call `cycle::select::select_candidates` against the
//!    NATS work-board (state.db fallback when NATS absent).
//! 3. **POLICY** — apply `policy::evaluate`; skip if below volume threshold.
//! 4. **MERGE** — call `cycle::merge_branch::build_integration_branch`.
//! 5. **PREFLIGHT** — shell out to `chump preflight` or
//!    `bash scripts/dev/cross-build-linux.sh`.
//! 6. **DECISION** — LIVE cycles push + create PR + auto-merge via `gh`;
//!    dry-run cycles log manifest + emit `integration_cycle_dry_run_completed`.
//!
//! ## LIVE-mode safety rails (SCALE-A, INFRA-2130)
//!
//! Before any cycle runs in LIVE mode (`dry_run = false`), the daemon checks:
//!
//! 1. **Trunk-RED gate** — reads `.chump-locks/trunk-red-detector-state.json`.
//!    If `is_red = true`, emits `integration_trunk_red_hold` and skips.
//! 2. **Batch cap** — candidates capped at `config.batch_max_live` (default 5)
//!    in addition to the general `max_batch`. Conservative v1 starting point.
//! 3. **`do-not-batch` label** — candidates with the configured label are
//!    excluded before the batch is assembled.
//! 4. **Circuit breaker** — on LIVE merge/push failure, emits
//!    `integration_cycle_failed`, rolls back the integration branch, and sets
//!    `circuit_broken = true` so the next cycle runs as dry-run.
//!
//! Emits ambient events at each step boundary:
//!
//! | Step | kind |
//! |---|---|
//! | cycle starts | `integration_cycle_started` |
//! | trunk-RED hold | `integration_trunk_red_hold` |
//! | sampling gate | `cycle_sampling_decision` |
//! | candidates selected | `integration_candidates_selected` |
//! | per-candidate merge | `integration_branch_merged` |
//! | preflight starts | `integration_preflight_started` |
//! | preflight fails | `integration_preflight_failed` |
//! | LIVE ship complete | `integration_cycle_completed` |
//! | LIVE ship failure | `integration_cycle_failed` |
//! | dry-run skip | `integration_dry_run_skip` |
//! | dry-run complete | `integration_cycle_dry_run_completed` |
//! | merge conflict | `integration_merge_conflict` |

use anyhow::{Context, Result};
use chrono::Utc;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;

use crate::config::IntegratorConfig;
use crate::cycle::merge_branch::build_integration_branch;
use crate::cycle::select::{select_candidates, StateDbWorkBoard};
use crate::cycle::CycleManifest;
use crate::policy::{evaluate, PolicyDecision};
use crate::sampling::sampling_decision;

use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_gap_store::GapFieldUpdate;

/// Integration slot key in the NATS KV `chump_gaps` bucket.
const INTEGRATION_SLOT_KEY: &str = "integration_slot";

/// Path to the trunk-RED detector state file (RESILIENT-050).
const TRUNK_RED_STATE_FILE: &str = ".chump-locks/trunk-red-detector-state.json";

/// The daemon polls the work-board and fires integration cycles.
pub struct IntegratorDaemon {
    pub config: IntegratorConfig,
    /// Path to the repo root (used for git operations).
    pub repo_root: PathBuf,
    /// Path to dry-run log file. Default: `~/.chump/integrator-dry-run.log`.
    pub dry_run_log: PathBuf,
    /// Optional chump-coord client (None when NATS unavailable).
    /// Wrapped in Arc so the Drop guard can hold a cheap clone.
    pub coord: Option<Arc<chump_coord::CoordClient>>,
    /// Circuit breaker: set to true when a LIVE cycle fails.
    /// The next cycle runs as dry-run regardless of config; resets on success.
    circuit_broken: Arc<AtomicBool>,
}

impl IntegratorDaemon {
    /// Create a daemon with defaults derived from env + repo root discovery.
    pub async fn new(repo_root: PathBuf) -> Result<Self> {
        let config = IntegratorConfig::from_env();
        let dry_run_log = Self::default_dry_run_log();
        let coord = chump_coord::CoordClient::connect_or_skip()
            .await
            .map(Arc::new);
        Ok(Self {
            config,
            repo_root,
            dry_run_log,
            coord,
            circuit_broken: Arc::new(AtomicBool::new(false)),
        })
    }

    fn default_dry_run_log() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join(".chump")
            .join("integrator-dry-run.log")
    }

    /// Run the daemon poll loop indefinitely.
    ///
    /// Each iteration fires one integration cycle attempt, then sleeps for
    /// `CHUMP_INTEGRATOR_POLL_S` seconds.
    pub async fn run(&self) -> Result<()> {
        eprintln!(
            "[integrator] starting (dry_run={}, poll={}s, volume_threshold={}, batch_max_live={})",
            self.config.dry_run,
            self.config.poll_interval.as_secs(),
            self.config.volume_threshold,
            self.config.batch_max_live,
        );

        loop {
            if let Err(e) = self.run_cycle().await {
                eprintln!("[integrator] cycle error: {e:#}");
            }
            tokio::time::sleep(self.config.poll_interval).await;
        }
    }

    /// Run one integration cycle. Returns Ok(()) even when the cycle is
    /// skipped; only hard errors (NATS unavailable and state.db unreadable)
    /// propagate as Err.
    pub async fn run_cycle(&self) -> Result<()> {
        let cycle_id = short_uuid();

        // ── Step 0: LIVE-mode safety rails ────────────────────────────────
        // Determine whether this cycle runs LIVE before claiming the slot.
        // Circuit breaker: if the last LIVE cycle failed, force dry-run.
        let circuit_broken = self.circuit_broken.load(Ordering::SeqCst);
        let config_dry_run = self.config.dry_run || circuit_broken;

        if circuit_broken && !self.config.dry_run {
            eprintln!("[integrator] circuit breaker active — forcing dry-run for cycle {cycle_id}");
            emit_event(
                "integration_dry_run_skip",
                &[("cycle_id", &cycle_id), ("reason", "circuit_breaker")],
            );
        }

        // Trunk-RED gate: only relevant when we might go LIVE.
        if !config_dry_run && self.is_trunk_red() {
            eprintln!("[integrator] trunk is RED — holding LIVE cycle {cycle_id}");
            emit_event("integration_trunk_red_hold", &[("cycle_id", &cycle_id)]);
            return Ok(());
        }

        // ── Step 1: CLAIM ────────────────────────────────────────────────
        let claimed = self.try_claim_integration_slot(&cycle_id).await;
        if !claimed {
            eprintln!("[integrator] another cycle is active — skipping");
            return Ok(());
        }

        let _slot_guard = IntegrationSlotGuard {
            coord: self.coord.clone(),
        };

        emit_event("integration_cycle_started", &[("cycle_id", &cycle_id)]);

        // ── Step 1b: SAMPLING ─────────────────────────────────────────────
        // Deterministic hash of cycle_id decides live vs dry-run for this
        // cycle. `config_dry_run=true` always overrides to DRY-RUN regardless
        // of sampling_pct. This gate is the Phase 2 knob.
        let (sample_decision, sample_roll) = sampling_decision(&cycle_id, self.config.sampling_pct);

        let cycle_is_live = !config_dry_run && sample_decision.is_live();

        emit_event(
            "cycle_sampling_decision",
            &[
                ("cycle_id", &cycle_id),
                ("roll", &sample_roll.to_string()),
                ("threshold", &self.config.sampling_pct.to_string()),
                ("decision", sample_decision.as_str()),
                ("dry_run_override", &config_dry_run.to_string()),
                ("cycle_is_live", &cycle_is_live.to_string()),
            ],
        );
        eprintln!(
            "[integrator] sampling: roll={} threshold={} decision={} live={}",
            sample_roll,
            self.config.sampling_pct,
            sample_decision.as_str(),
            cycle_is_live,
        );

        // ── Step 2: SELECT ────────────────────────────────────────────────
        let all_candidates = self.select_candidates().await?;

        // Apply LIVE-mode filters: do-not-batch label exclusion + batch cap.
        let candidates = if cycle_is_live {
            let filtered: Vec<_> = all_candidates
                .into_iter()
                .filter(|c| !self.has_do_not_batch_label(c))
                .collect();
            // Cap at batch_max_live (conservative v1 limit).
            filtered
                .into_iter()
                .take(self.config.batch_max_live)
                .collect::<Vec<_>>()
        } else {
            all_candidates
        };

        // ── Step 3: POLICY ────────────────────────────────────────────────
        match evaluate(&candidates, &self.config) {
            PolicyDecision::Skip(reason) => {
                eprintln!("[integrator] cycle {cycle_id} skipped: {reason}");
                return Ok(());
            }
            PolicyDecision::Proceed => {}
        }

        emit_event(
            "integration_candidates_selected",
            &[
                ("cycle_id", &cycle_id),
                ("count", &candidates.len().to_string()),
                (
                    "gap_ids",
                    &candidates
                        .iter()
                        .map(|c| c.gap_id.as_str())
                        .collect::<Vec<_>>()
                        .join(","),
                ),
            ],
        );

        let manifest = CycleManifest::new(cycle_id.clone(), candidates.clone());

        // ── Step 4: MERGE ─────────────────────────────────────────────────
        let integration_branch = format!("chump/integration-{}", &cycle_id);
        let merge_outcome = match self.run_merge(&candidates, &integration_branch).await {
            Ok(outcome) => outcome,
            Err(e) => {
                eprintln!("[integrator] merge step failed: {e:#}");
                return Ok(());
            }
        };

        if !merge_outcome.conflicts.is_empty() {
            let conflict = &merge_outcome.conflicts[0];
            emit_event(
                "integration_merge_conflict",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_id", &conflict.gap_id),
                    ("files", &conflict.conflicted_files.join(",")),
                ],
            );
            eprintln!(
                "[integrator] cycle {cycle_id} aborted — merge conflict on {}",
                conflict.gap_id
            );
            return Ok(());
        }

        for mg in &merge_outcome.merged_gaps {
            emit_event(
                "integration_branch_merged",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_id", &mg.gap_id),
                    ("merge_sha", &mg.merge_sha),
                ],
            );
        }

        // ── Step 5: PREFLIGHT + bisect-quarantine loop (INFRA-2137) ──────────
        // Max 3 quarantine cycles: on each preflight failure we bisect to find
        // the offending gap, quarantine it, rebuild the integration branch
        // without it, and retry.  After 3 quarantine passes we abort entirely.
        const MAX_QUARANTINE_CYCLES: usize = 3;
        let mut remaining_candidates = candidates.clone();
        let mut quarantine_count: usize = 0;

        loop {
            if remaining_candidates.is_empty() {
                eprintln!("[integrator] no candidates remain after quarantine — aborting cycle {cycle_id}");
                return Ok(());
            }

            emit_event(
                "integration_preflight_started",
                &[("cycle_id", &cycle_id), ("branch", &integration_branch)],
            );

            let preflight_ok = self.run_preflight(&integration_branch).await;

            if preflight_ok {
                // Preflight passed — proceed to DECISION below.
                break;
            }

            emit_event(
                "integration_preflight_failed",
                &[("cycle_id", &cycle_id), ("branch", &integration_branch)],
            );
            eprintln!("[integrator] preflight FAILED for cycle {cycle_id} (quarantine_count={quarantine_count})");

            if quarantine_count >= MAX_QUARANTINE_CYCLES {
                eprintln!(
                    "[integrator] reached max quarantine cycles ({MAX_QUARANTINE_CYCLES}) — aborting cycle {cycle_id}"
                );
                return Ok(());
            }
            quarantine_count += 1;

            // Bisect: identify the offending gap (currently: first candidate as
            // a conservative heuristic; INFRA-2136 replaces with git-bisect oracle).
            let offending = remaining_candidates[0].clone();
            eprintln!(
                "[integrator] quarantining {} (cycle {cycle_id}, pass {quarantine_count})",
                offending.gap_id
            );

            // Quarantine in state.db.
            if let Ok(store) = chump_gap_store::GapStore::open(&self.repo_root) {
                let reason = format!(
                    "Quarantined from integration-{cycle_id}: preflight failure (quarantine pass {quarantine_count})"
                );
                let _ = store.set_fields(
                    &offending.gap_id,
                    GapFieldUpdate {
                        status: Some("bisect_quarantined".to_string()),
                        ..Default::default()
                    },
                );
                let _ = store.append_notes_for_gap(&offending.gap_id, &reason);
            }

            // Emit ambient bisect_quarantine event.
            emit_event(
                "bisect_quarantine",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_id", &offending.gap_id),
                    ("quarantine_pass", &quarantine_count.to_string()),
                ],
            );

            // Post to work-board for operator review (best-effort; NATS may be absent).
            if let Some(coord) = &self.coord {
                use chump_coord::work_board::{Requirement, Subtask};
                let mut subtask = Subtask::new(
                    &offending.gap_id,
                    &format!(
                        "Manual review needed: {} failed integration {}",
                        offending.gap_id, cycle_id
                    ),
                    "chump-integrator",
                    Requirement {
                        task_class: "bisect-review".to_string(),
                        ..Default::default()
                    },
                );
                subtask.description = format!(
                    "Gap {} was quarantined by the integration daemon on cycle {} \
                     (quarantine pass {}). Run `chump gap requeue {}` after fixing \
                     the underlying failure.",
                    offending.gap_id, cycle_id, quarantine_count, offending.gap_id
                );
                if let Err(e) = coord.post_subtask(&subtask).await {
                    eprintln!("[integrator] work-board post failed (best-effort): {e:#}");
                }
            }

            // Remove offending gap from remaining candidates and rebuild branch.
            remaining_candidates.retain(|c| c.gap_id != offending.gap_id);

            if remaining_candidates.is_empty() {
                eprintln!(
                    "[integrator] no candidates remain after quarantining {} — aborting",
                    offending.gap_id
                );
                return Ok(());
            }

            // Rebuild integration branch without the offending gap.
            let _ = tokio::process::Command::new("git")
                .args(["checkout", "-B", &integration_branch, "HEAD"])
                .current_dir(&self.repo_root)
                .status()
                .await;
            match build_integration_branch(
                &remaining_candidates,
                &integration_branch,
                &self.repo_root,
            )
            .await
            {
                Ok(_) => {
                    eprintln!(
                        "[integrator] rebuilt integration branch without {} — retrying preflight",
                        offending.gap_id
                    );
                }
                Err(e) => {
                    eprintln!("[integrator] failed to rebuild integration branch: {e:#}");
                    return Ok(());
                }
            }
        }

        // ── Step 6: DECISION ─────────────────────────────────────────────
        let gap_ids = manifest
            .candidates
            .iter()
            .map(|c| c.gap_id.as_str())
            .collect::<Vec<_>>()
            .join(",");

        if cycle_is_live {
            // LIVE SHIP path: push integration branch, open PR, arm auto-merge.
            eprintln!(
                "[integrator] LIVE SHIP cycle={cycle_id} gaps=[{gap_ids}] loc={}",
                manifest.total_loc,
            );

            match self
                .ship_integration_branch(&integration_branch, &cycle_id, &manifest)
                .await
            {
                Ok(pr_url) => {
                    // Clear circuit breaker on success.
                    self.circuit_broken.store(false, Ordering::SeqCst);
                    emit_event(
                        "integration_cycle_completed",
                        &[
                            ("cycle_id", &cycle_id),
                            ("gap_count", &manifest.candidates.len().to_string()),
                            ("total_loc", &manifest.total_loc.to_string()),
                            ("gap_ids", &gap_ids),
                            ("pr_url", &pr_url),
                        ],
                    );
                    // Also emit the legacy shipped event for kpi-report consumers.
                    emit_event(
                        "integration_cycle_shipped",
                        &[
                            ("cycle_id", &cycle_id),
                            ("gap_count", &manifest.candidates.len().to_string()),
                            ("total_loc", &manifest.total_loc.to_string()),
                            ("gap_ids", &gap_ids),
                            ("stubbed", "false"),
                        ],
                    );
                }
                Err(e) => {
                    eprintln!("[integrator] LIVE ship FAILED cycle={cycle_id}: {e:#}");
                    // Circuit breaker: next cycle runs as dry-run.
                    self.circuit_broken.store(true, Ordering::SeqCst);
                    // Roll back the integration branch.
                    self.rollback_integration_branch(&integration_branch).await;
                    emit_event(
                        "integration_cycle_failed",
                        &[
                            ("cycle_id", &cycle_id),
                            ("gap_ids", &gap_ids),
                            ("error", &format!("{e:#}")),
                            ("circuit_breaker", "armed"),
                        ],
                    );
                }
            }
        } else {
            // DRY-RUN: log manifest + emit dry-run completed event.
            let summary = manifest.dry_run_summary();
            eprintln!("[integrator] DRY-RUN: {summary}");
            self.write_dry_run_log(&manifest)
                .with_context(|| "writing dry-run log")?;
            emit_event(
                "integration_cycle_dry_run_completed",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_count", &manifest.candidates.len().to_string()),
                    ("total_loc", &manifest.total_loc.to_string()),
                    ("gap_ids", &gap_ids),
                ],
            );
        }

        Ok(())
    }

    // ── safety-rail helpers ───────────────────────────────────────────────

    /// Returns true if trunk-red-detector-state.json signals trunk is RED.
    ///
    /// Reads `{repo_root}/.chump-locks/trunk-red-detector-state.json` and
    /// checks the `is_red` boolean field. Missing file or parse error → false
    /// (safe default: don't block on detector absence).
    fn is_trunk_red(&self) -> bool {
        let state_path = self.repo_root.join(TRUNK_RED_STATE_FILE);
        let Ok(bytes) = std::fs::read(&state_path) else {
            return false;
        };
        let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            eprintln!("[integrator] trunk-red state file unreadable; assuming not red");
            return false;
        };
        val.get("is_red").and_then(|v| v.as_bool()).unwrap_or(false)
    }

    /// Returns true if a candidate has the do-not-batch label.
    ///
    /// Checks the candidate's `tags` field for the configured label name.
    /// Tags are comma-separated; label matching is case-insensitive.
    ///
    /// For v1, checks author and branch name as a proxy. Full tag-field wiring
    /// through GapCandidate requires INFRA-2136 (adds tags to the struct).
    fn has_do_not_batch_label(&self, candidate: &crate::cycle::GapCandidate) -> bool {
        let label = self.config.do_not_batch_label.to_lowercase();
        let author_matches = candidate
            .author
            .as_deref()
            .unwrap_or("")
            .to_lowercase()
            .contains(&label);
        let branch_matches = candidate.branch.to_lowercase().contains(&label);
        author_matches || branch_matches
    }

    /// Push the integration branch, open a PR, and arm auto-merge.
    ///
    /// Returns the PR URL on success. On any failure the caller triggers
    /// the circuit breaker and calls `rollback_integration_branch`.
    async fn ship_integration_branch(
        &self,
        branch: &str,
        cycle_id: &str,
        manifest: &CycleManifest,
    ) -> Result<String> {
        let repo = &self.repo_root;
        let gap_ids: Vec<&str> = manifest
            .candidates
            .iter()
            .map(|c| c.gap_id.as_str())
            .collect();
        let gap_list = gap_ids.join(", ");

        // 1. Push the integration branch.
        let push_status = tokio::process::Command::new("git")
            .args(["push", "-u", "origin", branch, "--force-with-lease"])
            .current_dir(repo)
            .status()
            .await
            .with_context(|| format!("git push for branch {branch}"))?;

        if !push_status.success() {
            anyhow::bail!("git push failed for branch {branch}");
        }

        // 2. Create the PR via gh cli.
        let pr_title = format!(
            "feat(SCALE-A): integration-{cycle_id} — batch {} gaps",
            manifest.candidates.len()
        );
        let pr_body = format!(
            "Batched integration cycle `{cycle_id}`.\n\n\
             Gaps: {gap_list}\n\
             Total estimated LOC: {}\n\n\
             Batched-Under: {branch}\n\
             Integration-Cycle-Id: {cycle_id}\n",
            manifest.total_loc,
        );

        let pr_output = tokio::process::Command::new("gh")
            .args([
                "pr", "create", "--base", "main", "--head", branch, "--title", &pr_title, "--body",
                &pr_body,
            ])
            .current_dir(repo)
            .output()
            .await
            .with_context(|| "gh pr create")?;

        if !pr_output.status.success() {
            let stderr = String::from_utf8_lossy(&pr_output.stderr);
            anyhow::bail!("gh pr create failed: {stderr}");
        }

        let pr_url = String::from_utf8_lossy(&pr_output.stdout)
            .trim()
            .to_string();

        // 3. Extract PR number and arm auto-merge.
        // gh pr create outputs the PR URL as the last line; parse number from it.
        let pr_number = pr_url
            .rsplit('/')
            .next()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .with_context(|| format!("could not parse PR number from gh output: {pr_url}"))?;

        let merge_status = tokio::process::Command::new("gh")
            .args(["pr", "merge", &pr_number.to_string(), "--auto", "--squash"])
            .current_dir(repo)
            .status()
            .await
            .with_context(|| format!("gh pr merge --auto for PR {pr_number}"))?;

        if !merge_status.success() {
            anyhow::bail!("gh pr merge --auto --squash failed for PR {pr_number}");
        }

        eprintln!("[integrator] LIVE ship complete: PR #{pr_number} ({pr_url}) — auto-merge armed");
        Ok(pr_url)
    }

    /// Roll back the integration branch to HEAD on main.
    ///
    /// Best-effort: errors are logged but not propagated so the circuit
    /// breaker path completes cleanly.
    async fn rollback_integration_branch(&self, branch: &str) {
        eprintln!("[integrator] rolling back integration branch {branch}");
        let result = tokio::process::Command::new("git")
            .args(["branch", "-D", branch])
            .current_dir(&self.repo_root)
            .status()
            .await;
        match result {
            Ok(s) if s.success() => {
                eprintln!("[integrator] rollback complete: deleted local branch {branch}");
            }
            Ok(s) => {
                eprintln!(
                    "[integrator] rollback: git branch -D {branch} exited {}",
                    s.code().unwrap_or(-1)
                );
            }
            Err(e) => {
                eprintln!("[integrator] rollback: could not delete branch {branch}: {e:#}");
            }
        }
    }

    // ── core helpers ──────────────────────────────────────────────────────

    async fn try_claim_integration_slot(&self, cycle_id: &str) -> bool {
        if let Some(coord) = &self.coord {
            match coord.try_claim_gap(INTEGRATION_SLOT_KEY, cycle_id).await {
                Ok(claimed) => claimed,
                Err(e) => {
                    eprintln!("[integrator] NATS slot claim error: {e:#}; proceeding without lock");
                    true // degrade gracefully
                }
            }
        } else {
            // NATS unavailable — proceed without distributed lock.
            eprintln!("[integrator] NATS unavailable; integration slot lock skipped");
            true
        }
    }

    async fn select_candidates(&self) -> Result<Vec<crate::cycle::GapCandidate>> {
        // Try NATS work-board first; fall back to state.db.
        // Phase 1: always use state.db path (NATS work-board protocol is
        // defined by subtasks, not gaps — future phase will wire this up).
        let store = chump_gap_store::GapStore::open(&self.repo_root)
            .with_context(|| "opening state.db for candidate selection")?;

        let rows = store
            .list(Some("ready_to_ship"))
            .with_context(|| "listing ready_to_ship gaps")?;

        if rows.is_empty() {
            eprintln!("[integrator] state.db fallback: no ready_to_ship gaps");
        } else {
            eprintln!(
                "[integrator] state.db fallback: {} ready_to_ship gap(s)",
                rows.len()
            );
        }

        let board = StateDbWorkBoard::from_gap_rows(rows);
        Ok(select_candidates(
            &board,
            self.config.max_batch,
            self.config.loc_budget,
        ))
    }

    async fn run_merge(
        &self,
        candidates: &[crate::cycle::GapCandidate],
        integration_branch: &str,
    ) -> Result<crate::cycle::merge_branch::IntegrationBranchOutcome> {
        // Ensure integration branch exists.
        let _ = tokio::process::Command::new("git")
            .args(["checkout", "-B", integration_branch, "HEAD"])
            .current_dir(&self.repo_root)
            .status()
            .await;

        build_integration_branch(candidates, integration_branch, &self.repo_root).await
    }

    async fn run_preflight(&self, branch: &str) -> bool {
        let timeout = self.config.preflight_timeout;
        let repo = &self.repo_root;

        // Prefer `chump preflight` if available, else cross-build-linux.sh.
        let chump_bin = which_chump(repo);
        let result = if let Some(bin) = chump_bin {
            run_with_timeout(
                tokio::process::Command::new(bin)
                    .arg("preflight")
                    .current_dir(repo),
                timeout,
            )
            .await
        } else {
            let script = repo.join("scripts/dev/cross-build-linux.sh");
            if script.exists() {
                run_with_timeout(
                    tokio::process::Command::new("bash")
                        .args([script.to_str().unwrap(), "-p", "chump-integrator"])
                        .current_dir(repo),
                    timeout,
                )
                .await
            } else {
                eprintln!(
                    "[integrator] preflight: neither `chump preflight` nor \
                     scripts/dev/cross-build-linux.sh found; skipping (pass)"
                );
                return true;
            }
        };

        match result {
            Ok(status) => {
                if status {
                    eprintln!("[integrator] preflight passed (branch={branch})");
                } else {
                    eprintln!("[integrator] preflight FAILED (branch={branch})");
                }
                status
            }
            Err(e) => {
                eprintln!("[integrator] preflight error: {e:#}");
                false
            }
        }
    }

    fn write_dry_run_log(&self, manifest: &CycleManifest) -> Result<()> {
        // Ensure ~/.chump/ exists.
        if let Some(parent) = self.dry_run_log.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.dry_run_log)?;

        let entry = serde_json::json!({
            "ts": Utc::now().to_rfc3339(),
            "cycle_id": manifest.cycle_id,
            "summary": manifest.dry_run_summary(),
            "total_loc": manifest.total_loc,
            "candidates": manifest.candidates.iter().map(|c| &c.gap_id).collect::<Vec<_>>(),
        });
        writeln!(file, "{}", serde_json::to_string(&entry)?)?;
        Ok(())
    }
}

// ── slot guard ────────────────────────────────────────────────────────────────

/// RAII guard that releases the NATS integration slot on drop.
///
/// Holds an owned clone of the coord client so it is `'static`-safe.
/// Drop fires a detached tokio task for best-effort cleanup; the KV TTL
/// guarantees eventual expiry even if the task doesn't run.
struct IntegrationSlotGuard {
    coord: Option<Arc<chump_coord::CoordClient>>,
}

impl Drop for IntegrationSlotGuard {
    fn drop(&mut self) {
        if let Some(coord) = self.coord.take() {
            tokio::spawn(async move {
                let _ = coord.release_gap(INTEGRATION_SLOT_KEY).await;
            });
        }
    }
}

// ── utility functions ─────────────────────────────────────────────────────────

fn short_uuid() -> String {
    let u = Uuid::new_v4();
    u.simple().to_string()[..8].to_string()
}

fn which_chump(repo_root: &Path) -> Option<String> {
    // Check target/debug or target/release for local build first.
    for rel in ["target/debug/chump", "target/release/chump"] {
        let p = repo_root.join(rel);
        if p.exists() {
            return Some(p.to_string_lossy().into_owned());
        }
    }
    // Fall back to PATH lookup.
    if std::process::Command::new("which")
        .arg("chump")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        return Some("chump".to_string());
    }
    None
}

async fn run_with_timeout(cmd: &mut tokio::process::Command, timeout: Duration) -> Result<bool> {
    let mut child = cmd
        .stdin(std::process::Stdio::null())
        .spawn()
        .with_context(|| "spawning preflight command")?;

    match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(status)) => Ok(status.success()),
        Ok(Err(e)) => Err(anyhow::anyhow!("preflight process error: {e}")),
        Err(_) => {
            let _ = child.kill().await;
            Err(anyhow::anyhow!(
                "preflight timed out after {}s",
                timeout.as_secs()
            ))
        }
    }
}

fn emit_event(kind: &str, fields: &[(&str, &str)]) {
    let args = EmitArgs {
        kind: kind.to_string(),
        fields: fields
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        ..Default::default()
    };
    if let Err(e) = emit(&args) {
        eprintln!("[integrator] ambient emit {kind} failed: {e:#}");
    }
}
