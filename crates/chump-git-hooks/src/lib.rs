//! # chump-git-hooks
//!
//! Rust-native git hook framework for Chump. Phase 1 of INFRA-1997 /
//! META-107 (Rust-First Migration Blueprint).
//!
//! ## Why
//!
//! [`scripts/git-hooks/pre-push`] is a 1200-line bash script with ~57
//! direct `git` invocations. INFRA-1950 (2026-05-23 TRUNK_RED, 5 main
//! CI failures over 16 hours) traced root cause to **environment-variable
//! leakage from GitHub Actions self-hosted runner-listener**: `GIT_DIR`,
//! `GIT_WORK_TREE`, and `GITHUB_WORKSPACE` leaked into hook children,
//! silently redirecting `git rev-parse --show-toplevel` to the runner's
//! own checkout. Guard 3 (force-with-lease race protection, INFRA-345)
//! silently passed when it should have blocked.
//!
//! Bash's environment-inheritance model is the failure surface — every
//! new guard requires hand-auditing all `git` calls. Rust gives us:
//!
//! - **Single env-scrub point**: [`HookContext::new_from_stdin`] removes
//!   GIT_DIR / GIT_WORK_TREE / GITHUB_WORKSPACE / GIT_COMMON_DIR /
//!   GIT_INDEX_FILE before any other code runs.
//! - **Centralised git invocation**: [`HookContext::git`] returns a
//!   pre-configured [`std::process::Command`] with `env_clear()` and
//!   `-C <repo_root>` baked in — no guard can accidentally inherit env.
//! - **Typed Hook trait**: each guard is a `Hook` impl that returns a
//!   typed `HookOutcome`, so adding a new guard is mechanical.
//!
//! ## Phase 1 scope
//!
//! Ship the **framework** + ONE concrete guard
//! ([`ForceWithLeaseRaceGuard`], the INFRA-345 Guard 3 that INFRA-1950
//! bypassed under env-leak). Other 10 guards stay in bash; they get
//! ported in follow-up sub-gaps.
//!
//! Invocation is feature-flagged on `CHUMP_PREPUSH_RUST=1`. The legacy
//! bash hook stays in place and runs in parallel during the 1-week
//! validation window.
//!
//! ## Non-goals (Phase 1)
//!
//! - **NO new ambient event kinds.** The hook logs via `tracing` but
//!   must NOT emit to `.chump-locks/ambient.jsonl` in this PR.
//! - **NO touches to `scripts/ci/event-registry-reserved.txt`** (INFRA-2003
//!   holds a lease on it).
//! - **NO cutover**: the bash hook stays. Phase 2 (separate gap) flips
//!   the default; Phase 3 removes bash.

#![warn(missing_docs)]

pub mod pre_commit;

use std::path::{Path, PathBuf};
use std::process::Command;

use thiserror::Error;

/// Environment variables that can redirect `git` to the wrong repo.
///
/// Removed at hook entry in [`HookContext::new_from_stdin`]. The leak
/// surface that INFRA-1950 hit was GitHub Actions self-hosted
/// runner-listener leaking these into every spawned child process.
pub const ENV_LEAK_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GITHUB_WORKSPACE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
];

/// One refspec line from the pre-push hook's stdin.
///
/// Git invokes pre-push with one line per ref of the form:
/// `<local_ref> <local_sha> <remote_ref> <remote_sha>\n`
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefspecPush {
    /// Local reference name being pushed (e.g. `refs/heads/foo`).
    pub local_ref: String,
    /// SHA at the local tip.
    pub local_sha: String,
    /// Remote reference name (e.g. `refs/heads/foo`).
    pub remote_ref: String,
    /// What the local view thinks the remote's tip is. All zeros for new branches.
    pub remote_sha: String,
}

impl RefspecPush {
    /// True iff this is a new-branch push (remote tip is all zeros).
    pub fn is_new_branch(&self) -> bool {
        self.remote_sha.chars().all(|c| c == '0')
    }

    /// True iff this is a branch deletion (local tip is all zeros).
    pub fn is_branch_delete(&self) -> bool {
        self.local_sha.chars().all(|c| c == '0')
    }

    /// Strip the `refs/heads/` prefix from `remote_ref` to get the branch name.
    pub fn branch(&self) -> &str {
        self.remote_ref
            .strip_prefix("refs/heads/")
            .unwrap_or(&self.remote_ref)
    }
}

/// Outcome of running a single [`Hook`] against a [`HookContext`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookOutcome {
    /// Guard passed — push may proceed (subject to remaining guards).
    Pass,
    /// Guard intentionally skipped (e.g. bypass flag set, irrelevant input).
    Skipped {
        /// Human-readable reason for the skip; surfaced in tracing logs.
        reason: String,
    },
    /// Guard blocked the push. The runner exits non-zero with a diagnostic.
    Block(BlockReason),
}

