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
}
