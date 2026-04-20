//! Subprocess spawn for dispatched subagents — AUTO-013 MVP step 2.
//!
//! `dispatch_gap` creates a linked worktree for a gap, claims the lease in
//! that worktree, and spawns a `claude` CLI subprocess with a focused prompt.
//! The spawned agent follows `docs/TEAM_OF_AGENTS.md`: read CLAUDE.md, do the
//! work, ship via `scripts/bot-merge.sh`, reply only with the PR number.
//!
//! Monitor loop + reflection writes land in steps 3-4. This module only
//! returns a `DispatchHandle` — the caller owns tracking.
//!
//! ## Depth-1 enforcement (design doc §2, Q5)
//!
//! Dispatched subagents MUST NOT spawn further subagents. We set
//! `CHUMP_DISPATCH_DEPTH=1` in the subprocess env; a future guard in
//! `dispatch_gap` will refuse when that env var is already set.
//!
//! ## Why `std::process::Command`, not `tokio::process`
//!
//! Step 2 only needs to *start* the subprocess and return a handle. The
//! monitor loop (step 3) is where async polling matters. Keeping this
//! synchronous avoids pulling tokio into the crate for no gain.
//!
//! ## Fault-injection test mode (INFRA-DISPATCH-FAULT-INJECTION)
//!
//! Set `CHUMP_FAULT_INJECT` to a comma-separated list of fault specs to
//! exercise dispatch/monitor/retry paths without running a real `claude`
//! subprocess:
//!
//! - `spawn_fail` — `spawn_claude` returns an error immediately (no process).
//! - `exit_1` — spawns `sh -c 'sleep 0.1; exit 1'`; subprocess exits 1.
//! - `exit_0_no_pr` — spawns `sh -c 'sleep 0.1; exit 0'`; process exits 0
//!   but produces no PR number (tests the clean-exit-no-PR path).
//! - `monitor_timeout` — spawns `sh -c 'sleep 3600'`; the monitor's deadline
//!   ladder fires before the process exits (use a tiny soft_deadline in tests).
//!
//! The first spec in the list that applies wins. When `CHUMP_FAULT_INJECT` is
//! unset or empty, behavior is unchanged (production path).

use anyhow::{bail, Context, Result};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::Gap;

// ── Fault-injection ──────────────────────────────────────────────────────────

/// A single fault spec parsed from `CHUMP_FAULT_INJECT`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FaultMode {
    /// `spawn_claude` returns an error immediately — no process is forked.
    SpawnFail,
    /// Spawns `sh -c 'sleep 0.1; exit 1'` — process exits non-zero after
    /// 100 ms.
    Exit1,
    /// Spawns `sh -c 'sleep 0.1; exit 0'` — process exits 0 but produces
    /// no PR number in output (tests the clean-exit-no-PR monitor path).
    Exit0NoPr,
    /// Spawns `sh -c 'sleep 3600'` — a long-running process that the
    /// monitor's soft-deadline ladder will kill before it exits naturally.
    /// Use a tiny `soft_deadline_secs` in tests to trigger this quickly.
    MonitorTimeout,
}

/// Parse `CHUMP_FAULT_INJECT` into the first matching [`FaultMode`].
///
/// The env var accepts a comma-separated list; only the *first* recognised
/// token is returned (callers that need multiple faults in sequence drive
/// them in separate dispatches). Returns `None` when the env var is absent,
/// empty, or contains no recognised tokens.
pub fn active_fault_mode() -> Option<FaultMode> {
    let raw = std::env::var("CHUMP_FAULT_INJECT").ok()?;
    for token in raw.split(',') {
        match token.trim() {
            "spawn_fail" => return Some(FaultMode::SpawnFail),
            "exit_1" => return Some(FaultMode::Exit1),
            "exit_0_no_pr" => return Some(FaultMode::Exit0NoPr),
            "monitor_timeout" => return Some(FaultMode::MonitorTimeout),
            _ => {}
        }
    }
    None
}

/// Default cap on lines retained in [`DispatchHandle::stderr_tail`].
/// Anything past this is dropped — PRODUCT-006 only needs a representative
/// sample of WARN/ERROR lines, not the whole transcript.
pub const STDERR_TAIL_CAP: usize = 64;