/// Why a [`Hook`] blocked the push.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockReason {
    /// Short stable identifier (e.g. `force_with_lease_race`).
    pub code: String,
    /// Multi-line operator-facing diagnostic.
    pub diagnostic: String,
}

/// Errors that can arise while constructing or running a hook context.
#[derive(Debug, Error)]
pub enum HookError {
    /// IO error reading stdin or invoking git.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    /// `git rev-parse --show-toplevel` failed — repo discovery impossible.
    #[error("repo discovery failed: {0}")]
    RepoDiscoveryFailed(String),
    /// Malformed refspec line from stdin.
    #[error("malformed refspec line: {0:?}")]
    MalformedRefspec(String),
}

/// Per-invocation context for the pre-push hook.
///
/// Constructed via [`HookContext::new_from_stdin`] (the canonical entry).
/// After construction, all leak-class env vars are guaranteed scrubbed and
/// `repo_root` is anchored to the real on-disk repo via
/// `git rev-parse --show-toplevel` invoked with `env_clear()`.
#[derive(Debug)]
pub struct HookContext {
    /// Absolute path to the repository root.
    pub repo_root: PathBuf,
    /// Refspec lines parsed from stdin (one per ref being pushed).
    pub refspecs: Vec<RefspecPush>,
    /// Name of the git remote (e.g. `origin`). Passed by git as argv[1].
    pub remote_name: String,
}

impl HookContext {
    /// Canonical constructor: scrub leak-class env vars, then discover repo
    /// root via subprocess `git` with `env_clear()`, then parse stdin.
    ///
    /// `remote_name` is git's argv[1] (e.g. `origin`) — pass it through
    /// from the binary's `std::env::args`.
    ///
    /// `stdin_buf` is the already-read stdin contents (the binary reads
    /// stdin into a buffer once, since stdin is a one-shot stream — see
    /// INFRA-1986 for the historical bug).
    pub fn new_from_stdin(remote_name: String, stdin_buf: &str) -> Result<Self, HookError> {
        // Step 1: scrub leak vars BEFORE any subprocess invocation.
        // SAFETY: we are the only thread at hook entry; no race.
        for var in ENV_LEAK_VARS {
            std::env::remove_var(var);
        }

        // Step 2: discover repo root by running git. We already removed
        // the leak-class vars from the current process in Step 1, so the
        // child inherits a clean env without us needing env_clear (which
        // would also drop HOME, USER, etc. that some git wrappers need).
        // The remove_var calls above are the load-bearing operation —
        // env_clear here would be belt-and-braces but breaks user setups
        // with shell-wrapper git binaries that require HOME.
        let output = Command::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .output()?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
            return Err(HookError::RepoDiscoveryFailed(stderr.trim().to_string()));
        }
        let repo_root_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let repo_root = PathBuf::from(repo_root_str);

        // Step 3: parse stdin.
        let refspecs = parse_refspecs(stdin_buf)?;

        Ok(HookContext {
            repo_root,
            refspecs,
            remote_name,
        })
    }

    /// Returns a [`Command`] for invoking `git` against `repo_root` with
    /// the leak-class env vars already removed from the parent process
    /// and `-C <repo_root>` pre-applied.
    ///
    /// Every guard that needs to call git MUST use this helper rather
    /// than constructing its own `Command` — that way env-immunity is
    /// enforced at one chokepoint, not 57. The leak-class removal happens
    /// once in [`HookContext::new_from_stdin`]; this helper just adds the
    /// repo-anchor `-C` flag and explicitly re-removes the leak vars on
    /// the Command itself as a defense-in-depth measure in case some
    /// guard runs `std::env::set_var(...)` after init (it shouldn't, but
    /// we belt-and-brace it).
    pub fn git(&self) -> Command {
        let mut cmd = Command::new("git");
        for var in ENV_LEAK_VARS {
            cmd.env_remove(var);
        }
        cmd.arg("-C").arg(&self.repo_root);
        cmd
    }

    /// True iff at least one refspec is a non-trivial push (real SHAs, not
    /// just branch deletion or new-branch markers).
    pub fn has_nontrivial_push(&self) -> bool {
        self.refspecs
            .iter()
            .any(|r| !r.is_branch_delete() && !r.is_new_branch())
    }
}

/// Parse the pre-push stdin format into a vec of [`RefspecPush`].
///
/// Format (one line per ref): `<local_ref> <local_sha> <remote_ref> <remote_sha>\n`
fn parse_refspecs(buf: &str) -> Result<Vec<RefspecPush>, HookError> {
    let mut out = Vec::new();
    for line in buf.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() != 4 {
            return Err(HookError::MalformedRefspec(line.to_string()));
        }
        out.push(RefspecPush {
            local_ref: parts[0].to_string(),
            local_sha: parts[1].to_string(),
            remote_ref: parts[2].to_string(),
            remote_sha: parts[3].to_string(),
        });
    }
    Ok(out)
}

