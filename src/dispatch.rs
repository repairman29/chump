//! INFRA-191 — `chump dispatch` (Phase 1 skeleton).
//!
//! Single command that runs the whole ship cycle:
//!   preflight → claim → (caller's work happened already) → ship → release
//!
//! ## Phase 1 scope (PR #783, MERGED)
//!
//! - Public API surface: [`DispatchOptions`], [`DispatchOutcome`],
//!   [`ShipResult`], [`WorkBackend`], [`run`].
//! - Internals **wrap the existing shell scripts** via `std::process::Command`
//!   (gap-preflight.sh, gap-claim.sh, bot-merge.sh).
//! - Only [`WorkBackend::Interactive`] supported.
//!
//! ## Phase 2 scope (THIS PR)
//!
//! - [`WorkBackend::Headless`] — spawn `claude -p <prompt>
//!   --dangerously-skip-permissions` and wait for exit. Used by
//!   `chump-orchestrator` / `run-fleet.sh` (INFRA-211) to do the actual
//!   coding work between claim and ship.
//! - [`WorkBackend::ExecGap`] — spawn `chump --execute-gap <ID>` (chump-local
//!   backend, COG-025). Same surface, different binary; used when
//!   `CHUMP_DISPATCH_BACKEND=chump-local` for cost-routing.
//!
//! ## Future phases (NOT this PR)
//!
//! - Phase 3: port [`ship`] to native Rust git/gh calls (replace the
//!   bot-merge.sh wrap).
//! - Phase 4: flip the CLAUDE.md/AGENTS.md ship-pipeline guidance from
//!   `bot-merge.sh` to `chump dispatch`.
//! - Phase 5: retire `scripts/coord/bot-merge.sh`.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::Duration;

// INFRA-302 blocker (3): reuse the orchestrator's worktree-path convention
// so the stale-worktree-reaper (`scripts/ops/stale-worktree-reaper.sh`) +
// the `.claude/worktrees/<gap-slug>/` tree the operator already knows
// about all stay consistent. See [`create_dispatch_worktree`].
use chump_orchestrator::dispatch::dispatch_paths;

/// How the actual work between claim and ship gets done.
#[derive(Debug, Clone)]
pub enum WorkBackend {
    /// Caller drives the work directly (e.g. interactive editing in this
    /// shell). `dispatch::run` only orchestrates preflight → claim →
    /// ship → release. The Phase 1 default.
    Interactive,

    /// Spawn `claude -p <prompt> --dangerously-skip-permissions` and wait.
    /// `model` is forwarded via `--model <…>`; pass an empty string to use
    /// the user's `claude` config default. The spawned process inherits the
    /// parent's stdin/stdout/stderr so progress is visible inline.
    Headless { model: String, prompt: String },

    /// Spawn `chump --execute-gap <ID>` (chump-local backend, COG-025).
    /// Used when the operator set `CHUMP_DISPATCH_BACKEND=chump-local` for
    /// cost-routing through Together/mistral.rs/Ollama instead of Anthropic.
    ExecGap,

    /// EFFECTIVE-017: spawn `opencode -p <prompt>` (opencode CLI by SST).
    /// Operator selects via `CHUMP_WORK_BACKEND=opencode`.
    Opencode { model: String, prompt: String },

    /// EFFECTIVE-017: spawn `aider --message <prompt>` (Aider).
    /// Operator selects via `CHUMP_WORK_BACKEND=aider`.
    Aider { model: String, prompt: String },
}

/// EFFECTIVE-017: select a `WorkBackend` from `CHUMP_WORK_BACKEND` env var.
/// Mapping: claude/unset → Headless; opencode → Opencode; aider → Aider;
/// chump-local/exec-gap → ExecGap; anything else → warn + fallback Headless.
///
/// Per the chump-first doctrine, this is the single seam where operators
/// pick the worker binary without editing source.
pub fn backend_from_env(model: String, prompt: String) -> WorkBackend {
    match std::env::var("CHUMP_WORK_BACKEND").as_deref() {
        Ok("opencode") => WorkBackend::Opencode { model, prompt },
        Ok("aider") => WorkBackend::Aider { model, prompt },
        Ok("chump-local") | Ok("exec-gap") => WorkBackend::ExecGap,
        Ok("claude") | Ok("") | Err(_) => WorkBackend::Headless { model, prompt },
        Ok(other) => {
            eprintln!(
                "[chump] WARNING: unknown CHUMP_WORK_BACKEND={other:?} — falling back to claude. \
                 Supported: claude, opencode, aider, chump-local"
            );
            WorkBackend::Headless { model, prompt }
        }
    }
}

/// Options for one dispatch invocation.
#[derive(Debug)]
pub struct DispatchOptions<'a> {
    /// Gap ID to dispatch (e.g. "INFRA-191"). Must be in the gap registry.
    pub gap_id: &'a str,
    /// How the work happens; see [`WorkBackend`].
    pub work: WorkBackend,
    /// Pass `--auto-merge` to the underlying ship command.
    pub auto_merge: bool,
    /// Pass `--skip-tests` to the underlying ship command.
    pub skip_tests: bool,
    /// Optional comma-separated path scope (forwarded to gap-claim --paths,
    /// honored by INFRA-189 out-of-scope guard).
    pub paths: Option<&'a str>,
    /// Repo root. Phase 1 derives this from the caller; the binary entry
    /// point uses `repo_path::repo_root()`.
    pub repo_root: PathBuf,
}

/// What happened to the PR after [`ship`] finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShipResult {
    /// PR opened (and possibly merge-queued via auto-merge); caller can poll
    /// the merge queue from here.
    Shipped { pr_number: u64 },
    /// Ship pipeline ran but couldn't queue the PR (CI red, branch
    /// protection failure, etc.).
    Blocked { reason: String },
    /// Hard error — ship pipeline aborted before producing a PR.
    Aborted { error: String },
}