/// Shared, lock-protected ring of WARN/ERROR lines tailed off a subagent's
/// stderr. Held by both the spawning thread and the [`DispatchHandle`].
pub type StderrTail = Arc<Mutex<Vec<String>>>;

/// Which subagent binary the spawner forked. COG-025 added the second arm so
/// dispatched subagents can run on Together / mistral.rs / Ollama (cost
/// routing) instead of the Anthropic-only `claude` CLI.
///
/// Selected at spawn time via env `CHUMP_DISPATCH_BACKEND`. The value is
/// captured on every [`DispatchHandle`] so [`crate::reflect::DispatchReflection`]
/// rows can be filtered/aggregated per-backend (COG-026 A/B reads this).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchBackend {
    /// `claude -p <prompt>` via `scripts/claude-retry.sh` — original AUTO-013
    /// baseline. Anthropic-only, costs ~$1-2/PR shipped.
    Claude,
    /// `target/release/chump --execute-gap <GAP-ID>` — drives Chump's own
    /// multi-turn agent loop through whatever provider $OPENAI_API_BASE +
    /// $OPENAI_MODEL resolve to. Free-tier-capable.
    ChumpLocal,
}

impl DispatchBackend {
    /// Resolve the backend from env. Default = `Claude` (preserves AUTO-013
    /// baseline behaviour for any caller who hasn't opted in). Unknown values
    /// fall back to the default with a one-line stderr warning so a typo
    /// doesn't silently send everything to claude when the operator wanted
    /// the cheap path.
    pub fn from_env() -> Self {
        match std::env::var("CHUMP_DISPATCH_BACKEND")
            .ok()
            .as_deref()
            .map(str::trim)
        {
            Some("") | None => DispatchBackend::Claude,
            Some("claude") => DispatchBackend::Claude,
            Some("chump-local") | Some("chump_local") | Some("local") => {
                DispatchBackend::ChumpLocal
            }
            Some(other) => {
                eprintln!(
                    "[dispatch] WARN unknown CHUMP_DISPATCH_BACKEND={other:?}; \
                     falling back to 'claude' (valid: claude | chump-local)"
                );
                DispatchBackend::Claude
            }
        }
    }

    /// Short stable label for logging + reflection notes.
    pub fn label(self) -> &'static str {
        match self {
            DispatchBackend::Claude => "claude",
            DispatchBackend::ChumpLocal => "chump-local",
        }
    }
}

/// Result of [`Spawner::spawn_claude`]: an optional child handle plus the
/// optional stderr-tail buffer the spawner attached.
///
/// Method name preserved (it's the trait API); the arm actually invoked is
/// recorded on [`DispatchHandle::backend`].
pub type SpawnResult = (Option<Child>, Option<StderrTail>);

/// Handle returned after a successful spawn. The monitor loop (step 3) will
/// consume these to track outcomes.
///
/// `child` is `Some` for real spawns and `None` for tests / injection-mode
/// runs that skip the actual process fork.
#[derive(Debug)]
pub struct DispatchHandle {
    pub gap_id: String,
    pub worktree_path: PathBuf,
    pub branch_name: String,
    pub child_pid: Option<u32>,
    pub started_at_unix: u64,
    /// Held so the child isn't reaped as a zombie before the monitor loop
    /// exists. In step 3 the monitor takes ownership.
    pub child: Option<Child>,
    /// Bounded ring of WARN/ERROR lines captured from the subagent's
    /// stderr. Populated by a background thread spawned in
    /// [`RealSpawner::spawn_claude`]; the monitor reads it when the
    /// subprocess reaches a terminal outcome and feeds the snapshot into
    /// the dispatch reflection (AUTO-013 step 4 — see
    /// [`crate::reflect::DispatchReflection`]).
    ///
    /// `None` for test spawners that don't fork a real process.
    pub stderr_tail: Option<StderrTail>,
    /// Which subagent binary the spawner forked. Default `Claude` for
    /// back-compat; `ChumpLocal` when CHUMP_DISPATCH_BACKEND=chump-local.
    /// Recorded into reflection notes by the monitor (COG-025/COG-026 A/B).
    pub backend: DispatchBackend,
}