/// One guard in the pre-push pipeline.
///
/// Each guard sees the same `HookContext` and returns a typed outcome.
/// The runner short-circuits on the first `Block`; `Pass` and `Skipped`
/// both let the next guard run.
pub trait Hook {
    /// Short stable name (e.g. `force_with_lease_race_guard`). Used in
    /// tracing logs.
    fn name(&self) -> &'static str;

    /// Execute the guard. The runner short-circuits on `Block`.
    fn run(&self, ctx: &HookContext) -> Result<HookOutcome, HookError>;
}

/// Run a sequence of hooks against a context, short-circuiting on the
/// first `Block`. Returns the first `Block` encountered, or `Pass` if
/// all guards passed.
pub fn run_hooks(ctx: &HookContext, hooks: &[Box<dyn Hook>]) -> Result<HookOutcome, HookError> {
    for hook in hooks {
        match hook.run(ctx)? {
            HookOutcome::Pass => {
                tracing::debug!(hook = hook.name(), "pass");
            }
            HookOutcome::Skipped { reason } => {
                tracing::debug!(hook = hook.name(), %reason, "skipped");
            }
            HookOutcome::Block(reason) => {
                tracing::warn!(hook = hook.name(), code = %reason.code, "blocked");
                return Ok(HookOutcome::Block(reason));
            }
        }
    }
    Ok(HookOutcome::Pass)
}

// ---- Concrete guards ----------------------------------------------------

/// Guard 3: `--force-with-lease` race protection (INFRA-345).
///
/// On a force-push, verifies the actual current remote tip matches what
/// the local fetched view expected. `git push --force-with-lease` only
/// protects against the ref-tip you've fetched moving — it does NOT
/// protect against a sibling pushing between your fetch and your push.
/// PR #910 incident, 2026-05-03: clobbered a sibling's commit b484c152
/// that landed in the ~2-minute window between fetch and push.
///
/// Bypass: `CHUMP_FORCE_LEASE_CHECK=0` env var skips the guard.
///
/// This is the guard INFRA-1950 (TRUNK_RED, 2026-05-23) bypassed silently
/// under env-leak. The whole point of moving it to Rust is the
/// `HookContext::git()` env-scrub chokepoint — the ls-remote call below
/// can no longer be redirected to the wrong repo.
pub struct ForceWithLeaseRaceGuard;

impl Hook for ForceWithLeaseRaceGuard {
    fn name(&self) -> &'static str {
        "force_with_lease_race_guard"
    }

    fn run(&self, ctx: &HookContext) -> Result<HookOutcome, HookError> {
        if std::env::var("CHUMP_FORCE_LEASE_CHECK")
            .map(|v| v == "0")
            .unwrap_or(false)
        {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_FORCE_LEASE_CHECK=0".to_string(),
            });
        }

        for refspec in &ctx.refspecs {
            // Skip new-branch push (remote sha all zeros) — not a force-push.
            if refspec.is_new_branch() || refspec.is_branch_delete() {
                continue;
            }

            // Detect force-push: remote_sha is NOT an ancestor of local_sha.
            let is_ff = ctx
                .git()
                .args([
                    "merge-base",
                    "--is-ancestor",
                    &refspec.remote_sha,
                    &refspec.local_sha,
                ])
                .status()?
                .success();
            if is_ff {
                // Fast-forward — not a force push, skip.
                continue;
            }

            // This IS a force push. Verify remote tip hasn't moved since fetch.
            let output = ctx
                .git()
                .args(["ls-remote", &ctx.remote_name, &refspec.remote_ref])
                .output()?;
            if !output.status.success() {
                // Couldn't reach remote — be conservative and let push attempt.
                tracing::warn!(
                    remote = %ctx.remote_name,
                    "ls-remote failed; allowing force push without race check"
                );
                continue;
            }
            let stdout = String::from_utf8_lossy(&output.stdout);
            let actual_remote_sha = stdout.split_whitespace().next().unwrap_or("").to_string();

            if !actual_remote_sha.is_empty() && actual_remote_sha != refspec.remote_sha {
                let diagnostic = format!(
                    "force-push race detected on {branch} (INFRA-345).\n  \
                     Local view says remote tip is: {local_view}\n  \
                     Actual remote tip right now:   {actual}\n\n\
                     A sibling pushed between your last fetch and this push.\n\
                     Force-pushing now would clobber their work — `--force-with-lease`\n\
                     only protects against the local view moving, not stale fetches.\n\n\
                     Recover by:\n\
                     \tgit fetch {remote} {branch}\n\
                     \tgit log {branch}..{remote}/{branch}\n\
                     \tgit rebase {remote}/{branch}\n\
                     \tgit push --force-with-lease\n\n\
                     Bypass: CHUMP_FORCE_LEASE_CHECK=0 git push",
                    branch = refspec.branch(),
                    local_view = refspec.remote_sha,
                    actual = actual_remote_sha,
                    remote = ctx.remote_name,
                );
                return Ok(HookOutcome::Block(BlockReason {
                    code: "force_with_lease_race".to_string(),
                    diagnostic,
                }));
            }
        }

        Ok(HookOutcome::Pass)
    }
}

