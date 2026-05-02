//! INFRA-191 — `chump dispatch` (Phase 1 skeleton).
//!
//! Single command that runs the whole ship cycle:
//!   preflight → claim → (caller's work happened already) → ship → release
//!
//! ## Phase 1 scope (THIS PR)
//!
//! - Public API surface: [`DispatchOptions`], [`DispatchOutcome`],
//!   [`ShipResult`], [`WorkBackend`], [`run`].
//! - Internals **wrap the existing shell scripts** via `std::process::Command`
//!   (gap-preflight.sh, gap-claim.sh, bot-merge.sh). This makes the Rust path
//!   immediately usable end-to-end while leaving each step independently
//!   portable in later phases.
//! - Only [`WorkBackend::Interactive`] is supported (caller already did the
//!   work; `dispatch::run` ties off preflight + claim + ship + release).
//!
//! ## Future phases (NOT this PR — see docs/design/INFRA-191-chump-dispatch.md)
//!
//! - Phase 2: [`WorkBackend::Headless`] (spawn `claude -p`) and
//!   [`WorkBackend::ExecGap`] (spawn `chump --execute-gap`).
//! - Phase 3: port [`ship`] to native Rust git/gh calls (replace the
//!   bot-merge.sh wrap).
//! - Phase 4: flip the CLAUDE.md/AGENTS.md ship-pipeline guidance from
//!   `bot-merge.sh` to `chump dispatch`.
//! - Phase 5: retire `scripts/coord/bot-merge.sh`.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

/// How the actual work between claim and ship gets done.
///
/// Phase 1 only implements [`WorkBackend::Interactive`]; the others bail
/// with a descriptive error so the API surface is stable for Phase 2.
#[derive(Debug, Clone)]
pub enum WorkBackend {
    /// Caller drives the work directly (e.g. interactive editing in this
    /// shell). `dispatch::run` only orchestrates preflight → claim →
    /// ship → release. This is the Phase 1 default.
    Interactive,

    /// Phase 2: spawn `claude -p <prompt>` and wait for exit.
    Headless { model: String, prompt: String },

    /// Phase 2: spawn `chump --execute-gap <ID>` (chump-local backend,
    /// COG-025).
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

    // Step 3: caller's work happens here. Phase 1 only supports Interactive
    // (work has already happened in the caller's shell). Phase 2 adds the
    // headless / exec-gap backends.
    match &opts.work {
        WorkBackend::Interactive => { /* nothing — caller already did it */ }
        WorkBackend::Headless { .. } | WorkBackend::ExecGap => {
            // Always release before bailing.
            let _ = release(&opts);
            bail!(
                "WorkBackend::{:?} not implemented in Phase 1 (INFRA-191); see docs/design/INFRA-191-chump-dispatch.md",
                std::mem::discriminant(&opts.work)
            );
        }
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
    // Phase 1: prefer the existing `chump --release` path if the binary
    // exists; otherwise no-op (relying on TTL). Phase 3 will inline the
    // lock-file removal here.
    for candidate in [
        opts.repo_root.join("target/release/chump"),
        opts.repo_root.join("target/debug/chump"),
    ] {
        if candidate.exists() {
            let _ = Command::new(&candidate)
                .arg("--release")
                .current_dir(&opts.repo_root)
                .status();
            return Ok(());
        }
    }
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
}