impl DispatchHandle {
    /// Snapshot the captured stderr tail as a single newline-joined string
    /// (empty when no buffer was attached or no lines matched). Cheap —
    /// holds the mutex only long enough to clone the `Vec`.
    pub fn stderr_tail_snapshot(&self) -> String {
        match &self.stderr_tail {
            Some(buf) => match buf.lock() {
                Ok(g) => g.join("\n"),
                Err(_) => String::new(),
            },
            None => String::new(),
        }
    }
}

/// How to create worktrees + claim leases + spawn the claude CLI. Injecting
/// this makes `dispatch_gap` unit-testable without forking real processes
/// (which would burn budget and require a live `claude` binary).
pub trait Spawner {
    fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()>;
    fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()>;
    /// Returns `(child, stderr_tail)` — the child handle and an optional
    /// shared buffer the spawner attached to a stderr-tailing thread.
    /// Test spawners that don't fork a real process return `(None, None)`.
    fn spawn_claude(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult>;
}

/// Production spawner: shells out to git, gap-claim.sh, and the `claude` CLI.
pub struct RealSpawner;

impl Spawner for RealSpawner {
    fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()> {
        let status = Command::new("git")
            .args([
                "worktree",
                "add",
                worktree.to_str().context("worktree path not utf-8")?,
                "-b",
                branch,
                base,
            ])
            .status()
            .context("spawning git worktree add")?;
        if !status.success() {
            bail!("git worktree add failed for {}", worktree.display());
        }
        Ok(())
    }

    fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()> {
        // gap-claim.sh refuses from the main worktree root, so cwd MUST be the
        // new linked worktree. That's the caller's contract.
        let script = worktree.join("scripts").join("gap-claim.sh");
        let status = Command::new("bash")
            .arg(script)
            .arg(gap_id)
            .current_dir(worktree)
            .status()
            .context("spawning gap-claim.sh")?;
        if !status.success() {
            bail!("gap-claim.sh failed for {gap_id} in {}", worktree.display());
        }
        Ok(())
    }