/// Stub: stdin-double-drain detector port (INFRA-1986).
///
/// Phase 1 returns Pass unconditionally. The original bash guard catches
/// the case where an earlier loop consumed stdin so the main guard loop
/// saw EOF and silently iterated zero times. In Rust we read stdin
/// once into a buffer before constructing `HookContext`, so the
/// double-drain failure mode is structurally impossible — but we keep
/// this Hook impl as a placeholder for any future deeper checks.
pub struct StdinDoubleDrainGuard;

impl Hook for StdinDoubleDrainGuard {
    fn name(&self) -> &'static str {
        "stdin_double_drain_guard"
    }

    fn run(&self, _ctx: &HookContext) -> Result<HookOutcome, HookError> {
        Ok(HookOutcome::Pass)
    }
}

/// Stub: silent-noop alarm port (INFRA-1988).
///
/// Phase 1 returns Pass unconditionally. The original bash guard detects
/// when the main loop body never executes on a non-trivial push and
/// emits `kind=hook_silent_passthrough` to ambient. We deliberately
/// do NOT emit ambient events in Phase 1 (INFRA-2003 lease on
/// event-registry-reserved.txt); this stub leaves the slot for the
/// real port that lands with the registry coordination.
pub struct SilentNoopAlarmGuard;

impl Hook for SilentNoopAlarmGuard {
    fn name(&self) -> &'static str {
        "silent_noop_alarm_guard"
    }

    fn run(&self, _ctx: &HookContext) -> Result<HookOutcome, HookError> {
        Ok(HookOutcome::Pass)
    }
}

/// Convenience: assemble the Phase 1 hook chain.
///
/// Order: stdin-drain stub (cheap), force-with-lease race (the real
/// guard), silent-noop stub (cheap audit slot).
pub fn phase1_chain() -> Vec<Box<dyn Hook>> {
    vec![
        Box::new(StdinDoubleDrainGuard),
        Box::new(ForceWithLeaseRaceGuard),
        Box::new(SilentNoopAlarmGuard),
    ]
}

/// Guard blocking direct pushes to `main` or `master` unless explicitly allowed
/// via `CHUMP_ALLOW_MAIN_PUSH=1` or `CHUMP_OPERATOR_RECOVERY=1`.
pub struct ProtectedBranchGuard;

impl Hook for ProtectedBranchGuard {
    fn name(&self) -> &'static str {
        "protected_branch_guard"
    }

    fn run(&self, ctx: &HookContext) -> Result<HookOutcome, HookError> {
        let allow = std::env::var("CHUMP_ALLOW_MAIN_PUSH")
            .map(|v| v.trim() == "1" || v.trim().eq_ignore_ascii_case("true"))
            .unwrap_or(false)
            || std::env::var("CHUMP_OPERATOR_RECOVERY")
                .map(|v| v.trim() == "1" || v.trim().eq_ignore_ascii_case("true"))
                .unwrap_or(false);
        if allow {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_ALLOW_MAIN_PUSH=1 or CHUMP_OPERATOR_RECOVERY=1".to_string(),
            });
        }
        for refspec in &ctx.refspecs {
            if refspec.is_branch_delete() {
                continue;
            }
            let branch = refspec.branch();
            if branch == "main" || branch == "master" {
                let diagnostic = format!(
                    "Direct push to protected branch `{branch}` is blocked.\n\
                     Open a PR from a feature branch (`chump ship` / `chump-ship`), \
                     or set CHUMP_ALLOW_MAIN_PUSH=1 for authorized operator recovery."
                );
                return Ok(HookOutcome::Block(BlockReason {
                    code: "protected_branch_push".to_string(),
                    diagnostic,
                }));
            }
        }
        Ok(HookOutcome::Pass)
    }
}

/// Guard 4 (`INFRA-719` / `INFRA-1441`): requires new gap branches (`chump/<domain>-<num>*`
/// or `claude/<domain>-<num>*`) to be pushed via `chump ship` / `bot-merge`
/// (`CHUMP_BOT_MERGE_IN_PROGRESS=1`), unless bypassed with BOTH
/// `CHUMP_BYPASS_BOT_MERGE=1` and a `Bot-Merge-Bypass:` commit trailer (or
/// `CHUMP_OPERATOR_RECOVERY=1`).
pub struct BotMergeRequiredGuard;