/// Summary of one full dispatch cycle.
#[derive(Debug)]
pub struct DispatchOutcome {
    pub gap_id: String,
    pub branch: String,
    pub result: ShipResult,
    pub duration_secs: u64,
}

/// Run one full dispatch cycle for a single gap.
///
/// Always calls [`release`] at the end, even on error, so a process kill
/// mid-cycle leaves no stale lease. (The lease layer also has a TTL —
/// double belt-and-suspenders.)
///
/// ## INFRA-302 blocker (3) — worktree resolution
///
/// For [`WorkBackend::Headless`] and [`WorkBackend::ExecGap`], `run()`
/// creates a **fresh linked worktree** at `<repo_root>/.claude/worktrees/<gap-slug>`
/// off `origin/main` (matching `chump-orchestrator`'s convention via
/// [`chump_orchestrator::dispatch::dispatch_paths`]) and runs every
/// subsequent step (preflight, claim, work, ship, release) inside it.
/// Without this, the dispatched child runs in `opts.repo_root` (the
/// main checkout) on whatever branch `git rev-parse --abbrev-ref HEAD`
/// returns — which is exactly the 2026-05-02 dogfood failure mode where
/// `chump dispatch INFRA-247` reported `branch=chump/close-ghosts-batch-3`
/// (the operator's leftover branch) and the dispatched work would have
/// committed there if the run hadn't 402'd first.
///
/// For [`WorkBackend::Interactive`] the caller is already in their own
/// worktree (per the CLAUDE.md "always work in a linked worktree" rule
/// plus `gap-claim.sh`'s main-checkout refusal), so `run()` keeps using
/// `opts.repo_root` as the working directory unchanged.
pub fn run(opts: DispatchOptions) -> Result<DispatchOutcome> {
    let started = std::time::Instant::now();

    // Build the workspace: working_dir is either a fresh worktree (Headless
    // / ExecGap) or the caller's repo_root (Interactive). See [`Workspace`].
    let workspace = Workspace::new(&opts)
        .context("resolving workspace (worktree creation for ExecGap/Headless)")?;
    let branch = current_branch(workspace.working_dir())?;

    // Step 1: preflight (read-only check).
    preflight(&workspace).context("preflight")?;

    // Step 2: claim (writes .chump-locks/<session>.json).
    claim(&workspace).context("claim")?;

    // Step 3: caller's work happens here. Interactive = caller already did
    // it; Headless / ExecGap = spawn the work-doing process and wait.
    if let Err(e) = do_work(&workspace) {
        // Always release before propagating the error so a failed work
        // step doesn't leave a stale lease. INFRA-1243: use retry+emit path.
        release_with_retry(&workspace)?;
        return Ok(DispatchOutcome {
            gap_id: opts.gap_id.to_string(),
            branch,
            result: ShipResult::Aborted {
                error: format!("work step failed: {e:#}"),
            },
            duration_secs: started.elapsed().as_secs(),
        });
    }

    // Step 4: ship (calls bot-merge.sh in Phase 1; native in Phase 3).
    // Capture errors instead of `?`-ing so we always reach release.
    let ship_result = match ship(&workspace) {
        Ok(r) => r,
        Err(e) => ShipResult::Aborted {
            error: format!("{e:#}"),
        },
    };

    // Step 5: always release the lease. INFRA-1243: retry+emit on failure.
    release_with_retry(&workspace)?;

    Ok(DispatchOutcome {
        gap_id: opts.gap_id.to_string(),
        branch,
        result: ship_result,
        duration_secs: started.elapsed().as_secs(),
    })
}

/// Internal bundle of `(DispatchOptions, working_dir)` so step functions
/// don't have to repeat the resolution. INFRA-302 blocker (3) introduced
/// this so working_dir can differ from `opts.repo_root` (fresh worktree
/// for ExecGap/Headless).
///
/// Owned `working_dir: PathBuf` so the worktree path stays valid for the
/// whole dispatch lifetime (the worktree is created in [`Self::new`] and
/// outlives any borrows of `opts`).
struct Workspace<'a> {
    opts: &'a DispatchOptions<'a>,
    working_dir: PathBuf,
}

impl<'a> Workspace<'a> {
    fn new(opts: &'a DispatchOptions) -> Result<Self> {
        let working_dir = match opts.work {
            WorkBackend::Interactive => {
                // Caller is already in their worktree (per CLAUDE.md +
                // gap-claim.sh enforcement). No worktree creation needed;
                // matches the pre-INFRA-302 behavior so the Interactive
                // ledger-flip flow doesn't regress.
                opts.repo_root.clone()
            }
            WorkBackend::Headless { .. }
            | WorkBackend::ExecGap
            | WorkBackend::Opencode { .. }
            | WorkBackend::Aider { .. } => {
                // Fresh linked worktree off origin/main. INFRA-302 blocker
                // (3): without this, the dispatched child runs in the main
                // checkout on the operator's stale branch. The worktree is
                // intentionally NOT torn down on success — bot-merge.sh
                // writes `.bot-merge-shipped` and the
                // stale-worktree-reaper sweeps it up later (see CLAUDE.md
                // "Worktree disk hygiene"). On hard failure we also leave
                // it in place so the operator can inspect.
                create_dispatch_worktree(&opts.repo_root, opts.gap_id)
                    .with_context(|| format!("creating worktree for {}", opts.gap_id))?
            }
        };
        Ok(Self { opts, working_dir })
    }

    fn working_dir(&self) -> &Path {
        &self.working_dir
    }

