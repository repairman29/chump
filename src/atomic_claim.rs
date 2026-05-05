//! INFRA-468: atomic `chump claim <ID>` — single CLI call that does the
//! 6-step shell dance every session pays before writing any code:
//!
//!   1. fetch origin/main (already done; cheap)
//!   2. verify gap exists + is open in state.db (seed via import if missing)
//!   3. binary health probe (chump-doctor.sh, INFRA-275 wedge prevention)
//!   4. derive a unique per-claim session ID
//!   5. git worktree add to ${CHUMP_WORKTREE_BASE:-/tmp}/chump-<gap-lower>
//!   6. shell out to gap-claim.sh inside the new worktree (with --paths)
//!   7. print summary + cd hint
//!
//! Replaces the hand-typed mandatory pre-flight in CLAUDE.md. Each step
//! has an env-bypass for testing / unusual setups.

use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Args to atomic claim.
#[derive(Debug)]
pub struct ClaimArgs {
    pub gap_id: String,
    /// CSV of repo-relative paths to declare lease scope. Optional —
    /// passes through to gap-claim.sh's `--paths`.
    pub paths: Option<String>,
    /// Where to create the linked worktree. Default `/tmp`.
    pub worktree_base: PathBuf,
    /// Main repo root (the parent of `--git-common-dir`).
    pub repo_root: PathBuf,
    /// Git remote (default `origin`).
    pub remote: String,
    /// Base branch (default `main`).
    pub base_branch: String,
    /// Override the auto-derived session ID. Same fallback shape as
    /// fleet/INFRA-461: `claim-<gap>-<pid>-<epoch>`.
    pub session_id: Option<String>,
    /// Skip the chump-doctor binary health probe (tests).
    pub skip_doctor: bool,
    /// Skip state.db drift check / import (tests).
    pub skip_import: bool,
}

impl ClaimArgs {
    pub fn from_argv(args: &[String], repo_root: PathBuf) -> Result<Self> {
        // args[0] = "claim", args[1] = <GAP-ID>, then optional flags
        let gap_id = args
            .get(1)
            .ok_or_else(|| anyhow!("missing GAP-ID"))?
            .to_string();
        if gap_id.starts_with("--") {
            bail!("missing GAP-ID (saw flag {gap_id})");
        }
        let mut paths: Option<String> = None;
        let mut session_id: Option<String> = None;
        let mut skip_doctor = false;
        let mut skip_import = false;

        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--paths" => {
                    paths = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--paths needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                "--session" => {
                    session_id = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--session needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                "--skip-doctor" => {
                    skip_doctor = true;
                    i += 1;
                }
                "--skip-import" => {
                    skip_import = true;
                    i += 1;
                }
                other => bail!("unknown flag: {other}"),
            }
        }

        let worktree_base = std::env::var("CHUMP_WORKTREE_BASE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"));
        let remote = std::env::var("CHUMP_REMOTE").unwrap_or_else(|_| "origin".into());
        let base_branch = std::env::var("CHUMP_BASE_BRANCH").unwrap_or_else(|_| "main".into());

        Ok(Self {
            gap_id,
            paths,
            worktree_base,
            repo_root,
            remote,
            base_branch,
            session_id,
            skip_doctor,
            skip_import,
        })
    }
}

/// Outcome of a successful claim.
#[derive(Debug)]
pub struct ClaimReport {
    pub gap_id: String,
    pub worktree_path: PathBuf,
    pub branch: String,
    pub session_id: String,
    pub paths: Option<String>,
}

/// Print a friendly multi-line summary suitable for a terminal.
pub fn print_report(r: &ClaimReport) {
    println!();
    println!("✓ claimed {} atomically (INFRA-468)", r.gap_id);
    println!("    worktree : {}", r.worktree_path.display());
    println!("    branch   : {}", r.branch);
    println!("    session  : {}", r.session_id);
    if let Some(p) = &r.paths {
        println!("    paths    : {}", p);
    }
    println!();
    println!("    cd {}", r.worktree_path.display());
    println!();
}