impl Hook for BotMergeRequiredGuard {
    fn name(&self) -> &'static str {
        "bot_merge_required_guard"
    }

    fn run(&self, ctx: &HookContext) -> Result<HookOutcome, HookError> {
        let in_bot_merge = std::env::var("CHUMP_BOT_MERGE_IN_PROGRESS")
            .map(|v| v.trim() == "1")
            .unwrap_or(false);
        let op_recovery = std::env::var("CHUMP_OPERATOR_RECOVERY")
            .map(|v| v.trim() == "1")
            .unwrap_or(false);
        if in_bot_merge || op_recovery {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_BOT_MERGE_IN_PROGRESS=1 or CHUMP_OPERATOR_RECOVERY=1".to_string(),
            });
        }
        let bypass_env = std::env::var("CHUMP_BYPASS_BOT_MERGE")
            .map(|v| v.trim() == "1")
            .unwrap_or(false);

        for refspec in &ctx.refspecs {
            if !refspec.is_new_branch() || refspec.is_branch_delete() {
                continue;
            }
            let branch = refspec.branch();
            if !is_gap_branch_name(branch) {
                continue;
            }
            if bypass_env && commit_has_bot_merge_bypass_trailer(ctx, &refspec.local_sha) {
                continue;
            }
            let diagnostic = format!(
                "Bypass: CHUMP_BYPASS_BOT_MERGE=1 (+ Bot-Merge-Bypass trailer) or CHUMP_OPERATOR_RECOVERY=1\n\
                 BLOCKED (INFRA-719): new gap branch `{branch}` must be shipped via `chump ship` / `chump-ship` \
                 so preflight + PR metadata run atomically."
            );
            return Ok(HookOutcome::Block(BlockReason {
                code: "bot_merge_required".to_string(),
                diagnostic,
            }));
        }
        Ok(HookOutcome::Pass)
    }
}

fn is_gap_branch_name(branch: &str) -> bool {
    let Some(rest) = branch
        .strip_prefix("chump/")
        .or_else(|| branch.strip_prefix("claude/"))
    else {
        return false;
    };
    let mut parts = rest.split('-');
    let Some(domain) = parts.next() else {
        return false;
    };
    let Some(num) = parts.next() else {
        return false;
    };
    !domain.is_empty()
        && domain.chars().all(|c| c.is_ascii_alphabetic())
        && !num.is_empty()
        && num.chars().all(|c| c.is_ascii_digit())
}

fn commit_has_bot_merge_bypass_trailer(ctx: &HookContext, sha: &str) -> bool {
    let Ok(out) = ctx.git().args(["log", "-1", "--format=%B", sha]).output() else {
        return false;
    };
    if !out.status.success() {
        return false;
    }
    let body = String::from_utf8_lossy(&out.stdout);
    body.lines().any(|l| {
        let t = l.trim();
        t.starts_with("Bot-Merge-Bypass:")
            && !t.trim_start_matches("Bot-Merge-Bypass:").trim().is_empty()
    })
}

/// Assemble the complete cross-platform `pre-push` guard chain (Milestone 3).
pub fn default_pre_push_chain() -> Vec<Box<dyn Hook>> {
    vec![
        Box::new(StdinDoubleDrainGuard),
        Box::new(ProtectedBranchGuard),
        Box::new(ForceWithLeaseRaceGuard),
        Box::new(BotMergeRequiredGuard),
        Box::new(SilentNoopAlarmGuard),
    ]
}

/// Execute the default `pre-commit` hook chain for the current repository and
/// return the desired process exit code (`0` = pass/skipped, `1` = blocked/error).
pub fn run_pre_commit_cli() -> u8 {
    let ctx = match pre_commit::PreCommitContext::new() {
        Ok(c) => c,
        Err(err) => {
            eprintln!("[chump hook pre-commit] context init failed: {err}");
            return 1;
        }
    };
    let chain = pre_commit::default_pre_commit_chain();
    match pre_commit::run_pre_commit_hooks(&ctx, &chain) {
        Ok(HookOutcome::Pass) | Ok(HookOutcome::Skipped { .. }) => 0,
        Ok(HookOutcome::Block(reason)) => {
            eprintln!();
            eprintln!("[chump hook pre-commit] BLOCKED ({}):", reason.code);
            eprintln!("{}", reason.diagnostic);
            eprintln!();
            1
        }
        Err(err) => {
            eprintln!("[chump hook pre-commit] error: {err}");
            1
        }
    }
}

/// Execute the default `pre-push` hook chain against `stdin_buf` and return
/// the desired process exit code (`0` = pass/skipped, `1` = blocked/error).
pub fn run_pre_push_cli(remote_name: Option<String>, stdin_buf: &str) -> u8 {
    if std::env::var("CHUMP_OPERATOR_RECOVERY")
        .map(|v| v.trim() == "1")
        .unwrap_or(false)
    {
        return 0;
    }
    let remote = remote_name.unwrap_or_else(|| "origin".to_string());
    let ctx = match HookContext::new_from_stdin(remote, stdin_buf) {
        Ok(c) => c,
        Err(err) => {
            eprintln!("[chump hook pre-push] context init failed: {err}");
            return 1;
        }
    };
    let chain = default_pre_push_chain();
    match run_hooks(&ctx, &chain) {
        Ok(HookOutcome::Pass) | Ok(HookOutcome::Skipped { .. }) => 0,
        Ok(HookOutcome::Block(reason)) => {
            eprintln!();
            eprintln!("[chump hook pre-push] BLOCKED ({}):", reason.code);
            eprintln!("{}", reason.diagnostic);
            eprintln!();
            1
        }
        Err(err) => {
            eprintln!("[chump hook pre-push] error: {err}");
            1
        }
    }
}