    fn opts(&self) -> &DispatchOptions<'a> {
        self.opts
    }
}

/// INFRA-302 blocker (3): create a fresh linked worktree for a dispatched
/// agent. Path + branch follow [`chump_orchestrator::dispatch::dispatch_paths`]
/// (`<repo_root>/.claude/worktrees/<gap-slug>` + `claude/<gap-slug>`)
/// so the stale-worktree-reaper, the orchestrator's spawn path, and
/// `chump dispatch` all point at the same conventions.
///
/// Idempotent: if a leftover worktree from a prior killed dispatch
/// exists at the same path, it is force-removed first (along with the
/// orphan branch). The lease system already prevents two live sessions
/// from claiming the same gap in parallel (assuming single-host lease
/// visibility — INFRA-274 covers cross-host), so the only legitimate
/// pre-existing worktree at that path is detritus.
fn create_dispatch_worktree(repo_root: &Path, gap_id: &str) -> Result<PathBuf> {
    let (worktree_path, branch_name) = dispatch_paths(repo_root, gap_id);

    // Idempotent cleanup of any leftover worktree at the target path.
    // Failure is non-fatal — the subsequent `worktree add` will report a
    // clearer error if the path is genuinely contended (e.g. a live
    // sibling has it open).
    if worktree_path.exists() {
        let _ = Command::new("git")
            .arg("-C")
            .arg(repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(&worktree_path)
            .status();
    }
    // Same for any leftover branch from a prior dispatch that was
    // worktree-removed without `git branch -D`. Without this, the next
    // `git worktree add -b <branch>` fails with "branch already exists".
    let _ = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["branch", "-D", &branch_name])
        .status();

    let status = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["worktree", "add"])
        .arg(&worktree_path)
        .args(["-b", &branch_name, "origin/main"])
        .status()
        .with_context(|| {
            format!(
                "spawning git worktree add {} -b {} origin/main",
                worktree_path.display(),
                branch_name
            )
        })?;
    if !status.success() {
        bail!(
            "git worktree add failed for {} (branch {}, base origin/main)",
            worktree_path.display(),
            branch_name
        );
    }
    Ok(worktree_path)
}

// ── Internals (each one independently portable in Phase 3) ───────────────────

/// Execute the user-provided work for a dispatch cycle. Variant-dispatched
/// per [`WorkBackend`].
fn do_work(ws: &Workspace) -> Result<()> {
    match &ws.opts().work {
        WorkBackend::Interactive => {
            // Caller already did the work; nothing to spawn.
            Ok(())
        }
        WorkBackend::Headless { model, prompt } => spawn_headless(ws, model, prompt),
        WorkBackend::ExecGap => spawn_exec_gap(ws),
        WorkBackend::Opencode { model, prompt } => spawn_opencode(ws, model, prompt),
        WorkBackend::Aider { model, prompt } => spawn_aider(ws, model, prompt),
    }
}