    fn spawn_claude(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
        // INFRA-DISPATCH-FAULT-INJECTION: when CHUMP_FAULT_INJECT is set,
        // short-circuit to a synthetic process instead of the real backend.
        // This lets callers exercise dispatch/monitor/retry paths without a
        // live `claude` binary or a GitHub account.
        if let Some(fault) = active_fault_mode() {
            return spawn_fault_process(fault);
        }
        // COG-025: branch on $CHUMP_DISPATCH_BACKEND. Default = `claude`,
        // preserving AUTO-013 baseline behaviour for any caller that hasn't
        // opted in. `chump-local` swaps in `target/release/chump --execute-gap`
        // — Chump's own multi-turn agent loop driven by whatever provider
        // OPENAI_API_BASE+OPENAI_MODEL resolve to (Together free tier,
        // mistral.rs, Ollama, hosted OpenAI). Cost-routing path.
        match DispatchBackend::from_env() {
            DispatchBackend::Claude => self.spawn_claude_cli(worktree, prompt),
            DispatchBackend::ChumpLocal => self.spawn_chump_local(worktree, prompt),
        }
    }
}

/// Spawn the synthetic process for the given fault mode (or return an error
/// for `SpawnFail`). Used by both `RealSpawner` and any test harness that
/// wants to exercise this path without a full dispatch flow.
pub fn spawn_fault_process(fault: FaultMode) -> Result<SpawnResult> {
    match fault {
        FaultMode::SpawnFail => {
            bail!("[fault-inject] spawn_fail: dispatch returns error immediately");
        }
        FaultMode::Exit1 => {
            // Exits non-zero after 100 ms — triggers Killed("exit code 1").
            let child = Command::new("sh")
                .args(["-c", "sleep 0.1; exit 1"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .context("[fault-inject] exit_1: spawning sh")?;
            Ok((Some(child), None))
        }
        FaultMode::Exit0NoPr => {
            // Exits 0 after 100 ms with no PR number in output — tests the
            // clean-exit-no-PR monitor path (process exits OK but agent never
            // opened a PR; monitor waits for the soft-deadline ladder).
            let child = Command::new("sh")
                .args(["-c", "sleep 0.1; exit 0"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .context("[fault-inject] exit_0_no_pr: spawning sh")?;
            Ok((Some(child), None))
        }
        FaultMode::MonitorTimeout => {
            // Runs for 1 hour — the monitor's deadline ladder fires first.
            // Tests use a tiny `soft_deadline_secs` (e.g. 1 s) so this
            // resolves in milliseconds without burning real time.
            let child = Command::new("sh")
                .args(["-c", "sleep 3600"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .context("[fault-inject] monitor_timeout: spawning sh")?;
            Ok((Some(child), None))
        }
    }
}

impl RealSpawner {
    /// Original AUTO-013 spawn — `claude -p <prompt>` via claude-retry.sh.
    fn spawn_claude_cli(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
        // `claude -p <prompt>` is non-interactive. CWD is the worktree.
        // CHUMP_DISPATCH_DEPTH=1 prevents recursive dispatch in the child.
        //
        // We invoke through scripts/claude-retry.sh (INFRA-CHUMP-API-RETRY,
        // shipped 2026-04-19) which wraps claude with retry-on-transient-5xx.
        // Override the binary via env CHUMP_CLAUDE_BIN for tests.
        // Fallback to bare `claude` if the wrapper isn't found (e.g. running
        // from outside the repo).
        //
        // stderr is piped + tailed in a background thread so the AUTO-013
        // step-4 dispatch reflection can include WARN/ERROR lines without
        // buffering the whole transcript. The buffer is bounded by
        // [`STDERR_TAIL_CAP`].
        let claude_bin = std::env::var("CHUMP_CLAUDE_BIN").unwrap_or_else(|_| {
            // Look up the wrapper relative to the orchestrator's worktree
            // (cwd of the parent process). If found, use it; else fall back
            // to bare `claude`.
            let wrapper = std::env::current_dir()
                .ok()
                .map(|d| d.join("scripts").join("claude-retry.sh"));
            match wrapper {
                Some(p) if p.exists() => p.to_string_lossy().into_owned(),
                _ => "claude".to_string(),
            }
        });
        // INFRA-DISPATCH-PERMISSIONS-FLAG (2026-04-19): the dispatched
        // subagent runs unattended (no terminal, no human) so per-tool
        // permission prompts cause the subprocess to STALL forever (caught
        // by autonomy-test V3, marked STALLED by monitor at soft-deadline).
        // --dangerously-skip-permissions is appropriate here: the subagent
        // IS sandboxed-by-context (its own worktree, gap-scoped, atomic PR).
        let mut child = Command::new(&claude_bin)
            .arg("-p")
            .arg(prompt)
            .arg("--dangerously-skip-permissions")
            .current_dir(worktree)
            .env("CHUMP_DISPATCH_DEPTH", "1")
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("spawning claude CLI via {claude_bin}"))?;

        let buf: StderrTail = Arc::new(Mutex::new(Vec::new()));
        if let Some(stderr) = child.stderr.take() {
            let buf_thread = Arc::clone(&buf);
            std::thread::Builder::new()
                .name("orchestrator-stderr-tail".into())
                .spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        // Cheap filter — only retain lines that look like
                        // diagnostic noise. PRODUCT-006 wants signals,
                        // not the full info-stream.
                        let upper = line.to_uppercase();
                        if upper.contains("ERROR")
                            || upper.contains("WARN")
                            || upper.contains("FAIL")
                            || upper.contains("PANIC")
                        {
                            if let Ok(mut g) = buf_thread.lock() {
                                if g.len() >= STDERR_TAIL_CAP {
                                    // Drop oldest; keep the most-recent
                                    // window (terminal failures cluster
                                    // near the end of the transcript).
                                    g.remove(0);
                                }
                                g.push(line);
                            }
                        }
                    }
                })
                .ok(); // best-effort — failing to spawn the tailer must
                       // not abort dispatch.
        }

        Ok((Some(child), Some(buf)))
    }

    /// COG-025 backend: spawn `chump --execute-gap <GAP-ID>` so the dispatched
    /// subagent runs through Chump's own multi-turn agent loop (provider =
    /// $OPENAI_API_BASE+$OPENAI_MODEL — Together/mistral.rs/Ollama/OpenAI).
    ///
    /// The chump binary is resolved (in priority order):
    ///   1. `$CHUMP_LOCAL_BIN` — explicit override (tests, custom builds).
    ///   2. `<worktree>/target/release/chump` — typical release build.
    ///   3. `<worktree>/target/debug/chump` — dev fallback.
    ///   4. bare `chump` on $PATH — last resort.
    ///
    /// We pass through any OPENAI_* env the parent process holds so the
    /// caller's provider config flows into the child without a config file.
    fn spawn_chump_local(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
        // Resolve gap id from the prompt. The prompt is the canonical
        // `build_prompt` output ("...working on gap <ID>...") so a cheap
        // tokenizer is enough; we don't need to thread the id through the
        // trait (which would break the back-compat contract).
        let gap_id = parse_gap_id_from_prompt(prompt).ok_or_else(|| {
            anyhow::anyhow!(
                "spawn_chump_local: could not extract gap id from prompt — \
                 expected `working on gap <ID>` token"
            )
        })?;

        let bin = resolve_chump_local_bin(worktree);
        let mut cmd = Command::new(&bin);
        cmd.arg("--execute-gap")
            .arg(&gap_id)
            .current_dir(worktree)
            .env("CHUMP_DISPATCH_DEPTH", "1")
            .env("CHUMP_DISPATCH_BACKEND_LABEL", "chump-local")
            .stderr(Stdio::piped());

        // Pass through provider env explicitly so the child inherits it
        // even when the parent was launched with a stripped env (e.g. cron).
        // (Command::new already inherits the parent env by default — these
        // calls are belt-and-braces and document the contract.)
        for var in ["OPENAI_API_BASE", "OPENAI_MODEL", "OPENAI_API_KEY"] {
            if let Ok(v) = std::env::var(var) {
                cmd.env(var, v);
            }
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawning chump-local backend via {}", bin.display()))?;

        let buf: StderrTail = Arc::new(Mutex::new(Vec::new()));
        if let Some(stderr) = child.stderr.take() {
            let buf_thread = Arc::clone(&buf);
            std::thread::Builder::new()
                .name("orchestrator-stderr-tail-chump-local".into())
                .spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        let upper = line.to_uppercase();
                        if upper.contains("ERROR")
                            || upper.contains("WARN")
                            || upper.contains("FAIL")
                            || upper.contains("PANIC")
                        {
                            if let Ok(mut g) = buf_thread.lock() {
                                if g.len() >= STDERR_TAIL_CAP {
                                    g.remove(0);
                                }
                                g.push(line);
                            }
                        }
                    }
                })
                .ok();
        }

        Ok((Some(child), Some(buf)))
    }
}

/// Resolve the chump binary used by the `chump-local` backend. Priority:
/// `$CHUMP_LOCAL_BIN` → `<worktree>/target/release/chump` →
/// `<worktree>/target/debug/chump` → bare `chump`.
fn resolve_chump_local_bin(worktree: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_LOCAL_BIN") {
        return PathBuf::from(p);
    }
    // Try the worktree-local target/ first; subagents typically share the
    // top-level Cargo workspace, so target/ lives in the parent repo, not
    // the linked worktree. Walk up to find the closest `target/release/chump`.
    let mut probe = worktree.to_path_buf();
    for _ in 0..5 {
        let release = probe.join("target/release/chump");
        if release.is_file() {
            return release;
        }
        let debug = probe.join("target/debug/chump");
        if debug.is_file() {
            return debug;
        }
        if !probe.pop() {
            break;
        }
    }
    PathBuf::from("chump")
}