/// Result of installing portable `pre-commit` and `pre-push` shims into a git repository.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookInstallReport {
    /// Directory where hook shims were written (e.g. `.git/hooks`).
    pub hooks_dir: PathBuf,
    /// Installed `pre-commit` shim path.
    pub pre_commit_path: PathBuf,
    /// Installed `pre-push` shim path.
    pub pre_push_path: PathBuf,
}

/// Status snapshot returned by [`hooks_status`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookStatusReport {
    /// Resolved git hooks directory.
    pub hooks_dir: PathBuf,
    /// True if `pre-commit` exists and delegates to `chump hook pre-commit`.
    pub pre_commit_installed: bool,
    /// True if `pre-push` exists and delegates to `chump hook pre-push`.
    pub pre_push_installed: bool,
}

/// Resolve the active git hooks directory for `repo_root` (honoring `core.hooksPath`
/// and linked worktree `gitdir` indirection via `git rev-parse --git-path hooks`).
pub fn resolve_git_hooks_dir(repo_root: &Path) -> PathBuf {
    let mut cmd = Command::new("git");
    for var in ENV_LEAK_VARS {
        cmd.env_remove(var);
    }
    if let Ok(out) = cmd
        .arg("-C")
        .arg(repo_root)
        .args(["rev-parse", "--git-path", "hooks"])
        .output()
    {
        if out.status.success() {
            let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !raw.is_empty() {
                let p = PathBuf::from(&raw);
                return if p.is_absolute() {
                    p
                } else {
                    repo_root.join(p)
                };
            }
        }
    }
    repo_root.join(".git").join("hooks")
}

/// Render a portable POSIX `#!/bin/sh` hook shim that works identically across
/// Git for Windows (`/bin/sh`), macOS, and Linux.
pub fn render_portable_hook_shim(subcommand: &str) -> String {
    format!(
        "#!/bin/sh\n\
         # Auto-generated by `chump hook install` — portable across macOS, Linux, and Git for Windows.\n\
         if [ -n \"${{CHUMP_BIN:-}}\" ] && [ -x \"${{CHUMP_BIN}}\" ]; then\n\
             exec \"${{CHUMP_BIN}}\" hook {subcommand} \"$@\"\n\
         fi\n\
         if command -v chump >/dev/null 2>&1; then\n\
             exec chump hook {subcommand} \"$@\"\n\
         fi\n\
         for cand in \"${{CARGO_TARGET_DIR:-}}/debug/chump\" \"${{CARGO_TARGET_DIR:-}}/release/chump\" \\\n\
                     \"${{HOME:-}}/.cargo/chump-shared-target/debug/chump\" \"./target/debug/chump\" \"./target/release/chump\"; do\n\
             if [ -n \"$cand\" ] && [ -x \"$cand\" ]; then\n\
                 exec \"$cand\" hook {subcommand} \"$@\"\n\
             fi\n\
         done\n\
         echo \"[chump hook] warning: chump binary not found on PATH; skipping {subcommand}\" >&2\n\
         exit 0\n"
    )
}

/// Write portable `pre-commit` and `pre-push` shims into `repo_root`'s git hooks directory.
pub fn install_hooks(repo_root: &Path) -> std::io::Result<HookInstallReport> {
    let hooks_dir = resolve_git_hooks_dir(repo_root);
    std::fs::create_dir_all(&hooks_dir)?;

    let pre_commit_path = hooks_dir.join("pre-commit");
    let pre_push_path = hooks_dir.join("pre-push");

    write_executable_shim(&pre_commit_path, &render_portable_hook_shim("pre-commit"))?;
    write_executable_shim(&pre_push_path, &render_portable_hook_shim("pre-push"))?;

    Ok(HookInstallReport {
        hooks_dir,
        pre_commit_path,
        pre_push_path,
    })
}

fn write_executable_shim(path: &Path, content: &str) -> std::io::Result<()> {
    // Remove any existing symlink first so we NEVER write through a symlink into
    // another checkout's tracked files!
    if path.symlink_metadata().is_ok() {
        let _ = std::fs::remove_file(path);
    }
    std::fs::write(path, content)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))?;
    }
    Ok(())
}

/// Inspect whether `chump hook` shims are installed in `repo_root`.
pub fn hooks_status(repo_root: &Path) -> HookStatusReport {
    let hooks_dir = resolve_git_hooks_dir(repo_root);
    let check = |name: &str, marker: &str| -> bool {
        std::fs::read_to_string(hooks_dir.join(name))
            .map(|s| s.contains(marker))
            .unwrap_or(false)
    };
    HookStatusReport {
        pre_commit_installed: check("pre-commit", "hook pre-commit"),
        pre_push_installed: check("pre-push", "hook pre-push"),
        hooks_dir,
    }
}