/// Run the atomic claim. Each step is a separate function so the unit
/// tests can exercise individual pieces in isolation.
pub fn run_claim(args: ClaimArgs) -> Result<ClaimReport> {
    // 1. Fetch latest base branch — best-effort; the worktree-add will
    //    fail loudly if origin is unreachable AND no local ref exists.
    let _ = run_git(
        &args.repo_root,
        &["fetch", &args.remote, &args.base_branch, "--quiet"],
    );

    // 2. Verify gap is openable (or seed state.db if drifted).
    if !args.skip_import {
        verify_or_seed_gap(&args.repo_root, &args.gap_id)?;
    }

    // 3. Binary health probe (INFRA-275 wedge prevention).
    if !args.skip_doctor {
        run_doctor_probe(&args.repo_root)?;
    }

    // 4. Session ID — explicit --session flag > derived.
    //
    // Deliberately do NOT honor CHUMP_SESSION_ID env: each `chump claim`
    // is meant to be a fresh isolated session. Operators who want a
    // specific session ID pass --session explicitly. This avoids the
    // surprise where a parent shell's CHUMP_SESSION_ID (e.g. set by
    // bot-merge.sh, or another claim earlier in the same shell) bleeds
    // into the lease and breaks the "one claim = one session" model.
    let session_id = args
        .session_id
        .clone()
        .unwrap_or_else(|| derive_session_id(&args.gap_id));

    // 5. Worktree path + branch name.
    let gap_lower = args.gap_id.to_lowercase();
    let worktree_path = args.worktree_base.join(format!("chump-{}", gap_lower));
    let branch = format!("chump/{}-claim", gap_lower);

    if worktree_path.exists() {
        bail!(
            "worktree path already exists: {}\n  Remove it first with: git worktree remove --force {}",
            worktree_path.display(),
            worktree_path.display()
        );
    }

    // PathBuf-to-str: macOS/Linux paths are normally UTF-8, but
    // CHUMP_WORKTREE_BASE could be set to a non-UTF-8 path. Fail loudly
    // rather than panic with unwrap().
    let worktree_path_str = worktree_path.to_str().ok_or_else(|| {
        anyhow!(
            "worktree path contains non-UTF-8 bytes (likely from CHUMP_WORKTREE_BASE): {}",
            worktree_path.display()
        )
    })?;

    // 6. git worktree add -b <branch> <path> <remote>/<base>
    run_git(
        &args.repo_root,
        &[
            "worktree",
            "add",
            "-b",
            &branch,
            worktree_path_str,
            &format!("{}/{}", args.remote, args.base_branch),
        ],
    )
    .with_context(|| {
        format!(
            "git worktree add failed for {} -> {}",
            branch,
            worktree_path.display()
        )
    })?;

    // 7. Shell out to gap-claim.sh inside the new worktree.
    let mut claim_cmd = Command::new("bash");
    claim_cmd
        .arg(args.repo_root.join("scripts/coord/gap-claim.sh"))
        .arg(&args.gap_id)
        .env("CHUMP_SESSION_ID", &session_id)
        .current_dir(&worktree_path);
    if let Some(p) = &args.paths {
        claim_cmd.arg("--paths").arg(p);
    }
    let claim_out = claim_cmd
        .output()
        .with_context(|| "spawning gap-claim.sh")?;
    if !claim_out.status.success() {
        // Roll back the worktree to keep the world consistent. Reuses
        // worktree_path_str which is already validated as UTF-8 above.
        let _ = run_git(
            &args.repo_root,
            &["worktree", "remove", "--force", worktree_path_str],
        );
        let _ = run_git(&args.repo_root, &["branch", "-D", &branch]);
        let stderr = String::from_utf8_lossy(&claim_out.stderr);
        bail!("gap-claim.sh failed (rolled back worktree): {}", stderr);
    }

    Ok(ClaimReport {
        gap_id: args.gap_id,
        worktree_path,
        branch,
        session_id,
        paths: args.paths,
    })
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn run_git(cwd: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .with_context(|| format!("spawning git {:?}", args))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!("git {} failed: {}", args.join(" "), stderr);
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Derive a unique session ID for an atomic claim. Same shape as the
/// INFRA-461 fleet pattern but with a `claim-` prefix so logs / leases
/// distinguish operator-claims from fleet-claims.
fn derive_session_id(gap_id: &str) -> String {
    let pid = std::process::id();
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("claim-{}-{}-{}", gap_id.to_lowercase(), pid, epoch)
}

/// Step 2: ensure the gap is in state.db. If missing, attempt to seed
/// via `chump gap import` (uses the per-file YAML mirrors as source of
/// truth — INFRA-470 / INFRA-460 territory).
fn verify_or_seed_gap(repo_root: &Path, gap_id: &str) -> Result<()> {
    // Quick sqlite read.
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        // No DB yet — bootstrap by running `chump gap import`. Caller
        // is presumably trying to seed too, so this is fine.
        return run_chump_gap_import(repo_root);
    }

    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {}", db_path.display()))?;
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM gaps WHERE id = ?1", [gap_id], |r| {
            r.get(0)
        })
        .unwrap_or(0);

    if count == 0 {
        // Gap not in DB but YAML may have it — seed.
        run_chump_gap_import(repo_root)?;

        // Re-check.
        let count_after: i64 = conn
            .query_row("SELECT COUNT(*) FROM gaps WHERE id = ?1", [gap_id], |r| {
                r.get(0)
            })
            .unwrap_or(0);
        if count_after == 0 {
            bail!(
                "gap {} not found in state.db or docs/gaps/ — reserve it first with `chump gap reserve --domain D --title T`",
                gap_id
            );
        }
    }

    // Reject if already done.
    let status: String = conn
        .query_row("SELECT status FROM gaps WHERE id = ?1", [gap_id], |r| {
            r.get(0)
        })
        .unwrap_or_else(|_| "unknown".into());
    if status == "done" {
        bail!(
            "gap {} is already status=done; pick a different gap or reopen it",
            gap_id
        );
    }
    Ok(())
}