/// Extract the gap id from a `build_prompt`-shaped prompt string. Returns
/// `None` if the marker `working on gap ` isn't present (e.g. the caller
/// hand-crafted a prompt that doesn't follow the contract).
fn parse_gap_id_from_prompt(prompt: &str) -> Option<String> {
    let marker = "working on gap ";
    let start = prompt.find(marker)? + marker.len();
    let rest = &prompt[start..];
    // Gap id ends at the first whitespace, period, or punctuation.
    let end = rest
        .find(|c: char| !(c.is_ascii_uppercase() || c.is_ascii_digit() || c == '-'))
        .unwrap_or(rest.len());
    let id = &rest[..end];
    if id.is_empty() {
        None
    } else {
        Some(id.to_string())
    }
}

/// Build the prompt handed to the dispatched subagent. See
/// `docs/TEAM_OF_AGENTS.md` — the contract every dispatched subagent follows.
///
/// `repo_root` is used to read `docs/CHUMP_DISPATCH_RULES.md` — the distilled
/// coordination rules injected inline so both `claude` and `chump-local`
/// backends receive them regardless of whether they read files unprompted.
pub fn build_prompt(gap_id: &str, repo_root: &Path) -> String {
    let rules =
        std::fs::read_to_string(repo_root.join("docs/CHUMP_DISPATCH_RULES.md")).unwrap_or_default();
    let rules_block = if rules.is_empty() {
        String::new()
    } else {
        format!("{rules}\n\n---\n\n")
    };
    format!(
        "{rules}You are a Chump dispatched agent working on gap {gap}. \
The gap is already claimed in this worktree. \
Read the gap entry in docs/gaps.yaml for full acceptance criteria. \
Do the work, then ship via:\n  scripts/bot-merge.sh --gap {gap} --auto-merge\n\
After ship, exit. Reply ONLY with the PR number.",
        rules = rules_block,
        gap = gap_id
    )
}