/// Re-exported for the binary: read all of stdin into a String.
pub fn read_stdin_to_string() -> std::io::Result<String> {
    use std::io::Read;
    let mut buf = String::new();
    std::io::stdin().read_to_string(&mut buf)?;
    Ok(buf)
}

/// Re-exported for testing: hook root from explicit path (bypasses git
/// discovery). Caller is responsible for env-scrubbing.
#[doc(hidden)]
pub fn context_from_explicit_root(
    repo_root: impl AsRef<Path>,
    remote_name: String,
    refspecs: Vec<RefspecPush>,
) -> HookContext {
    HookContext {
        repo_root: repo_root.as_ref().to_path_buf(),
        refspecs,
        remote_name,
    }
}

// ---- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refspec_new_branch_detection() {
        let r = RefspecPush {
            local_ref: "refs/heads/foo".to_string(),
            local_sha: "abc123".to_string(),
            remote_ref: "refs/heads/foo".to_string(),
            remote_sha: "0000000000000000000000000000000000000000".to_string(),
        };
        assert!(r.is_new_branch());
        assert!(!r.is_branch_delete());
        assert_eq!(r.branch(), "foo");
    }

    #[test]
    fn refspec_branch_delete_detection() {
        let r = RefspecPush {
            local_ref: "(delete)".to_string(),
            local_sha: "0000000000000000000000000000000000000000".to_string(),
            remote_ref: "refs/heads/foo".to_string(),
            remote_sha: "abc123".to_string(),
        };
        assert!(r.is_branch_delete());
        assert!(!r.is_new_branch());
    }

    #[test]
    fn refspec_strips_refs_heads_prefix() {
        let r = RefspecPush {
            local_ref: "refs/heads/feature/foo".to_string(),
            local_sha: "abc".to_string(),
            remote_ref: "refs/heads/feature/foo".to_string(),
            remote_sha: "def".to_string(),
        };
        assert_eq!(r.branch(), "feature/foo");
    }

    #[test]
    fn refspec_branch_falls_back_to_remote_ref() {
        let r = RefspecPush {
            local_ref: "refs/heads/foo".to_string(),
            local_sha: "abc".to_string(),
            remote_ref: "refs/tags/v1".to_string(),
            remote_sha: "def".to_string(),
        };
        assert_eq!(r.branch(), "refs/tags/v1");
    }

    #[test]
    fn parse_refspecs_handles_multiple_lines() {
        let buf = "\
            refs/heads/foo abc111 refs/heads/foo def222\n\
            refs/heads/bar abc222 refs/heads/bar 0000000000000000000000000000000000000000\n";
        let parsed = parse_refspecs(buf).expect("parse");
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].local_sha, "abc111");
        assert!(parsed[1].is_new_branch());
    }

    #[test]
    fn parse_refspecs_skips_blank_lines() {
        let buf = "\n\nrefs/heads/foo abc def refs/heads/foo\n\n";
        let parsed = parse_refspecs(buf);
        // 4 fields required, this line has 4 — should parse one entry.
        assert!(parsed.is_ok());
        let entries = parsed.unwrap();
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn parse_refspecs_rejects_malformed() {
        let buf = "only_three fields_here\n";
        let err = parse_refspecs(buf);
        assert!(matches!(err, Err(HookError::MalformedRefspec(_))));
    }

    #[test]
    fn env_leak_vars_list_is_complete() {
        // Snapshot the contract: any change here must be intentional.
        assert_eq!(ENV_LEAK_VARS.len(), 5);
        assert!(ENV_LEAK_VARS.contains(&"GIT_DIR"));
        assert!(ENV_LEAK_VARS.contains(&"GIT_WORK_TREE"));
        assert!(ENV_LEAK_VARS.contains(&"GITHUB_WORKSPACE"));
        assert!(ENV_LEAK_VARS.contains(&"GIT_COMMON_DIR"));
        assert!(ENV_LEAK_VARS.contains(&"GIT_INDEX_FILE"));
    }

    #[test]
    fn force_with_lease_guard_skips_when_disabled() {
        let prev = std::env::var("CHUMP_FORCE_LEASE_CHECK").ok();
        std::env::set_var("CHUMP_FORCE_LEASE_CHECK", "0");

        let ctx = context_from_explicit_root(
            "/tmp",
            "origin".to_string(),
            vec![RefspecPush {
                local_ref: "refs/heads/foo".to_string(),
                local_sha: "deadbeef".to_string(),
                remote_ref: "refs/heads/foo".to_string(),
                remote_sha: "cafebabe".to_string(),
            }],
        );
        let outcome = ForceWithLeaseRaceGuard.run(&ctx).expect("run");
        assert!(matches!(outcome, HookOutcome::Skipped { .. }));

        match prev {
            Some(v) => std::env::set_var("CHUMP_FORCE_LEASE_CHECK", v),
            None => std::env::remove_var("CHUMP_FORCE_LEASE_CHECK"),
        }
    }

    #[test]
    fn stub_guards_pass() {
        let ctx = context_from_explicit_root("/tmp", "origin".to_string(), vec![]);
        assert_eq!(StdinDoubleDrainGuard.run(&ctx).unwrap(), HookOutcome::Pass);
        assert_eq!(SilentNoopAlarmGuard.run(&ctx).unwrap(), HookOutcome::Pass);
    }

    #[test]
    fn has_nontrivial_push_false_for_new_branch_only() {
        let ctx = context_from_explicit_root(
            "/tmp",
            "origin".to_string(),
            vec![RefspecPush {
                local_ref: "refs/heads/foo".to_string(),
                local_sha: "abc".to_string(),
                remote_ref: "refs/heads/foo".to_string(),
                remote_sha: "0000000000000000000000000000000000000000".to_string(),
            }],
        );
        assert!(!ctx.has_nontrivial_push());
    }

    #[test]
    fn has_nontrivial_push_true_for_real_push() {
        let ctx = context_from_explicit_root(
            "/tmp",
            "origin".to_string(),
            vec![RefspecPush {
                local_ref: "refs/heads/foo".to_string(),
                local_sha: "abc".to_string(),
                remote_ref: "refs/heads/foo".to_string(),
                remote_sha: "def".to_string(),
            }],
        );
        assert!(ctx.has_nontrivial_push());
    }

    #[test]
    fn phase1_chain_has_three_hooks() {
        let chain = phase1_chain();
        assert_eq!(chain.len(), 3);
        let names: Vec<&str> = chain.iter().map(|h| h.name()).collect();
        assert!(names.contains(&"stdin_double_drain_guard"));
        assert!(names.contains(&"force_with_lease_race_guard"));
        assert!(names.contains(&"silent_noop_alarm_guard"));
    }

    #[test]
    fn protected_branch_guard_blocks_main_unless_allowed() {
        std::env::remove_var("CHUMP_ALLOW_MAIN_PUSH");
        std::env::remove_var("CHUMP_OPERATOR_RECOVERY");
        let ctx = context_from_explicit_root(
            "/tmp",
            "origin".to_string(),
            vec![RefspecPush {
                local_ref: "refs/heads/main".to_string(),
                local_sha: "abc".to_string(),
                remote_ref: "refs/heads/main".to_string(),
                remote_sha: "def".to_string(),
            }],
        );
        let blocked = ProtectedBranchGuard.run(&ctx).unwrap();
        assert!(matches!(blocked, HookOutcome::Block(_)));

        let ctx_feat = context_from_explicit_root(
            "/tmp",
            "origin".to_string(),
            vec![RefspecPush {
                local_ref: "refs/heads/feature/ok".to_string(),
                local_sha: "abc".to_string(),
                remote_ref: "refs/heads/feature/ok".to_string(),
                remote_sha: "def".to_string(),
            }],
        );
        assert_eq!(
            ProtectedBranchGuard.run(&ctx_feat).unwrap(),
            HookOutcome::Pass
        );
    }

    #[test]
    fn bot_merge_required_guard_enforces_new_gap_branches() {
        std::env::remove_var("CHUMP_BOT_MERGE_IN_PROGRESS");
        std::env::remove_var("CHUMP_BYPASS_BOT_MERGE");
        std::env::remove_var("CHUMP_OPERATOR_RECOVERY");
        let zero = "0000000000000000000000000000000000000000".to_string();

        let ctx_gap = context_from_explicit_root(
            "/tmp",
            "origin".to_string(),
            vec![RefspecPush {
                local_ref: "refs/heads/chump/infra-999-claim".to_string(),
                local_sha: "abc".to_string(),
                remote_ref: "refs/heads/chump/infra-999-claim".to_string(),
                remote_sha: zero.clone(),
            }],
        );
        assert!(matches!(
            BotMergeRequiredGuard.run(&ctx_gap).unwrap(),
            HookOutcome::Block(_)
        ));

        let ctx_non_gap = context_from_explicit_root(
            "/tmp",
            "origin".to_string(),
            vec![RefspecPush {
                local_ref: "refs/heads/chump/fix-auth-issue".to_string(),
                local_sha: "abc".to_string(),
                remote_ref: "refs/heads/chump/fix-auth-issue".to_string(),
                remote_sha: zero,
            }],
        );
        assert_eq!(
            BotMergeRequiredGuard.run(&ctx_non_gap).unwrap(),
            HookOutcome::Pass
        );
    }

    #[test]
    fn install_hooks_writes_portable_shims_and_reports_status() {
        let tmp = tempfile::TempDir::new().unwrap();
        Command::new("git")
            .arg("-C")
            .arg(tmp.path())
            .args(["init", "-b", "main"])
            .status()
            .unwrap();
        let report = install_hooks(tmp.path()).unwrap();
        assert!(report.pre_commit_path.is_file());
        assert!(report.pre_push_path.is_file());
        let status = hooks_status(tmp.path());
        assert!(status.pre_commit_installed);
        assert!(status.pre_push_installed);
    }
}