fn run_chump_gap_import(repo_root: &Path) -> Result<()> {
    // Use the same binary that's running this code so we're consistent
    // with the build that may have local edits. argv[0] resolves to it.
    let exe = std::env::current_exe().context("locating current chump exe")?;
    let out = Command::new(&exe)
        .args(["gap", "import"])
        .current_dir(repo_root)
        .output()
        .context("spawning chump gap import")?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!("chump gap import failed: {}", stderr);
    }
    Ok(())
}

/// Step 3: chump-doctor binary health probe. Skips silently if the
/// script isn't present (e.g. partial checkouts in tests).
fn run_doctor_probe(repo_root: &Path) -> Result<()> {
    let doctor = repo_root.join("scripts/dev/chump-doctor.sh");
    if !doctor.exists() {
        return Ok(()); // best-effort
    }
    // Use QUIET mode if supported by the script (it greps args for
    // CHUMP_DOCTOR_QUIET=1).
    let out = Command::new("bash")
        .arg(&doctor)
        .env("CHUMP_DOCTOR_QUIET", "1")
        .current_dir(repo_root)
        .output()
        .context("spawning chump-doctor.sh")?;
    if !out.status.success() {
        // Don't abort — the doctor itself may exit non-zero on
        // fresh-binary "no heal needed" paths in some versions. Log
        // stderr as a warning for visibility.
        let stderr = String::from_utf8_lossy(&out.stderr);
        if !stderr.is_empty() {
            eprintln!("[chump claim] chump-doctor stderr: {}", stderr.trim());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_session_id_shape() {
        let s = derive_session_id("INFRA-123");
        assert!(s.starts_with("claim-infra-123-"));
        // claim-infra-123-<pid>-<epoch> = 4 dash-separated segments
        assert_eq!(s.matches('-').count(), 4);
    }

    #[test]
    fn from_argv_minimal() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-123".into()];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-123");
        assert!(args.paths.is_none());
        assert!(!args.skip_doctor);
    }

    #[test]
    fn from_argv_with_flags() {
        let argv: Vec<String> = vec![
            "claim".into(),
            "INFRA-200".into(),
            "--paths".into(),
            "src/,scripts/".into(),
            "--session".into(),
            "test-session".into(),
            "--skip-doctor".into(),
        ];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-200");
        assert_eq!(args.paths.as_deref(), Some("src/,scripts/"));
        assert_eq!(args.session_id.as_deref(), Some("test-session"));
        assert!(args.skip_doctor);
    }

    #[test]
    fn from_argv_missing_gap_id() {
        let argv: Vec<String> = vec!["claim".into()];
        assert!(ClaimArgs::from_argv(&argv, PathBuf::from(".")).is_err());
    }

    #[test]
    fn from_argv_flag_in_gap_id_position() {
        let argv: Vec<String> = vec!["claim".into(), "--paths".into(), "x".into()];
        assert!(ClaimArgs::from_argv(&argv, PathBuf::from(".")).is_err());
    }
}