/// Derive the worktree path + branch name for a gap. Lowercased, underscores
/// rewritten to hyphens (matching the conventions in musher.sh and the
/// existing `.claude/worktrees/<name>/` tree).
pub fn dispatch_paths(repo_root: &Path, gap_id: &str) -> (PathBuf, String) {
    let slug = gap_id.to_ascii_lowercase().replace('_', "-");
    let worktree = repo_root.join(".claude").join("worktrees").join(&slug);
    let branch = format!("claude/{slug}");
    (worktree, branch)
}

/// Dispatch a single gap. Creates the worktree, claims the lease, spawns
/// `claude -p <prompt>`, returns a handle for the monitor loop.
///
/// `repo_root` is the top-level git repo. `base_ref` is the git ref the new
/// worktree branches off (caller typically passes `"origin/main"`).
pub fn dispatch_gap_with<S: Spawner>(
    spawner: &S,
    gap: &Gap,
    repo_root: &Path,
    base_ref: &str,
) -> Result<DispatchHandle> {
    let (worktree, branch) = dispatch_paths(repo_root, &gap.id);

    spawner
        .create_worktree(&worktree, &branch, base_ref)
        .with_context(|| format!("creating worktree {} for {}", worktree.display(), gap.id))?;

    spawner
        .claim_gap(&worktree, &gap.id)
        .with_context(|| format!("claiming lease for {} in {}", gap.id, worktree.display()))?;

    let prompt = build_prompt(&gap.id, repo_root);
    let (child, stderr_tail) = spawner
        .spawn_claude(&worktree, &prompt)
        .with_context(|| format!("spawning claude for {}", gap.id))?;

    let pid = child.as_ref().map(|c| c.id());
    let started_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before UNIX epoch")?
        .as_secs();

    Ok(DispatchHandle {
        gap_id: gap.id.clone(),
        worktree_path: worktree,
        branch_name: branch,
        child_pid: pid,
        started_at_unix,
        child,
        stderr_tail,
        backend: DispatchBackend::from_env(),
    })
}

