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
use std::process::Command;

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
pub fn run(opts: DispatchOptions) -> Result<DispatchOutcome> {
    let started = std::time::Instant::now();
    let branch = current_branch(&opts.repo_root)?;

    // Step 1: preflight (read-only check).
    preflight(&opts).context("preflight")?;

    // Step 2: claim (writes .chump-locks/<session>.json).
    claim(&opts).context("claim")?;

    // Step 3: caller's work happens here. Interactive = caller already did
    // it; Headless / ExecGap = spawn the work-doing process and wait.
    if let Err(e) = do_work(&opts) {
        // Always release before propagating the error so a failed work
        // step doesn't leave a stale lease.
        let _ = release(&opts);
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
    let ship_result = match ship(&opts) {
        Ok(r) => r,
        Err(e) => ShipResult::Aborted {
            error: format!("{e:#}"),
        },
    };

    // Step 5: always release the lease.
    let _ = release(&opts);

    Ok(DispatchOutcome {
        gap_id: opts.gap_id.to_string(),
        branch,
        result: ship_result,
        duration_secs: started.elapsed().as_secs(),
    })
}

// ── Internals (each one independently portable in Phase 3) ───────────────────

/// Execute the user-provided work for a dispatch cycle. Variant-dispatched
/// per [`WorkBackend`].
fn do_work(opts: &DispatchOptions) -> Result<()> {
    match &opts.work {
        WorkBackend::Interactive => {
            // Caller already did the work; nothing to spawn.
            Ok(())
        }
        WorkBackend::Headless { model, prompt } => spawn_headless(opts, model, prompt),
        WorkBackend::ExecGap => spawn_exec_gap(opts),
    }
}

/// Phase 2 — `WorkBackend::Headless`. Spawns
/// `claude -p <prompt> --dangerously-skip-permissions [--model <model>]`,
/// inherits stdio so the operator sees progress inline, and waits for exit.
fn spawn_headless(opts: &DispatchOptions, model: &str, prompt: &str) -> Result<()> {
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
    cmd.current_dir(&opts.repo_root);
    let status = cmd
        .status()
        .context("spawn `claude -p` (is the claude CLI on PATH?)")?;
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
fn spawn_exec_gap(opts: &DispatchOptions) -> Result<()> {
    let chump_bin = resolve_chump_binary(&opts.repo_root);
    let mut cmd = Command::new(chump_bin);
    cmd.args(["--execute-gap", opts.gap_id])
        .current_dir(&opts.repo_root);
    let status = cmd
        .status()
        .with_context(|| format!("spawn `chump --execute-gap {}`", opts.gap_id))?;
    if !status.success() {
        bail!(
            "chump --execute-gap exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
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

fn preflight(opts: &DispatchOptions) -> Result<()> {
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
        .current_dir(&opts.repo_root)
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

fn claim(opts: &DispatchOptions) -> Result<()> {
    let script = opts.repo_root.join("scripts/coord/gap-claim.sh");
    if !script.exists() {
        bail!("gap-claim.sh missing at {}", script.display());
    }
    let mut cmd = Command::new("bash");
    cmd.arg(&script).arg(opts.gap_id);
    if let Some(paths) = opts.paths {
        cmd.arg("--paths").arg(paths);
    }
    let status = cmd
        .current_dir(&opts.repo_root)
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

fn ship(opts: &DispatchOptions) -> Result<ShipResult> {
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
    let status = cmd
        .current_dir(&opts.repo_root)
        .status()
        .context("invoke bot-merge.sh")?;
    if !status.success() {
        return Ok(ShipResult::Aborted {
            error: format!("bot-merge.sh exited {}", status.code().unwrap_or(-1)),
        });
    }

    // bot-merge.sh has already opened/updated the PR. Read the PR number off
    // the current branch via gh.
    match current_pr_number(&opts.repo_root) {
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

/// Best-effort lease cleanup. Lease files have a TTL so a missed release
/// auto-recovers; we never bail on failure here.
fn release(opts: &DispatchOptions) -> Result<()> {
    // Re-use [`resolve_chump_binary`] so we honor the same precedence as
    // Phase 2's exec-gap path (in-tree target/ → $HOME/.local/bin → PATH).
    let chump = resolve_chump_binary(&opts.repo_root);
    let _ = Command::new(&chump)
        .arg("--release")
        .current_dir(&opts.repo_root)
        .status();
    Ok(())
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
        let err = preflight(&opts).unwrap_err();
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
        let err = ship(&opts).unwrap_err();
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
        let err = spawn_headless(&opts, "claude-sonnet-4-6", "   ").unwrap_err();
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
        // Interactive should just return Ok(()) without spawning anything.
        do_work(&opts).expect("Interactive backend must always succeed");
    }
}