/// EFFECTIVE-017 — `WorkBackend::Opencode`.
fn spawn_opencode(ws: &Workspace, model: &str, prompt: &str) -> Result<()> {
    let opts = ws.opts();
    if prompt.trim().is_empty() {
        bail!(
            "WorkBackend::Opencode: prompt is empty (gap={})",
            opts.gap_id
        );
    }
    let mut cmd = Command::new("opencode");
    cmd.arg("-p").arg(prompt).arg("--auto-approve");
    if !model.is_empty() {
        cmd.args(["--model", model]);
    }
    cmd.current_dir(ws.working_dir());
    let child = cmd
        .spawn()
        .context("spawn `opencode -p` (is opencode CLI on PATH?)")?;
    let status = wait_with_hang_detection(child, "opencode -p", opts.gap_id)
        .context("waiting for opencode -p to complete")?;
    if !status.success() {
        bail!(
            "opencode -p exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// EFFECTIVE-017 — `WorkBackend::Aider`.
fn spawn_aider(ws: &Workspace, model: &str, prompt: &str) -> Result<()> {
    let opts = ws.opts();
    if prompt.trim().is_empty() {
        bail!("WorkBackend::Aider: prompt is empty (gap={})", opts.gap_id);
    }
    let mut cmd = Command::new("aider");
    cmd.arg("--message").arg(prompt).arg("--yes");
    if !model.is_empty() {
        cmd.args(["--model", model]);
    }
    cmd.current_dir(ws.working_dir());
    let child = cmd
        .spawn()
        .context("spawn `aider --message` (is aider on PATH?)")?;
    let status = wait_with_hang_detection(child, "aider", opts.gap_id)
        .context("waiting for aider --message to complete")?;
    if !status.success() {
        bail!(
            "aider exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// Phase 2 — `WorkBackend::Headless`. Spawns
/// `claude -p <prompt> --dangerously-skip-permissions [--model <model>]`,
/// inherits stdio so the operator sees progress inline, and waits for exit.
fn spawn_headless(ws: &Workspace, model: &str, prompt: &str) -> Result<()> {
    let opts = ws.opts();
    if prompt.trim().is_empty() {
        bail!(
            "WorkBackend::Headless: prompt is empty (gap={})",
            opts.gap_id
        );
    }
    let mut cmd = Command::new("claude");
    cmd.arg("-p")
        .arg(prompt)
        .arg("--dangerously-skip-permissions");
    if !model.is_empty() {
        cmd.args(["--model", model]);
    }
    // Inherit env so spawned process sees CLAUDE_SESSION_ID / CHUMP_SESSION_ID
    // / lease metadata. Inherit stdio so the operator can see progress.
    // INFRA-302 blocker (3): cwd is the FRESH WORKTREE, NOT opts.repo_root —
    // see Workspace::new for the resolution.
    cmd.current_dir(ws.working_dir());
    let child = cmd
        .spawn()
        .context("spawn `claude -p` (is the claude CLI on PATH?)")?;
    let status = wait_with_hang_detection(child, "claude -p", opts.gap_id)
        .context("waiting for claude -p to complete")?;
    if !status.success() {
        bail!(
            "claude -p exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// Phase 2 — `WorkBackend::ExecGap`. Spawns `chump --execute-gap <ID>` (the
/// chump-local backend introduced in COG-025). Same stdio + env inheritance
/// as headless. Resolves the chump binary by trying common install paths
/// before falling back to PATH lookup; this avoids needing $HOME/.local/bin
/// in PATH at every callsite (parallel to INFRA-231's overnight wrapper fix).
fn spawn_exec_gap(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    // Resolve binary against repo_root (binary lives under
    // `<repo_root>/target/...`, NOT under the worktree's target/).
    let chump_bin = resolve_chump_binary(&opts.repo_root);
    let mut cmd = Command::new(chump_bin);
    cmd.args(["--execute-gap", opts.gap_id])
        // INFRA-302 blocker (3): cwd is the FRESH WORKTREE so the
        // dispatched child commits + ships from the gap's own branch,
        // not from whatever was checked out in the main repo when the
        // operator typed `chump dispatch …`.
        .current_dir(ws.working_dir());
    let child = cmd
        .spawn()
        .with_context(|| format!("spawn `chump --execute-gap {}`", opts.gap_id))?;
    let status = wait_with_hang_detection(child, "chump --execute-gap", opts.gap_id)
        .context("waiting for chump --execute-gap to complete")?;
    if !status.success() {
        bail!(
            "chump --execute-gap exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// Wait for a child process with hang detection (INFRA-406).
/// If the process doesn't complete within the timeout period, send SIGTERM
/// and emit an ALERT to ambient.jsonl.
///
/// The timeout is configurable via CHUMP_DISPATCH_HANG_TIMEOUT_SECS env var
/// (default 3600 = 1 hour). Set to 0 to disable hang detection.
fn wait_with_hang_detection(
    mut child: Child,
    process_name: &str,
    gap_id: &str,
) -> Result<std::process::ExitStatus> {
    // Two cooperating deadlines:
    //   1. SUBAGENT BUDGET (CHUMP_SUBAGENT_BUDGET_S, default 900s):
    //      parent-enforced upper bound on wall-clock per subagent dispatch.
    //      INFRA-1972 (critique H3): CLAUDE.md documents this as a
    //      "self-discipline rule" for the subagent itself, but yesterday's
    //      ci-audit + md-links dispatches burned 144K + 157K tokens past
    //      budget without self-honoring it. This is the parent-side hard
    //      enforcement that didn't exist before. On exceed: SIGTERM, then
    //      30s grace, then SIGKILL. Emits kind=subagent_killed_at_budget.
    //   2. HANG TIMEOUT (CHUMP_DISPATCH_HANG_TIMEOUT_SECS, default 3600s):
    //      backup deadline — catches a stuck process that somehow survived
    //      the budget kill. SIGKILL only. Emits kind=hang_detector.
    //
    // Either env set to 0 disables that specific deadline. The budget
    // (faster) fires first by design; hang is a backstop.
    let budget_secs: u64 = std::env::var("CHUMP_SUBAGENT_BUDGET_S")
        .ok()
        .and_then(|s| s.parse().ok())
        .or_else(|| {
            // Fall back to the legacy bot-merge-specific name if set,
            // so existing env configs keep working (CLAUDE.md still
            // documents CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S=900).
            std::env::var("CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S")
                .ok()
                .and_then(|s| s.parse().ok())
        })
        .unwrap_or(900);

    let hang_secs: u64 = std::env::var("CHUMP_DISPATCH_HANG_TIMEOUT_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3600);

    let no_budget = budget_secs == 0;
    let no_hang = hang_secs == 0;
    if no_budget && no_hang {
        return child.wait().context("waiting for child process");
    }

    let start = std::time::Instant::now();
    let child_pid = child.id();
    let mut budget_kill_in_flight: Option<std::time::Instant> = None;
    let grace_secs: u64 = 30; // SIGTERM → SIGKILL grace window

    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {
                let elapsed = start.elapsed();

                // Budget enforcement (faster, graceful)
                if !no_budget && budget_kill_in_flight.is_none() && elapsed.as_secs() > budget_secs
                {
                    emit_subagent_killed_at_budget(process_name, gap_id, budget_secs, child_pid);
                    // Send SIGTERM (graceful). std::process::Child::kill is
                    // SIGKILL only; use the `kill` CLI to get SIGTERM without
                    // pulling in a new crate dep (see paramedic.rs for the
                    // existing precedent of Command::new("kill")).
                    let _ = std::process::Command::new("kill")
                        .args(["-TERM", &child_pid.to_string()])
                        .status();
                    budget_kill_in_flight = Some(std::time::Instant::now());
                }

                // After SIGTERM, allow `grace_secs` for graceful shutdown
                // before SIGKILL. INFRA-1972 AC: "at budget_secs + 30s: SIGKILL".
                if let Some(term_at) = budget_kill_in_flight {
                    if term_at.elapsed().as_secs() > grace_secs {
                        let _ = child.kill(); // SIGKILL
                        let _ = child.wait();
                        bail!(
                            "{} exceeded subagent budget ({} secs) for gap {}; SIGTERM at budget, \
                             SIGKILL after {}s grace",
                            process_name,
                            budget_secs,
                            gap_id,
                            grace_secs
                        );
                    }
                }

                // Hang-detector backstop (slower, hard kill — handles a stuck
                // process that somehow survived the budget SIGTERM+SIGKILL).
                if !no_hang && elapsed > Duration::from_secs(hang_secs) {
                    emit_hang_alert(process_name, gap_id, hang_secs);
                    let _ = child.kill();
                    let _ = child.wait();
                    bail!(
                        "{} exceeded no-tool-call timeout ({} secs) for gap {}; sent SIGTERM",
                        process_name,
                        hang_secs,
                        gap_id
                    );
                }
                std::thread::sleep(Duration::from_secs(1));
            }
            Err(e) => return Err(e).context("checking child process status"),
        }
    }
}

/// Emit `kind=subagent_killed_at_budget` to ambient.jsonl (INFRA-1972, H3).
/// Distinct from `kind=hang_detector` — this is the parent-enforced subagent
/// budget exceed; hang_detector is the longer fall-through wall-clock guard.
fn emit_subagent_killed_at_budget(
    process_name: &str,
    gap_id: &str,
    budget_secs: u64,
    child_pid: u32,
) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());

    let worktree = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"subagent_killed_at_budget\",\"kind\":\"subagent_killed_at_budget\",\
         \"process\":\"{process_name}\",\"gap\":\"{gap_id}\",\"pid\":{child_pid},\
         \"budget_secs\":{budget_secs}}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }

    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = std::process::Command::new("chump-coord")
            .arg("emit")
            .arg("subagent_killed_at_budget")
            .arg(format!("process={}", process_name))
            .arg(format!("gap={}", gap_id))
            .arg(format!("pid={}", child_pid))
            .arg(format!("budget_secs={}", budget_secs))
            .status();
    }
}

/// Emit a hang-detection alert to ambient.jsonl (INFRA-406).
fn emit_hang_alert(process_name: &str, gap_id: &str, timeout_secs: u64) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());

    let worktree = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"hang_detected\",\"kind\":\"hang_detector\",\"process\":\"{process_name}\",\
         \"gap\":\"{gap_id}\",\"timeout_secs\":{timeout_secs}}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }

    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = std::process::Command::new("chump-coord")
            .arg("emit")
            .arg("hang_detected")
            .arg(format!("process={}", process_name))
            .arg(format!("gap={}", gap_id))
            .arg(format!("timeout_secs={}", timeout_secs))
            .env("CHUMP_SESSION_ID", &session)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

/// Find the `chump` binary. Tries the in-tree `target/release` and
/// `target/debug` first (so `chump dispatch` always re-uses the same binary
/// the user is invoking), then `$HOME/.local/bin/chump` (the cargo-install
/// default), then bare `chump` (relying on PATH).
fn resolve_chump_binary(repo_root: &Path) -> PathBuf {
    for candidate in [
        repo_root.join("target/release/chump"),
        repo_root.join("target/debug/chump"),
    ] {
        if candidate.exists() {
            return candidate;
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let dot_local = PathBuf::from(home).join(".local/bin/chump");
        if dot_local.exists() {
            return dot_local;
        }
    }
    PathBuf::from("chump")
}

fn current_branch(repo_root: &Path) -> Result<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .context("git rev-parse --abbrev-ref")?;
    if !out.status.success() {
        bail!(
            "git rev-parse failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn preflight(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    // Scripts live in the main repo (worktrees share them via the
    // shared .git/, but path resolution is rooted at repo_root for
    // clarity).
    let script = opts.repo_root.join("scripts/coord/gap-preflight.sh");
    if !script.exists() {
        bail!(
            "gap-preflight.sh missing at {} — is repo_root set correctly?",
            script.display()
        );
    }
    let status = Command::new("bash")
        .arg(&script)
        .arg(opts.gap_id)
        // INFRA-302 blocker (3): run from the worktree so any
        // worktree-scoped state (lease files at `<wt>/.chump-locks/`)
        // is visible to the script.
        .current_dir(ws.working_dir())
        .status()
        .context("invoke gap-preflight.sh")?;
    if !status.success() {
        bail!(
            "gap-preflight.sh rejected {} (exit {})",
            opts.gap_id,
            status.code().unwrap_or(-1)
        );
    }
    Ok(())
}

fn claim(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    let script = opts.repo_root.join("scripts/coord/gap-claim.sh");
    if !script.exists() {
        bail!("gap-claim.sh missing at {}", script.display());
    }
    let mut cmd = Command::new("bash");
    cmd.arg(&script).arg(opts.gap_id);
    if let Some(paths) = opts.paths {
        cmd.arg("--paths").arg(paths);
    }
    // INFRA-302 blocker (3): run from the worktree. gap-claim.sh's
    // worktree-scoped session-ID resolution
    // (`.chump-locks/.wt-session-id`, see CLAUDE.md "Session ID
    // resolution") needs the worktree as cwd to get a stable per-worktree
    // session ID.
    let status = cmd
        .current_dir(ws.working_dir())
        .status()
        .context("invoke gap-claim.sh")?;
    if !status.success() {
        bail!(
            "gap-claim.sh failed for {} (exit {})",
            opts.gap_id,
            status.code().unwrap_or(-1)
        );
    }
    Ok(())
}

fn ship(ws: &Workspace) -> Result<ShipResult> {
    let opts = ws.opts();
    let script = opts.repo_root.join("scripts/coord/bot-merge.sh");
    if !script.exists() {
        bail!("bot-merge.sh missing at {}", script.display());
    }
    let mut cmd = Command::new("bash");
    cmd.arg(&script).args(["--gap", opts.gap_id]);
    if opts.auto_merge {
        cmd.arg("--auto-merge");
    }
    if opts.skip_tests {
        cmd.arg("--skip-tests");
    }
    // INFRA-302 blocker (3): bot-merge.sh derives the branch via
    // `git rev-parse --abbrev-ref HEAD` — it MUST run inside the
    // dispatch's fresh worktree, not the main checkout, or it pushes
    // (and force-arms auto-merge on) the wrong branch.
    let status = cmd
        .current_dir(ws.working_dir())
        .status()
        .context("invoke bot-merge.sh")?;
    if !status.success() {
        return Ok(ShipResult::Aborted {
            error: format!("bot-merge.sh exited {}", status.code().unwrap_or(-1)),
        });
    }

    // bot-merge.sh has already opened/updated the PR. Read the PR number off
    // the current branch via gh — also from the worktree, since we want the
    // PR that bot-merge.sh just opened (which corresponds to the worktree's
    // branch, not main).
    match current_pr_number(ws.working_dir()) {
        Ok(pr) => Ok(ShipResult::Shipped { pr_number: pr }),
        Err(e) => Ok(ShipResult::Blocked {
            reason: format!("ship succeeded but PR# unresolvable: {e:#}"),
        }),
    }
}

fn current_pr_number(repo_root: &Path) -> Result<u64> {
    let out = Command::new("gh")
        .args(["pr", "view", "--json", "number", "-q", ".number"])
        .current_dir(repo_root)
        .output()
        .context("gh pr view")?;
    if !out.status.success() {
        bail!(
            "gh pr view failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    s.parse::<u64>()
        .with_context(|| format!("parse PR# from {s:?}"))
}

/// Attempt one `chump --release` subprocess call. Returns an error if the
/// subprocess fails to spawn or exits non-zero.
fn release(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    // Re-use [`resolve_chump_binary`] so we honor the same precedence as
    // Phase 2's exec-gap path (in-tree target/ → $HOME/.local/bin → PATH).
    let chump = resolve_chump_binary(&opts.repo_root);
    // INFRA-302 blocker (3): release from the worktree so the same
    // session-ID resolution that wrote the lease (under
    // `<worktree>/.chump-locks/`) sees it for cleanup.
    let status = Command::new(&chump)
        .arg("--release")
        .current_dir(ws.working_dir())
        .status()
        .with_context(|| format!("spawning chump --release (binary: {})", chump.display()))?;
    if !status.success() {
        bail!("chump --release exited with {}", status);
    }
    Ok(())
}

/// Release the lease with one retry on transient failure. On second failure:
/// - emits `kind=lease_release_failed` to ambient.jsonl (INFRA-1243)
/// - logs via `tracing::error!`
/// - propagates via `bail!` so the dispatch caller sees the failure
///
/// Lease files carry a TTL so a missed release auto-recovers; this function
/// makes the gap deliberate and observable rather than silently lost.
fn release_with_retry(ws: &Workspace) -> Result<()> {
    match release(ws) {
        Ok(()) => return Ok(()),
        Err(e) => {
            eprintln!("[dispatch] WARNING: lease release failed (attempt 1/2), retrying: {e:#}");
        }
    }
    std::thread::sleep(std::time::Duration::from_millis(500));
    match release(ws) {
        Ok(()) => Ok(()),
        Err(e) => {
            let msg = format!("{e:#}");
            emit_lease_release_failed(ws.opts().gap_id, &msg);
            tracing::error!(
                gap_id = ws.opts().gap_id,
                error = %e,
                "lease release failed after 2 attempts — lease may persist until TTL"
            );
            bail!("lease release failed after 2 attempts: {e:#}");
        }
    }
}

/// Emit a `lease_release_failed` event to ambient.jsonl (INFRA-1243).
fn emit_lease_release_failed(gap_id: &str, error: &str) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    // Escape the error string for JSON (replace backslash and quote).
    let error_escaped = error.replace('\\', "\\\\").replace('"', "\\\"");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\
         \"kind\":\"lease_release_failed\",\"gap\":\"{gap_id}\",\
         \"error\":\"{error_escaped}\"}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn dispatch_options_round_trip() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: true,
            skip_tests: false,
            paths: Some("src/dispatch.rs"),
            repo_root: PathBuf::from("/tmp/nonexistent-dispatch-test"),
        };
        assert_eq!(opts.gap_id, "INFRA-191");
        assert!(opts.auto_merge);
        assert!(!opts.skip_tests);
        assert_eq!(opts.paths, Some("src/dispatch.rs"));
        match opts.work {
            WorkBackend::Interactive => {}
            _ => panic!("expected Interactive"),
        }
    }

    #[test]
    fn ship_result_variants_construct() {
        assert_eq!(
            ShipResult::Shipped { pr_number: 770 },
            ShipResult::Shipped { pr_number: 770 }
        );
        assert_ne!(
            ShipResult::Shipped { pr_number: 770 },
            ShipResult::Shipped { pr_number: 771 }
        );
        let blocked = ShipResult::Blocked {
            reason: "test".into(),
        };
        match blocked {
            ShipResult::Blocked { ref reason } => assert_eq!(reason, "test"),
            _ => panic!("expected Blocked"),
        }
    }

    /// Test helper: build a Workspace with a fixed working_dir, skipping
    /// the [`Workspace::new`] worktree-creation path (which needs a real
    /// git repo). Tests that exercise step fns just need a `(opts,
    /// working_dir)` bundle.
    fn ws_with_dir<'a>(opts: &'a DispatchOptions<'a>, dir: PathBuf) -> Workspace<'a> {
        Workspace {
            opts,
            working_dir: dir,
        }
    }

    #[test]
    fn preflight_bails_when_script_missing() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            // Deliberately point at a directory that has no scripts/coord/
            // tree so the missing-file branch fires.
            repo_root: PathBuf::from("/tmp"),
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        let err = preflight(&ws).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("gap-preflight.sh missing"),
            "expected missing-file error, got: {msg}"
        );
    }

    #[test]
    fn ship_bails_when_script_missing() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        let err = ship(&ws).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("bot-merge.sh missing"),
            "expected missing-file error, got: {msg}"
        );
    }

    // Phase 1.5+: integration test that exercises a full run() against a
    // tmpdir-staged fake repo (mock git/gh via shimmed PATH). Skipped here;
    // tracked in INFRA-191 design doc test plan.

    // ── Phase 2 tests ────────────────────────────────────────────────────────

    #[test]
    fn headless_backend_constructs() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Headless {
                model: "claude-sonnet-4-6".into(),
                prompt: "ship gap INFRA-191".into(),
            },
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
        };
        match opts.work {
            WorkBackend::Headless {
                ref model,
                ref prompt,
            } => {
                assert_eq!(model, "claude-sonnet-4-6");
                assert_eq!(prompt, "ship gap INFRA-191");
            }
            _ => panic!("expected Headless"),
        }
    }

    #[test]
    fn exec_gap_backend_constructs() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::ExecGap,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
        };
        matches!(opts.work, WorkBackend::ExecGap);
    }

    #[test]
    fn headless_bails_on_empty_prompt() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive, // value unused; we test the helper directly
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        let err = spawn_headless(&ws, "claude-sonnet-4-6", "   ").unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("prompt is empty"),
            "expected empty-prompt error, got: {msg}"
        );
    }

    #[test]
    fn resolve_chump_binary_falls_back_to_path() {
        // Empty repo_root with no target/ subdir; HOME unset (or home doesn't
        // contain .local/bin/chump). Should fall back to bare `chump` so the
        // OS resolves via PATH.
        let bin = resolve_chump_binary(&PathBuf::from("/tmp/no-such-repo-root"));
        // Either a real path (Jeff's machine has $HOME/.local/bin/chump) or
        // bare "chump" (CI). Both are valid resolutions. The contract is "we
        // never panic and we always return *something*".
        let s = bin.to_string_lossy().to_string();
        assert!(
            s == "chump" || s.ends_with("/chump") || s.contains("chump"),
            "unexpected resolution: {s}"
        );
    }

    #[test]
    fn do_work_interactive_is_noop() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        // Interactive should just return Ok(()) without spawning anything.
        do_work(&ws).expect("Interactive backend must always succeed");
    }

    // ── INFRA-302 blocker (3) — stale-branch / no-worktree fix ──────────────

    /// Workspace::new for Interactive must NOT touch the worktree
    /// machinery — the caller is already in their own worktree per
    /// CLAUDE.md. Regression guard: don't accidentally spawn a worktree
    /// for the ledger-flip flow.
    #[test]
    fn workspace_interactive_uses_repo_root_unchanged() {
        let opts = DispatchOptions {
            gap_id: "INFRA-302",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp/some-existing-worktree"),
        };
        let ws = Workspace::new(&opts).expect("Interactive must not touch git");
        assert_eq!(
            ws.working_dir(),
            opts.repo_root.as_path(),
            "Interactive backend must use opts.repo_root verbatim — caller is \
             already in their worktree (CLAUDE.md \"always work in a linked worktree\")"
        );
    }

    /// The dispatched-worktree path must follow the
    /// chump_orchestrator::dispatch_paths convention so the
    /// stale-worktree-reaper sweeps both orchestrator-spawned AND
    /// `chump dispatch`-spawned trees uniformly. Regression guard for
    /// path/branch drift between the two entry points.
    #[test]
    fn dispatch_paths_match_orchestrator_convention() {
        // Direct call into the orchestrator helper — confirms the import
        // resolves AND the path shape we depend on hasn't drifted. If
        // this changes, the stale-worktree-reaper's glob needs updating
        // in lockstep.
        let (wt, branch) =
            chump_orchestrator::dispatch::dispatch_paths(Path::new("/repo"), "INFRA-302");
        assert_eq!(
            wt,
            PathBuf::from("/repo/.claude/worktrees/infra-302"),
            "worktree path drifted — stale-worktree-reaper glob may need updating"
        );
        assert_eq!(
            branch, "claude/infra-302",
            "branch convention drifted — bot-merge.sh's gap-from-branch \
             auto-derive (INFRA-237) parses this prefix"
        );
    }

    /// The pre-INFRA-302 bug was that `chump dispatch INFRA-247` ran in
    /// the main checkout and reported `branch=chump/close-ghosts-batch-3`
    /// (operator's stale leftover branch). After the fix, the
    /// dispatched-worktree branch derives from `gap_id`, NOT from the
    /// caller's `git rev-parse --abbrev-ref HEAD`. This test pins the
    /// derivation contract.
    #[test]
    fn dispatched_worktree_branch_derives_from_gap_id_not_head() {
        // Two calls with the same repo_root but different gap_ids must
        // produce different branches — proving the branch is a function
        // of gap_id, not of the repo's current HEAD (which is the same
        // for both calls).
        let (_w1, b1) =
            chump_orchestrator::dispatch::dispatch_paths(Path::new("/repo"), "INFRA-247");
        let (_w2, b2) =
            chump_orchestrator::dispatch::dispatch_paths(Path::new("/repo"), "INFRA-302");
        assert_ne!(
            b1, b2,
            "branches must differ when gap_ids differ — otherwise the \
             pre-INFRA-302 stale-branch-pickup bug regresses"
        );
        assert!(
            b1.contains("infra-247"),
            "branch must encode gap_id, got: {b1}"
        );
        assert!(
            b2.contains("infra-302"),
            "branch must encode gap_id, got: {b2}"
        );
        // Critically: neither branch matches a typical operator-leftover
        // branch name (the 2026-05-02 incident leftover was
        // `chump/close-ghosts-batch-3`).
        assert!(
            !b1.contains("close-ghosts"),
            "regression: branch derived from operator's stale HEAD"
        );
    }

    /// `create_dispatch_worktree` is best-effort idempotent on a
    /// pre-existing target path (force-removes a leftover worktree
    /// before re-adding). Without a real git repo we can't run the
    /// happy path, but we CAN verify that the function doesn't panic
    /// when handed a nonexistent repo_root — the underlying git
    /// commands fail gracefully with a clear `Result<Err>` instead of
    /// blowing up the dispatch.
    #[test]
    fn create_dispatch_worktree_returns_err_on_invalid_repo_root() {
        let res = create_dispatch_worktree(
            Path::new("/tmp/definitely-not-a-git-repo-infra-302"),
            "INFRA-302",
        );
        // We expect Err — but the important thing is it does NOT panic.
        // If git is unavailable in the test environment we'd also Err.
        assert!(
            res.is_err(),
            "expected Err from invalid repo_root; got: {:?}",
            res.map(|p| p.display().to_string())
        );
    }

    #[test]
    fn claim_bails_when_script_missing() {
        let opts = DispatchOptions {
            gap_id: "TEST-001",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        let err = claim(&ws).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("gap-claim.sh missing"),
            "expected missing-file error, got: {msg}"
        );
    }

    #[test]
    fn dispatch_outcome_tracks_gap_and_result() {
        let outcome = DispatchOutcome {
            gap_id: "INFRA-191".to_string(),
            branch: "claude/infra-191".to_string(),
            result: ShipResult::Shipped { pr_number: 1234 },
            duration_secs: 42,
        };
        assert_eq!(outcome.gap_id, "INFRA-191");
        assert_eq!(outcome.branch, "claude/infra-191");
        assert_eq!(outcome.duration_secs, 42);
        match outcome.result {
            ShipResult::Shipped { pr_number } => assert_eq!(pr_number, 1234),
            _ => panic!("expected Shipped result"),
        }
    }

    #[test]
    fn dispatch_options_with_paths() {
        let opts = DispatchOptions {
            gap_id: "INFRA-302",
            work: WorkBackend::Interactive,
            auto_merge: true,
            skip_tests: false,
            paths: Some("src/,scripts/"),
            repo_root: PathBuf::from("/repo"),
        };
        assert_eq!(opts.paths, Some("src/,scripts/"));
    }

    #[test]
    fn ship_result_aborted_variant() {
        let aborted = ShipResult::Aborted {
            error: "test error message".into(),
        };
        match aborted {
            ShipResult::Aborted { ref error } => assert_eq!(error, "test error message"),
            _ => panic!("expected Aborted variant"),
        }
    }

    #[test]
    fn workspace_accessors_expose_opts_and_dir() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/repo"),
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/working"));
        assert_eq!(ws.opts().gap_id, "INFRA-191");
        assert_eq!(ws.working_dir(), PathBuf::from("/working"));
    }

    // ── INFRA-1243: release_with_retry error handling ────────────────────────

    /// When the `chump --release` subprocess fails twice, `release_with_retry`
    /// must:
    ///   (a) return an Err (not swallow it),
    ///   (b) emit a `lease_release_failed` line to the ambient log.
    ///
    /// We exercise this by placing a mock `chump` binary at
    /// `<tmp>/target/release/chump` that always exits 1 — `resolve_chump_binary`
    /// finds it before falling back to PATH, so the real chump is never called.
    #[test]
    #[serial_test::serial(ambient_env)]
    fn release_with_retry_emits_ambient_event_and_propagates_on_double_failure() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let dir = tmp.path();

        // Fake chump binary that always exits 1.
        let target_dir = dir.join("target/release");
        std::fs::create_dir_all(&target_dir).unwrap();
        let fake_chump = target_dir.join("chump");
        std::fs::write(&fake_chump, "#!/usr/bin/env bash\nexit 1\n").unwrap();
        let mut perms = std::fs::metadata(&fake_chump).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_chump, perms).unwrap();

        // Point ambient log at a temp file so we can inspect it.
        let ambient = dir.join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", ambient.to_string_lossy().as_ref());

        let opts = DispatchOptions {
            gap_id: "INFRA-1243-TEST",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: dir.to_path_buf(),
        };
        let ws = ws_with_dir(&opts, dir.to_path_buf());

        let err = release_with_retry(&ws).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("failed after 2 attempts"),
            "expected '2 attempts' in error message, got: {msg}"
        );

        let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
        assert!(
            contents.contains("lease_release_failed"),
            "expected 'lease_release_failed' event in ambient log, got: {contents}"
        );
        assert!(
            contents.contains("INFRA-1243-TEST"),
            "expected gap_id in ambient event, got: {contents}"
        );

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    /// Single `release()` call must propagate a non-zero exit status as Err
    /// rather than silently succeeding.
    #[test]
    fn release_returns_err_on_nonzero_exit() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let dir = tmp.path();

        let target_dir = dir.join("target/release");
        std::fs::create_dir_all(&target_dir).unwrap();
        let fake_chump = target_dir.join("chump");
        std::fs::write(&fake_chump, "#!/usr/bin/env bash\nexit 2\n").unwrap();
        let mut perms = std::fs::metadata(&fake_chump).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_chump, perms).unwrap();

        let opts = DispatchOptions {
            gap_id: "INFRA-1243-UNIT",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: dir.to_path_buf(),
        };
        let ws = ws_with_dir(&opts, dir.to_path_buf());

        let result = release(&ws);
        assert!(
            result.is_err(),
            "release() must return Err on non-zero exit, got Ok"
        );
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("chump --release exited with"),
            "expected exit-status error, got: {msg}"
        );
    }
}