/// Production entry point: dispatch a gap using the real `RealSpawner`.
pub fn dispatch_gap(gap: &Gap, repo_root: &Path, base_ref: &str) -> Result<DispatchHandle> {
    dispatch_gap_with(&RealSpawner, gap, repo_root, base_ref)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Test spawner that records every call and never touches the real
    /// filesystem or forks a process. This is the contract enforcement: the
    /// dispatch flow must call create_worktree → claim_gap → spawn_claude in
    /// order, with the correctly-derived paths.
    #[derive(Default)]
    struct RecordingSpawner {
        calls: RefCell<Vec<String>>,
    }

    impl Spawner for RecordingSpawner {
        fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()> {
            self.calls.borrow_mut().push(format!(
                "worktree:{}:{}:{}",
                worktree.display(),
                branch,
                base
            ));
            Ok(())
        }
        fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()> {
            self.calls
                .borrow_mut()
                .push(format!("claim:{}:{}", worktree.display(), gap_id));
            Ok(())
        }
        fn spawn_claude(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
            self.calls
                .borrow_mut()
                .push(format!("spawn:{}:{}", worktree.display(), prompt.len()));
            Ok((None, None))
        }
    }

    fn fake_gap(id: &str) -> Gap {
        Gap {
            id: id.into(),
            title: "t".into(),
            priority: "P1".into(),
            effort: "m".into(),
            status: "open".into(),
            depends_on: None,
        }
    }

    #[test]
    fn dispatch_paths_lowercases_and_replaces_underscores() {
        let (wt, branch) = dispatch_paths(Path::new("/repo"), "AUTO_013");
        assert_eq!(wt, PathBuf::from("/repo/.claude/worktrees/auto-013"));
        assert_eq!(branch, "claude/auto-013");
    }

    #[test]
    fn dispatch_calls_steps_in_order() {
        let spawner = RecordingSpawner::default();
        let gap = fake_gap("AUTO-013");
        let handle = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();

        let calls = spawner.calls.borrow();
        assert_eq!(calls.len(), 3);
        assert!(calls[0].starts_with("worktree:"), "first call = worktree");
        assert!(calls[1].starts_with("claim:"), "second call = claim");
        assert!(calls[2].starts_with("spawn:"), "third call = spawn");

        assert_eq!(handle.gap_id, "AUTO-013");
        assert_eq!(handle.branch_name, "claude/auto-013");
        assert_eq!(
            handle.worktree_path,
            PathBuf::from("/repo/.claude/worktrees/auto-013")
        );
        assert!(handle.child_pid.is_none(), "recording spawner = no pid");
        assert!(handle.started_at_unix > 0);
    }

    #[test]
    fn claim_receives_exact_gap_id() {
        let spawner = RecordingSpawner::default();
        let gap = fake_gap("EVAL-031");
        let _ = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
        let calls = spawner.calls.borrow();
        assert!(
            calls[1].ends_with(":EVAL-031"),
            "claim must pass exact gap id, got {}",
            calls[1]
        );
    }

    #[test]
    fn build_prompt_contains_gap_id_and_ship_command() {
        let prompt = build_prompt("AUTO-013", Path::new("/nonexistent"));
        assert!(prompt.contains("AUTO-013"));
        assert!(prompt.contains("scripts/bot-merge.sh --gap AUTO-013 --auto-merge"));
        assert!(prompt.contains("PR number"));
    }

    #[test]
    fn build_prompt_injects_dispatch_rules_when_file_present() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs");
        std::fs::create_dir(&docs).unwrap();
        std::fs::write(
            docs.join("CHUMP_DISPATCH_RULES.md"),
            "## rule\n- do the thing\n",
        )
        .unwrap();
        let prompt = build_prompt("MEM-001", dir.path());
        assert!(
            prompt.contains("do the thing"),
            "rules block should be injected"
        );
        assert!(prompt.contains("MEM-001"));
    }

    #[test]
    fn build_prompt_gracefully_missing_rules_file() {
        let prompt = build_prompt("EVAL-001", Path::new("/nonexistent"));
        assert!(prompt.contains("EVAL-001"));
        assert!(prompt.contains("bot-merge.sh"));
    }

    #[test]
    fn stderr_tail_snapshot_returns_empty_when_no_buffer() {
        let h = DispatchHandle {
            gap_id: "X".into(),
            worktree_path: PathBuf::from("/tmp"),
            branch_name: "claude/x".into(),
            child_pid: None,
            started_at_unix: 0,
            child: None,
            stderr_tail: None,
            backend: DispatchBackend::Claude,
        };
        assert_eq!(h.stderr_tail_snapshot(), "");
    }

    #[test]
    fn stderr_tail_snapshot_joins_lines_with_newlines() {
        let buf = Arc::new(Mutex::new(vec![
            "ERROR: foo".to_string(),
            "WARN: bar".to_string(),
        ]));
        let h = DispatchHandle {
            gap_id: "X".into(),
            worktree_path: PathBuf::from("/tmp"),
            branch_name: "claude/x".into(),
            child_pid: None,
            started_at_unix: 0,
            child: None,
            stderr_tail: Some(buf),
            backend: DispatchBackend::Claude,
        };
        assert_eq!(h.stderr_tail_snapshot(), "ERROR: foo\nWARN: bar");
    }

    // ── COG-025: backend selector ────────────────────────────────────────

    /// Run a closure with `CHUMP_DISPATCH_BACKEND` set to `value` and
    /// restore the previous env after, even on panic. Required because
    /// `from_env` reads process env and tests run in the same process.
    fn with_backend_env(value: Option<&str>, f: impl FnOnce()) {
        let prev = std::env::var("CHUMP_DISPATCH_BACKEND").ok();
        match value {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_BACKEND", v),
            None => std::env::remove_var("CHUMP_DISPATCH_BACKEND"),
        }
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
        match prev {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_BACKEND", v),
            None => std::env::remove_var("CHUMP_DISPATCH_BACKEND"),
        }
        if let Err(e) = result {
            std::panic::resume_unwind(e);
        }
    }

    #[test]
    #[serial_test::serial]
    fn backend_default_is_claude() {
        with_backend_env(None, || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::Claude);
        });
    }

    #[test]
    #[serial_test::serial]
    fn backend_recognises_chump_local() {
        with_backend_env(Some("chump-local"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::ChumpLocal);
        });
        with_backend_env(Some("chump_local"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::ChumpLocal);
        });
        with_backend_env(Some("local"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::ChumpLocal);
        });
    }

    #[test]
    #[serial_test::serial]
    fn backend_unknown_falls_back_to_claude() {
        with_backend_env(Some("ollama-direct"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::Claude);
        });
        with_backend_env(Some(""), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::Claude);
        });
    }

    #[test]
    fn backend_label_is_stable() {
        // Reflection rows depend on these labels — changing them silently
        // breaks downstream A/B aggregation in COG-026.
        assert_eq!(DispatchBackend::Claude.label(), "claude");
        assert_eq!(DispatchBackend::ChumpLocal.label(), "chump-local");
    }

    #[test]
    #[serial_test::serial]
    fn dispatch_handle_records_backend() {
        // The handle's `backend` field must reflect the env at dispatch time.
        with_backend_env(Some("chump-local"), || {
            let spawner = RecordingSpawner::default();
            let gap = fake_gap("COG-025");
            let h = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
            assert_eq!(h.backend, DispatchBackend::ChumpLocal);
        });
        with_backend_env(None, || {
            let spawner = RecordingSpawner::default();
            let gap = fake_gap("COG-025");
            let h = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
            assert_eq!(h.backend, DispatchBackend::Claude);
        });
    }

    #[test]
    fn parse_gap_id_from_prompt_extracts_canonical() {
        let prompt = build_prompt("COG-025", Path::new("/nonexistent"));
        assert_eq!(
            parse_gap_id_from_prompt(&prompt).as_deref(),
            Some("COG-025")
        );
        let p2 = build_prompt("AUTO-013", Path::new("/nonexistent"));
        assert_eq!(parse_gap_id_from_prompt(&p2).as_deref(), Some("AUTO-013"));
    }

    #[test]
    fn parse_gap_id_from_prompt_returns_none_on_unknown_shape() {
        assert_eq!(parse_gap_id_from_prompt("hello world"), None);
        assert_eq!(parse_gap_id_from_prompt(""), None);
        // marker present but no id after
        assert_eq!(
            parse_gap_id_from_prompt("working on gap "),
            None,
            "empty id after marker should yield None"
        );
    }

    #[test]
    fn resolve_chump_local_bin_honors_env_override() {
        std::env::set_var("CHUMP_LOCAL_BIN", "/opt/custom/chump");
        let p = resolve_chump_local_bin(Path::new("/nonexistent/worktree"));
        std::env::remove_var("CHUMP_LOCAL_BIN");
        assert_eq!(p, PathBuf::from("/opt/custom/chump"));
    }

    #[test]
    fn resolve_chump_local_bin_falls_back_to_path_when_no_target() {
        // Use a dir that definitely has no target/ tree.
        std::env::remove_var("CHUMP_LOCAL_BIN");
        let p = resolve_chump_local_bin(Path::new("/tmp/cog-025-no-target-here-xyz"));
        assert_eq!(p, PathBuf::from("chump"));
    }

    #[test]
    fn worktree_create_failure_aborts_claim_and_spawn() {
        struct FailingWorktree;
        impl Spawner for FailingWorktree {
            fn create_worktree(&self, _w: &Path, _b: &str, _r: &str) -> Result<()> {
                bail!("worktree add failed");
            }
            fn claim_gap(&self, _w: &Path, _g: &str) -> Result<()> {
                panic!("must not be called");
            }
            fn spawn_claude(&self, _w: &Path, _p: &str) -> Result<SpawnResult> {
                panic!("must not be called");
            }
        }
        let gap = fake_gap("AUTO-013");
        let err = dispatch_gap_with(&FailingWorktree, &gap, Path::new("/repo"), "origin/main")
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("worktree add failed"), "got: {msg}");
    }
}
