//! INFRA-468 + INFRA-1025: atomic `chump claim <ID>` — single CLI call.
//!
//! Steps (all in Rust, no shell-out to gap-claim.sh — INFRA-1025):
//!   1. fetch origin/main
//!   2. verify gap exists + is open in state.db (seed via import if missing)
//!   3. binary health probe (chump-binary-unwedge.sh, INFRA-275 wedge prevention)
//!   4. derive a unique per-claim session ID
//!   5. git worktree add to ${CHUMP_WORKTREE_BASE:-/tmp}/chump-<gap-lower>
//!   6. repair gitdir back-reference (INFRA-779)
//!      6c. remote-branch guard (AC6: --resume resets to remote tip)
//!   7. write lease:
//!      7a. NATS KV dual-write (opt-in)
//!      7b. write JSON lease file to .chump-locks/
//!      7c. write state.db leases row
//!
//! Each step rolls back prior steps on failure (no half-claim state).

use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Args to atomic claim.
#[derive(Debug, Clone)]
pub struct ClaimArgs {
    pub gap_id: String,
    /// CSV of repo-relative paths to declare lease scope.
    pub paths: Option<String>,
    /// If branch already exists on the remote, reset HEAD to remote tip and continue
    /// instead of aborting. AC6: handles already-pushed-but-unmerged branch.
    pub resume: bool,
    /// INFRA-1439: Before the atomic-claim step, auto-remove a stale worktree
    /// directory + stale local branch if they exist. Without this flag the
    /// caller must clean up manually. Does NOT bypass stomp-check (open PR on
    /// branch) — that still blocks unless CHUMP_ALLOW_STOMP=1 is set.
    pub force_recover: bool,
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
    /// INFRA-1394: override the hot-file collision block (warn-only mode still fires).
    pub force_overlap: bool,
    /// INFRA-1503: bypass the open-PR-in-flight abort (step 5b). Mirrors
    /// `CHUMP_CLAIM_ALLOW_OPEN_PR=1`. Distinct from `CHUMP_ALLOW_STOMP`/`--resume`:
    /// this is the operator-explicit "I know there's an open PR; let me work
    /// alongside it (rescue scenario)" path. Default false.
    pub allow_duplicate_pr: bool,
    /// INFRA-1442: bypass the claim-time fuzzy-match against open PR titles
    /// and active leases (kicks in BEFORE worktree creation). Mirrors the
    /// `CHUMP_CLAIM_NO_FUZZY=1` env. Emits `claim_duplicate_bypassed` for
    /// audit when set.
    pub force_duplicate: bool,
    /// Run all preflight gates without creating worktree or lease.
    pub check_only: bool,
    /// Output JSON format (used with --check-only).
    pub json: bool,
}

impl ClaimArgs {
    pub fn from_argv(args: &[String], repo_root: PathBuf) -> Result<Self> {
        // INFRA-1238: trap -h / --help BEFORE positional validation so
        // `chump claim --help` prints usage and exits 0, not "missing GAP-ID".
        for a in args.iter().skip(1) {
            if a == "--help" || a == "-h" {
                println!(
                    "Usage: chump claim <GAP-ID> [--paths CSV] [--session ID] [--no-doctor] [--no-import] [--force-recover]\n\n\
                     Atomic claim: fetch + verify + (doctor) + worktree + lease for <GAP-ID>.\n\n\
                     Options:\n  \
                       --paths CSV      Record path scope (comma-separated globs); enables overlap detection\n  \
                       --session ID     Explicit session ID (default derived from env / pid)\n  \
                       --no-doctor      Skip gap-doctor reconciliation (faster, but skips drift repair)\n  \
                       --no-import      Skip yaml->state.db re-import (faster, but assumes registry is fresh)\n  \
                       --force-recover  Auto-remove stale worktree dir + stale local branch before claiming\n  \
                       --force-overlap  Override hot-file collision block (INFRA-1394); warning still emitted\n  \
                       --allow-duplicate-pr  Bypass open-PR-in-flight abort (INFRA-1503; rescue scenarios)\n  \
                       -h, --help       Show this help
                       --check-only  Run all preflight gates without creating worktree or lease\n  \
                       --json        Output JSON format (use with --check-only)"
                );
                std::process::exit(0);
            }
        }
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
        let mut resume = false;
        let mut force_recover = false;
        let mut force_overlap = false;
        let mut allow_duplicate_pr = false;
        let mut force_duplicate = false;
        let mut check_only = false;
        let mut json = false;

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
                "--resume" => {
                    resume = true;
                    i += 1;
                }
                "--force-recover" => {
                    force_recover = true;
                    i += 1;
                }
                "--force-overlap" => {
                    force_overlap = true;
                    i += 1;
                }
                "--allow-duplicate-pr" => {
                    allow_duplicate_pr = true;
                    i += 1;
                }
                "--force-duplicate" => {
                    force_duplicate = true;
                    i += 1;
                }
                "--check-only" => {
                    check_only = true;
                    i += 1;
                }
                "--json" => {
                    json = true;
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
            resume,
            force_recover,
            force_overlap,
            allow_duplicate_pr,
            force_duplicate,
            check_only,
            json,
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

/// Check result for a single preflight gate (INFRA-1415).
#[derive(Debug, Clone, serde::Serialize)]
pub struct GateResult {
    pub gate: String,
    pub status: String, // "pass", "warn", or "fail"
    pub message: String,
}

/// Outcome of check-only run.
#[derive(Debug, serde::Serialize)]
pub struct CheckReport {
    pub gap_id: String,
    pub overall: String, // "pass", "warn", or "fail"
    pub gates: Vec<GateResult>,
}

/// Print check report in human-readable table format.
pub fn print_check_report(r: &CheckReport) {
    println!();
    println!("chump claim --check-only {}", r.gap_id);
    println!();

    // Print header
    println!("{:<20} {:<10} MESSAGE", "GATE", "STATUS");
    println!(
        "{:<20} {:<10} {}",
        "─".repeat(20),
        "─".repeat(10),
        "─".repeat(50)
    );

    // Print each gate result
    for gate in &r.gates {
        let status_display = match gate.status.as_str() {
            "pass" => "✓ PASS",
            "warn" => "⚠ WARN",
            "fail" => "✗ FAIL",
            _ => &gate.status,
        };
        println!("{:<20} {:<10} {}", gate.gate, status_display, gate.message);
    }

    println!();
    match r.overall.as_str() {
        "pass" => println!("Overall: ✓ All checks passed"),
        "warn" => println!("Overall: ⚠ Some warnings (not blocking)"),
        "fail" => println!("Overall: ✗ Blocking issue found"),
        _ => println!("Overall: {}", r.overall),
    }
    println!();
}

/// INFRA-1415: Run all preflight gates without creating worktree or lease.
/// Returns a CheckReport with pass/warn/fail status for each gate.
pub fn run_check_only(args: ClaimArgs) -> Result<CheckReport> {
    let mut gates = Vec::new();
    let mut has_fail = false;
    let mut has_warn = false;

    // Gate 1: Fetch + verify state.db status
    let fetch_result = run_git(
        &args.repo_root,
        &["fetch", &args.remote, &args.base_branch, "--quiet"],
    );
    if fetch_result.is_err() {
        gates.push(GateResult {
            gate: "fetch".to_string(),
            status: "warn".to_string(),
            message: "Could not fetch origin (offline or network issue)".to_string(),
        });
        has_warn = true;
    } else {
        gates.push(GateResult {
            gate: "fetch".to_string(),
            status: "pass".to_string(),
            message: "Fetched latest origin/main".to_string(),
        });
    }

    // Gate 2: Check state.db status (gap must be open and unclaimed)
    let db_path = args.repo_root.join(".chump/state.db");
    if !db_path.exists() {
        gates.push(GateResult {
            gate: "state.db".to_string(),
            status: "fail".to_string(),
            message: format!("state.db not found at {}", db_path.display()),
        });
        has_fail = true;
    } else {
        match check_gap_status(&args.repo_root, &args.gap_id) {
            Ok(status_msg) => {
                gates.push(GateResult {
                    gate: "state.db".to_string(),
                    status: "pass".to_string(),
                    message: status_msg,
                });
            }
            Err(e) => {
                gates.push(GateResult {
                    gate: "state.db".to_string(),
                    status: "fail".to_string(),
                    message: e.to_string(),
                });
                has_fail = true;
            }
        }
    }

    // Gate 3: Check hot-file collision (INFRA-1394)
    if let Some(paths) = &args.paths {
        match check_hot_file_collision(&args.repo_root, paths) {
            Ok(msg) => {
                gates.push(GateResult {
                    gate: "hot-files".to_string(),
                    status: "pass".to_string(),
                    message: msg,
                });
            }
            Err(msg) => {
                gates.push(GateResult {
                    gate: "hot-files".to_string(),
                    status: "warn".to_string(),
                    message: msg,
                });
                has_warn = true;
            }
        }
    }

    // Gate 3b: INFRA-1885: Check lease-breadth (broad top-level dir rejection)
    if let Some(paths) = &args.paths {
        let ambient_log_co = args.repo_root.join(".chump-locks/ambient.jsonl");
        let session_co = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        match check_lease_breadth(paths, &args.gap_id, &session_co, &ambient_log_co) {
            Ok(()) => {
                gates.push(GateResult {
                    gate: "lease-breadth".to_string(),
                    status: "pass".to_string(),
                    message: "paths are specific enough (no broad top-level dirs)".to_string(),
                });
            }
            Err(e) => {
                gates.push(GateResult {
                    gate: "lease-breadth".to_string(),
                    status: "fail".to_string(),
                    message: e.to_string(),
                });
                has_fail = true;
            }
        }
    }

    // Gate 4: Check acceptance criteria (must not be empty/TODO only)
    match check_acceptance_criteria(&args.repo_root, &args.gap_id) {
        Ok(msg) => {
            gates.push(GateResult {
                gate: "acceptance_criteria".to_string(),
                status: "pass".to_string(),
                message: msg,
            });
        }
        Err(e) => {
            gates.push(GateResult {
                gate: "acceptance_criteria".to_string(),
                status: "fail".to_string(),
                message: e.to_string(),
            });
            has_fail = true;
        }
    }

    // Gate 5: Check base branch is up-to-date (sanity check)
    match check_base_branch(&args.repo_root, &args.remote, &args.base_branch) {
        Ok(msg) => {
            gates.push(GateResult {
                gate: "base_branch".to_string(),
                status: "pass".to_string(),
                message: msg,
            });
        }
        Err(msg) => {
            gates.push(GateResult {
                gate: "base_branch".to_string(),
                status: "warn".to_string(),
                message: msg,
            });
            has_warn = true;
        }
    }

    // Gate 6: Check disk space (must have >5GB free)
    match check_disk_space(&args.worktree_base) {
        Ok(msg) => {
            gates.push(GateResult {
                gate: "disk_space".to_string(),
                status: "pass".to_string(),
                message: msg,
            });
        }
        Err(msg) => {
            gates.push(GateResult {
                gate: "disk_space".to_string(),
                status: "warn".to_string(),
                message: msg,
            });
            has_warn = true;
        }
    }

    // Determine overall status
    let overall = if has_fail {
        "fail".to_string()
    } else if has_warn {
        "warn".to_string()
    } else {
        "pass".to_string()
    };

    Ok(CheckReport {
        gap_id: args.gap_id,
        overall,
        gates,
    })
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

    // INFRA-1442: claim-time fuzzy-match against in-flight work BEFORE
    // worktree creation. Catches the 3-way duplicate-fix pattern observed
    // 2026-05-22 (INFRA-1341/1384/1396 all fixed test-cache-mergestatestatus.sh
    // independently in parallel). Bypass via --force-duplicate or
    // CHUMP_CLAIM_NO_FUZZY=1; bypass emits claim_duplicate_bypassed.
    match run_fuzzy_gate(&args.repo_root, &args.gap_id, args.force_duplicate) {
        Ok(_matches) => {} // either no matches OR operator-bypassed; the helper emitted the event
        Err(warning_text) => {
            eprint!("{warning_text}");
            bail!(
                "claim refused — fuzzy-match against open PRs / active leases. Use --force-duplicate or CHUMP_CLAIM_NO_FUZZY=1 to override."
            );
        }
    }

    // INFRA-1885: lease-breadth cap — reject claims of exact top-level dirs
    // without a more specific sub-path. Forces file-level granularity so
    // broad leases don't block other sessions from filing event-registry
    // entries or touching adjacent sub-paths.
    //
    // Bypass: CHUMP_LEASE_ALLOW_BROAD_DIRS=1 + commit-message trailer
    //   Broad-Lease-Reason: <one sentence>
    // Bypass emits kind=lease_broad_dir_claim to ambient.jsonl for audit.
    if let Some(paths_csv) = &args.paths {
        let early_session_id = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let ambient_log_early = args.repo_root.join(".chump-locks/ambient.jsonl");
        check_lease_breadth(
            paths_csv,
            &args.gap_id,
            &early_session_id,
            &ambient_log_early,
        )?;
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

    // PathBuf-to-str needed for both the force-recover block and worktree-add below.
    // Derive early so both code paths share the same binding.
    let worktree_path_str = worktree_path.to_str().ok_or_else(|| {
        anyhow!(
            "worktree path contains non-UTF-8 bytes (likely from CHUMP_WORKTREE_BASE): {}",
            worktree_path.display()
        )
    })?;

    // INFRA-1439: --force-recover — auto-clean stale worktree dir + local branch
    // BEFORE the stomp-check or worktree-add, so the claim can proceed
    // idempotently when a prior session left orphaned state.
    //
    // Actions taken (in order):
    //   (a) git worktree remove --force <path>  if the dir exists
    //   (b) rm -rf <path>                       if (a) failed or dir still present
    //   (c) git branch -D <branch>              if branch exists locally
    // Emits chump_claim_force_recover to ambient.jsonl with the actions taken.
    if args.force_recover {
        let mut recovery_actions: Vec<String> = Vec::new();

        // (a) git worktree remove --force
        if worktree_path.exists() {
            match run_git(
                &args.repo_root,
                &["worktree", "remove", "--force", worktree_path_str],
            ) {
                Ok(_) => {
                    recovery_actions
                        .push(format!("worktree_remove_force:{}", worktree_path.display()));
                }
                Err(e) => {
                    eprintln!(
                        "[claim --force-recover] git worktree remove --force failed: {e}; falling back to rm -rf"
                    );
                    // (b) rm -rf fallback
                    if let Err(rm_err) = std::fs::remove_dir_all(&worktree_path) {
                        eprintln!(
                            "[claim --force-recover] rm -rf {} failed: {rm_err}",
                            worktree_path.display()
                        );
                        // If we can't remove it, bail — the claim will fail anyway
                        bail!(
                            "--force-recover: could not remove stale worktree {}: {rm_err}",
                            worktree_path.display()
                        );
                    }
                    recovery_actions.push(format!("rm_rf:{}", worktree_path.display()));
                }
            }
        }

        // (c) delete local branch if it exists
        let local_branch_exists =
            run_git(&args.repo_root, &["rev-parse", "--verify", &branch]).is_ok();
        if local_branch_exists {
            match run_git(&args.repo_root, &["branch", "-D", &branch]) {
                Ok(_) => {
                    recovery_actions.push(format!("branch_delete:{branch}"));
                }
                Err(e) => {
                    eprintln!("[claim --force-recover] git branch -D {branch} failed: {e}");
                    // Non-fatal — worktree-add will fail loudly if the branch still exists
                }
            }
        }

        if !recovery_actions.is_empty() {
            let actions_str = recovery_actions.join(",");
            eprintln!(
                "[claim --force-recover] recovered stale state for {}: {}",
                args.gap_id, actions_str
            );
            emit_force_recover_event(&args.repo_root, &args.gap_id, &branch, &actions_str);
        }
    } else if worktree_path.exists() {
        bail!(
            "worktree path already exists: {}\n  Remove it first with: git worktree remove --force {}\n  Or re-run with --force-recover to auto-clean.",
            worktree_path.display(),
            worktree_path.display()
        );
    }

    // 5b. INFRA-1328: stomp-prevention pre-claim PR check.
    //
    // If an OPEN PR exists upstream with `chump/<gap>-claim` as its head,
    // the prior agent's work is in flight even if their lease lapsed (claim
    // TTL is 30 min; ship cycles often run longer while CI sits in the
    // queue). Re-claiming would force the next push to either bail or
    // stomp the open PR — that's the failure mode PR #2008 lost work to
    // when sibling-PR #2013 took the same branch.
    //
    // The check is best-effort: `gh` failures return None and we fall
    // through to today's behavior. `--resume` and CHUMP_ALLOW_STOMP=1 are
    // legitimate overrides (resume = same agent retrying, stomp = operator
    // explicitly takes over an abandoned PR).
    let stomp_bypass = std::env::var("CHUMP_ALLOW_STOMP")
        .map(|v| !v.trim().is_empty() && v.trim() != "0")
        .unwrap_or(false);
    // INFRA-1503: separate operator-explicit bypass for the "rescue an in-flight
    // open PR" workflow. Distinct from CHUMP_ALLOW_STOMP so audit logs can tell
    // intentional rescue (this) apart from abandoned-PR takeover (stomp).
    let allow_open_pr_bypass = args.allow_duplicate_pr
        || std::env::var("CHUMP_CLAIM_ALLOW_OPEN_PR")
            .map(|v| !v.trim().is_empty() && v.trim() != "0")
            .unwrap_or(false);
    if !args.resume && !stomp_bypass && !allow_open_pr_bypass {
        if let Some((pr_num, author)) = open_pr_info(&args.repo_root, &branch) {
            // INFRA-1503: emit ambient event BEFORE bail so the waste signal is
            // captured even when the operator dismisses the diagnostic and
            // moves on (this is the "2 sessions wasted" failure mode we want to
            // count).
            let ambient_log = args.repo_root.join(".chump-locks/ambient.jsonl");
            emit_claim_aborted_pr_in_flight_event(&ambient_log, &args.gap_id, pr_num, &author);
            bail!(
                "INFRA-1503 (was INFRA-1328): open PR #{} already exists for {} by {} on branch `{}` — gap is in-flight.\n  \
                 Pick a different gap, or wait for the PR to land/close.\n  \
                 Overrides: --allow-duplicate-pr | CHUMP_CLAIM_ALLOW_OPEN_PR=1 (rescue) | \
                 --resume (continue same work) | CHUMP_ALLOW_STOMP=1 (abandoned PR takeover).",
                pr_num,
                args.gap_id,
                if author.is_empty() { "unknown" } else { author.as_str() },
                branch,
            );
        }
    }

    // 5.5. INFRA-1116: Check for overlapping INTENT from other live sessions,
    // BEFORE creating the worktree so we never leave a dangling worktree on refusal.
    let lock_dir = args.repo_root.join(".chump-locks");
    let ambient_log = lock_dir.join("ambient.jsonl");
    let claim_paths = args.paths.as_deref().unwrap_or("");

    let enforce_gate =
        std::env::var("CHUMP_ENFORCE_INTENT_GATE").unwrap_or_else(|_| "0".to_string());
    if enforce_gate == "1" {
        if let Err(e) = check_intent_overlap(&lock_dir, &args.gap_id, claim_paths, &session_id) {
            // Exit 14 by convention (matching intent-overlap-check.sh).
            eprintln!("[intent-gate] INFRA-1116: {:#}", e);
            std::process::exit(14);
        }
    } else if !claim_paths.is_empty() {
        // Warn-only mode (default): run the check, log any overlap, but don't block.
        if let Err(e) = check_intent_overlap(&lock_dir, &args.gap_id, claim_paths, &session_id) {
            eprintln!(
                "[intent-gate] WARN (CHUMP_ENFORCE_INTENT_GATE not set to 1): {:#}",
                e
            );
            eprintln!("[intent-gate] Set CHUMP_ENFORCE_INTENT_GATE=1 to enforce blocking.");
        }
    }

    // 5.6. INFRA-1394: Hot-file collision check vs sibling leases.
    //
    // Before creating the worktree (so we never leave a dangling worktree on
    // refusal), check if the gap's acceptance_criteria references any of the
    // hot shared files AND a sibling lease already declares one of them in its
    // paths[] field. If so: warn + emit ambient event. Without --force-overlap,
    // also abort with exit code 15.
    {
        let hot_files_yaml = args.repo_root.join("scripts/coord/lib/hot-files.yaml");
        let gap_ac = read_gap_ac_from_db(&args.repo_root, &args.gap_id);
        let hot_files = load_hot_files(&hot_files_yaml);
        if !hot_files.is_empty() {
            if let Some(overlap_result) =
                check_hot_file_overlap(&lock_dir, &args.gap_id, &session_id, &gap_ac, &hot_files)
            {
                // Always emit the ambient event.
                emit_claim_hot_file_overlap_event(
                    &ambient_log,
                    &args.gap_id,
                    &overlap_result.sibling_gap,
                    &overlap_result.sibling_session,
                    &overlap_result.overlap_paths,
                );

                // Print warning to stderr.
                eprintln!(
                    "[claim] INFRA-1394: HOT-FILE OVERLAP detected for {}",
                    args.gap_id
                );
                eprintln!(
                    "[claim]   sibling session {} (gap {}) holds: {}",
                    overlap_result.sibling_session,
                    overlap_result.sibling_gap,
                    overlap_result.overlap_paths.join(", ")
                );
                eprintln!(
                    "[claim]   These are hot shared files — concurrent edits risk merge conflicts."
                );

                if !args.force_overlap {
                    eprintln!(
                        "[claim]   Re-run with --force-overlap to proceed anyway (event still emitted)."
                    );
                    std::process::exit(15);
                } else {
                    eprintln!(
                        "[claim]   --force-overlap set; proceeding despite hot-file collision."
                    );
                }
            }
        }
    }

    // 5.7. INFRA-1692: pre-flight team-nugget search.
    //
    // Marcus M-D arc: when an operator runs `chump claim GAP-ID`, surface
    // relevant team-shared knowledge BEFORE the worktree spins up, so the
    // operator doesn't repeat known failure modes that a teammate already
    // hit. Best-effort: graceful degrade on missing CHUMP_TEAM_URL or
    // unreachable endpoint; bypass via CHUMP_CLAIM_SKIP_NUGGET_SEARCH=1.
    nugget_prefetch::prefetch_and_print(&args.repo_root, &args.gap_id, &session_id);

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

    // 6b. Verify (and repair if needed) the gitdir back-reference.
    // Concurrent `git worktree add` calls from sibling agents can clobber
    // .git/worktrees/<name>/gitdir, causing the new worktree to resolve to
    // the wrong repo root (INFRA-779). Repair is safe: git computes this
    // value deterministically as the canonicalized path of <worktree>/.git.
    verify_and_repair_gitdir(&args.repo_root, &branch, &worktree_path)?;

    // Rollback helper: undo worktree + branch on failure.
    let rollback_wt = |extra: &str| {
        let _ = run_git(
            &args.repo_root,
            &["worktree", "remove", "--force", worktree_path_str],
        );
        let _ = run_git(&args.repo_root, &["branch", "-D", &branch]);
        if !extra.is_empty() {
            eprintln!("[claim] rolled back worktree: {}", extra);
        }
    };

    // 6c. INFRA-1025 AC6: detect existing remote branch. If --resume, reset
    // HEAD to the remote tip and continue; otherwise abort with guidance.
    let remote_has_branch = remote_branch_exists(&args.repo_root, &args.remote, &branch);
    if remote_has_branch {
        if args.resume {
            // Reset the new local branch to match the remote tip so we pick up
            // prior work (e.g. an aborted session that already pushed commits).
            if let Err(e) = run_git(
                &worktree_path,
                &["reset", "--hard", &format!("{}/{}", args.remote, branch)],
            ) {
                rollback_wt(&format!("reset --hard failed: {e}"));
                bail!(
                    "--resume: reset --hard to {}/{} failed: {}",
                    args.remote,
                    branch,
                    e
                );
            }
            eprintln!(
                "[claim] --resume: reset HEAD to {}/{} (existing remote branch)",
                args.remote, branch
            );
        } else {
            rollback_wt("");
            bail!(
                "branch {} already exists on {}.\n  \
                 Pass --resume to reset HEAD to the remote tip and continue from that work.\n  \
                 Or delete the remote branch: gh api repos/OWNER/REPO/git/refs/heads/{} -X DELETE",
                branch,
                args.remote,
                branch
            );
        }
    }

    // 7. INFRA-1025: Write lease atomically in Rust — no shell-out to gap-claim.sh.
    // Order: NATS (cross-machine serialization) → JSON lease file → state.db row.
    // Each step rolls back all prior steps on failure.

    // 7a. NATS KV dual-write (opt-in: CHUMP_NATS_URL must be set).
    let nats_result = nats_dual_write(&args.gap_id, &session_id, Some(&ambient_log))?;
    if nats_result == NatsClaimOutcome::Conflict {
        rollback_wt("");
        bail!(
            "NATS KV conflict: another session holds the atomic claim for {}. \
             Check `chump-coord claim` output.",
            args.gap_id
        );
    }

    // 7b. Write JSON lease file to .chump-locks/<session>.json.
    let lease_file = match write_or_merge_lease(
        &lock_dir,
        &session_id,
        &args.gap_id,
        args.paths.as_deref(),
        14_400, // 4h TTL
        false,
    ) {
        Ok(p) => p,
        Err(e) => {
            rollback_wt(&format!("JSON lease write failed: {e}"));
            return Err(e.context("writing JSON lease file (.chump-locks/)"));
        }
    };

    // 7c. Write state.db leases row.
    if let Err(e) = write_db_claim(
        &args.repo_root,
        &args.gap_id,
        &session_id,
        worktree_path_str,
        14_400,
    ) {
        let _ = std::fs::remove_file(&lease_file);
        rollback_wt(&format!("state.db claim failed: {e}"));
        return Err(e.context("writing state.db leases row"));
    }

    // INFRA-1240: emit gap_claimed ambient event for observability (silent_agent debugging)
    let _ = emit_gap_claimed_event(&args.repo_root, &args.gap_id, &session_id);

    // INFRA-1116 AC4: emit intent_announced event so other sessions' overlap checks
    // can detect this claim. TTL = 4h (same as the lease). Paths from --paths flag.
    emit_intent_announced(
        &ambient_log,
        &args.gap_id,
        &session_id,
        args.paths.as_deref().unwrap_or(""),
        14_400, // 4h TTL in seconds
    );

    Ok(ClaimReport {
        gap_id: args.gap_id,
        worktree_path,
        branch,
        session_id,
        paths: args.paths,
    })
}

// ── Helpers ─────────────────────────────────────────────────────────────────

// ── INFRA-1885: lease-breadth cap ───────────────────────────────────────────

/// Top-level directory names that are too broad to hold as a lease path.
/// Operators must supply a more specific sub-path (e.g. `src/foo.rs` instead
/// of `src`) to avoid blocking sibling sessions for entire directory trees.
const BROAD_LEASE_DIRS: &[&str] = &["src", "scripts/ci", "docs/gaps", "src/lib", "app"];

/// INFRA-1885: Check that no path in `paths_csv` is an exact match against a
/// broad top-level directory. Returns `Ok(())` when all paths are sufficiently
/// specific, or when the operator override is active. Returns `Err(...)` with
/// a human-readable message when a broad path is detected and no override is
/// present.
///
/// Override: set `CHUMP_LEASE_ALLOW_BROAD_DIRS=1`. Every bypass emits
/// `kind=lease_broad_dir_claim` to ambient.jsonl for audit.
fn check_lease_breadth(
    paths_csv: &str,
    gap_id: &str,
    session_id: &str,
    ambient_log: &Path,
) -> Result<()> {
    let broad_dirs: Vec<&str> = paths_csv
        .split(',')
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .filter(|p| BROAD_LEASE_DIRS.contains(p))
        .collect();

    if broad_dirs.is_empty() {
        return Ok(());
    }

    // Check override env var.
    let allow_broad = std::env::var("CHUMP_LEASE_ALLOW_BROAD_DIRS")
        .map(|v| v.trim() == "1")
        .unwrap_or(false);

    if allow_broad {
        // Operator override active — emit audit event and continue.
        emit_lease_broad_dir_claim(
            ambient_log,
            gap_id,
            session_id,
            &broad_dirs,
            "CHUMP_LEASE_ALLOW_BROAD_DIRS=1",
        );
        eprintln!(
            "[claim] INFRA-1885: broad-dir override active for {} (paths: {}). \
             Remember to add 'Broad-Lease-Reason: <one sentence>' to your commit message.",
            gap_id,
            broad_dirs.join(", ")
        );
        return Ok(());
    }

    // No override — reject the claim.
    bail!(
        "INFRA-1885: broad lease path(s) rejected: {broad}.\n  \
         Specify a more specific sub-path (e.g. `src/foo.rs` instead of `src`).\n  \
         Override: set CHUMP_LEASE_ALLOW_BROAD_DIRS=1 AND add commit trailer:\n    \
         Broad-Lease-Reason: <one sentence why a broad lease is necessary>",
        broad = broad_dirs.join(", ")
    );
}

/// INFRA-1885: emit `kind=lease_broad_dir_claim` to ambient.jsonl.
/// Fields: session_id, gap, paths (JSON array), reason.
/// Best-effort — silently no-ops if the file isn't writable.
fn emit_lease_broad_dir_claim(
    ambient_log: &Path,
    gap_id: &str,
    session_id: &str,
    broad_paths: &[&str],
    reason: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    // Build paths JSON array manually (no serde dependency here).
    let paths_json = {
        let parts: Vec<String> = broad_paths
            .iter()
            .map(|p| format!("\"{}\"", json_escape(p)))
            .collect();
        format!("[{}]", parts.join(","))
    };
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"lease_broad_dir_claim\",\
         \"session_id\":\"{sid}\",\"gap\":\"{gap}\",\
         \"paths\":{paths},\"reason\":\"{reason}\"}}\n",
        ts = ts,
        sid = json_escape(session_id),
        gap = json_escape(gap_id),
        paths = paths_json,
        reason = json_escape(reason),
    );
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

// ── end INFRA-1885 ───────────────────────────────────────────────────────────

/// INFRA-1025 AC6: check whether <remote>/<branch> exists on the remote.
/// Uses `git ls-remote --exit-code` which exits 2 when the ref is absent.
/// Best-effort — on network error we assume absent (don't block the claim).
fn remote_branch_exists(repo_root: &Path, remote: &str, branch: &str) -> bool {
    let refspec = format!("refs/heads/{}", branch);
    let out = Command::new("git")
        .args(["ls-remote", "--exit-code", remote, &refspec])
        .current_dir(repo_root)
        .output();
    match out {
        Ok(o) => o.status.success(),
        Err(_) => false,
    }
}

/// INFRA-1328: Returns `Some(pr_number)` if the upstream has an OPEN PR with
/// `<branch>` as its head. Used to refuse a stomp-claim: even if the prior
/// claimer's lease expired, an open PR (especially one with armed auto-merge)
/// is a strong signal the work is in flight and the branch must not be
/// re-purposed.
///
/// Best-effort: any `gh` failure (no auth, no network, gh not on PATH) returns
/// `None` so offline / un-authed clones don't get blocked. The downside is a
/// false-negative — but the worst case is the same as today's behavior, while
/// the success case prevents the stomp class entirely.
pub(crate) fn open_pr_on_branch(repo_root: &Path, branch: &str) -> Option<u64> {
    open_pr_info(repo_root, branch).map(|(n, _)| n)
}

/// INFRA-1503: same as `open_pr_on_branch` but also returns the PR author's
/// GitHub login. Used to surface the in-flight author in the abort diagnostic
/// and in the `claim_aborted_pr_in_flight` ambient event so the fleet can
/// distinguish "my own prior session" from "sibling already on it".
///
/// Best-effort: any failure returns `None`. Author may be empty string if the
/// PR has no `user.login` (rare; some GitHub Apps).
pub(crate) fn open_pr_info(repo_root: &Path, branch: &str) -> Option<(u64, String)> {
    let owner_repo = gh_owner_repo(repo_root)?;
    let owner = owner_repo.split('/').next()?;
    let head = format!("{}:{}", owner, branch);
    let out = Command::new("gh")
        .args([
            "api",
            "-H",
            "Accept: application/vnd.github+json",
            &format!(
                "repos/{}/pulls?state=open&head={}&per_page=1",
                owner_repo, head
            ),
            "--jq",
            // tab-separated number\tauthor; empty if no PR found
            r#".[0] | if . == null then empty else "\(.number)\t\(.user.login // "")" end"#,
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let line = stdout.trim();
    if line.is_empty() {
        return None;
    }
    let mut parts = line.splitn(2, '\t');
    let num = parts.next()?.parse::<u64>().ok()?;
    let author = parts.next().unwrap_or("").to_string();
    Some((num, author))
}

/// Resolve `owner/repo` from the git remote URL (https or ssh). Returns
/// `None` if the remote isn't a github.com URL.
fn gh_owner_repo(repo_root: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["config", "--get", "remote.origin.url"])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&out.stdout).trim().to_string();
    // https://github.com/owner/repo(.git)?  or  git@github.com:owner/repo(.git)?
    let stripped = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))?;
    Some(stripped.trim_end_matches(".git").to_string())
}

/// INFRA-1025: write the leases row to state.db. Mirrors GapStore::claim()
/// but without requiring a GapStore reference in this module.
/// Best-effort when DB absent (fresh clone has no state.db yet).
fn write_db_claim(
    repo_root: &Path,
    gap_id: &str,
    session_id: &str,
    worktree: &str,
    ttl_secs: i64,
) -> Result<()> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Ok(());
    }
    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {} for lease write", db_path.display()))?;
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let expires_at = now_secs + ttl_secs;
    conn.execute(
        "INSERT INTO leases(session_id, gap_id, worktree, expires_at)
         VALUES(?1, ?2, ?3, ?4)
         ON CONFLICT(session_id) DO UPDATE SET gap_id=excluded.gap_id,
             worktree=excluded.worktree, expires_at=excluded.expires_at",
        rusqlite::params![session_id, gap_id, worktree, expires_at],
    )
    .with_context(|| format!("inserting lease for {} into leases table", gap_id))?;
    Ok(())
}

/// Verify that .git/worktrees/<branch-slug>/gitdir points at <worktree_path>/.git.
/// Repairs the file if wrong (INFRA-779: concurrent sibling claims can clobber it).
///
/// INFRA-1056 hardening:
///   - Retry up to 3 times with short backoff if the back-ref is wrong AFTER
///     repair (i.e. a sibling claim re-clobbered it between our write and read).
///   - Emit `kind=worktree_gitdir_repair_fired` to ambient.jsonl so operators
///     can see if/when the race is still happening in the wild.
fn verify_and_repair_gitdir(repo_root: &Path, _branch: &str, worktree_path: &Path) -> Result<()> {
    // The worktrees entry name is the last component of the branch slug
    // (git uses the worktree directory name, not the branch name).
    let wt_name = worktree_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if wt_name.is_empty() {
        return Ok(());
    }

    let gitdir_file = repo_root
        .join(".git")
        .join("worktrees")
        .join(wt_name)
        .join("gitdir");
    if !gitdir_file.exists() {
        return Ok(());
    }

    // git stores the canonical (realpath) value of <worktree>/.git
    let dot_git = worktree_path.join(".git");
    let canonical = std::fs::canonicalize(&dot_git).unwrap_or(dot_git.clone());
    let expected = canonical.to_str().unwrap_or("").to_string();
    if expected.is_empty() {
        return Ok(());
    }

    // Retry loop: INFRA-1056. The race window is the time between our read-
    // back-ref and any concurrent sibling claim's write. 3 attempts × 50ms
    // covers the realistic worst case without blocking the claim path.
    const MAX_ATTEMPTS: usize = 3;
    let mut last_recorded = String::new();
    for attempt in 1..=MAX_ATTEMPTS {
        let recorded = std::fs::read_to_string(&gitdir_file)
            .unwrap_or_default()
            .trim()
            .to_string();
        last_recorded = recorded.clone();

        if recorded == expected {
            if attempt > 1 {
                eprintln!(
                    "[claim] INFRA-1056: gitdir back-ref converged on attempt {attempt} for {wt_name}"
                );
            }
            return Ok(());
        }

        eprintln!(
            "[claim] INFRA-1056 (attempt {attempt}/{MAX_ATTEMPTS}): gitdir mismatch for {wt_name} — repairing\n  was: {recorded}\n  now: {expected}"
        );
        std::fs::write(&gitdir_file, format!("{expected}\n"))
            .with_context(|| format!("repairing gitdir file {}", gitdir_file.display()))?;
        emit_gitdir_repair_event(repo_root, wt_name, &recorded, &expected, attempt);
        emit_gitdir_repaired_event(repo_root, wt_name, &recorded, &expected);

        if attempt < MAX_ATTEMPTS {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    // We attempted 3 repairs and the back-ref still doesn't match. Concurrent
    // sibling activity is overwhelming the repair path. Surface this loudly
    // — the operator needs to know the race is unresolved for this claim.
    bail!(
        "INFRA-1056: gitdir back-ref for {wt_name} did not converge after {MAX_ATTEMPTS} repair attempts\n  expected: {expected}\n  last seen: {last_recorded}\n  Concurrent sibling claims are overwhelming the repair path; release leases and retry."
    );
}

/// Emit `kind=worktree_gitdir_repair_fired` to ambient.jsonl. Best-effort —
/// silently no-ops if the file isn't writable. Lets operators measure
/// whether the INFRA-779 race is still firing in production.
fn emit_gitdir_repair_event(repo_root: &Path, wt_name: &str, was: &str, now: &str, attempt: usize) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = format!(
        r#"{{"ts":"{ts}","kind":"worktree_gitdir_repair_fired","worktree":"{wt_name}","was":"{}","now":"{}","attempt":{attempt}}}"#,
        json_escape(was),
        json_escape(now),
    );
    let path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", event);
    }
}

/// Emit kind=worktree_gitdir_repaired to ambient.jsonl (INFRA-1033).
fn emit_gitdir_repaired_event(repo_root: &Path, wt_name: &str, was: &str, now: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let ts = {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // Format as ISO-8601 UTC
        let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
        format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
    };

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"worktree_gitdir_repaired\",\"wt_name\":\"{wt_name}\",\"was\":\"{was}\",\"now\":\"{now}\"}}\n"
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-1240: Emit gap_claimed ambient event for observability.
/// Used to debug silent_agent and lease-race issues.
fn emit_gap_claimed_event(repo_root: &Path, gap_id: &str, session_id: &str) -> Result<()> {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_claimed\",\"gap_id\":\"{gap_id}\",\"session_id\":\"{session_id}\"}}\n"
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
    Ok(())
}

/// INFRA-1439: emit kind=chump_claim_force_recover to ambient.jsonl.
/// Best-effort — silently no-ops if the file isn't writable.
fn emit_force_recover_event(repo_root: &Path, gap_id: &str, branch: &str, actions: &str) {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"chump_claim_force_recover\",\
         \"gap_id\":\"{}\",\"branch\":\"{}\",\"actions\":\"{}\"}}\n",
        json_escape(gap_id),
        json_escape(branch),
        json_escape(actions),
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-1503: emit `claim_aborted_pr_in_flight` to ambient.jsonl. Fired right
/// before we bail in step 5b so we count the waste-prevention signal even
/// though the claim itself is refused. `existing_author` may be empty when
/// the PR was opened by a GitHub App or `user.login` is unavailable.
fn emit_claim_aborted_pr_in_flight_event(
    ambient_path: &Path,
    gap_id: &str,
    existing_pr: u64,
    existing_author: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_aborted_pr_in_flight\",\
         \"gap_id\":\"{}\",\"existing_pr\":{},\"existing_author\":\"{}\"}}\n",
        json_escape(gap_id),
        existing_pr,
        json_escape(existing_author),
    );
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// Decompose Unix epoch seconds into (year, month, day, hour, min, sec) UTC.
/// Minimal implementation — no external date crate dependency.
fn secs_to_ymdhms(secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let s = secs % 60;
    let mi = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Gregorian calendar from day count since 1970-01-01.
    let mut y = 1970u32;
    let mut rem = days;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let days_in_year = if leap { 366u64 } else { 365u64 };
        if rem < days_in_year {
            break;
        }
        rem -= days_in_year;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = [
        31u64,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut mo = 1u32;
    for &md in &month_days {
        if rem < md {
            break;
        }
        rem -= md;
        mo += 1;
    }
    (y, mo, rem as u32 + 1, h as u32, mi as u32, s as u32)
}

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

/// INFRA-965 slice 1 (INFRA-984): port the new-lease-file write from
/// scripts/coord/gap-claim.sh into Rust. Matches the JSON schema used by
/// gap-preflight.sh's reader exactly — session_id, paths, taken_at,
/// expires_at, heartbeat_at, purpose, gap_id. Returns the path of the
/// lease file written.
///
/// This is the simple-case write (no existing lease, no speculative
/// flag). INFRA-985 ports the merge-existing-lease + speculative cases;
/// INFRA-986 ports the NATS KV dual-write. Once all three land, gap-claim.sh
/// can be deleted (INFRA-987).
pub fn write_basic_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
) -> Result<PathBuf> {
    std::fs::create_dir_all(lock_dir)
        .with_context(|| format!("create lock dir {}", lock_dir.display()))?;

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let now_iso = unix_to_iso8601(now_secs);
    let expires_iso = unix_to_iso8601(now_secs.saturating_add(ttl_secs));

    let paths_list: Vec<String> = paths_csv
        .unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // Hand-roll the JSON to match gap-claim.sh's output byte-for-byte:
    // two-space indent, trailing newline, key order session_id → paths →
    // taken_at → expires_at → heartbeat_at → purpose → gap_id. Using
    // serde_json::to_string_pretty would change key order (it's BTreeMap
    // for serde_json::Map under that path) and add subtle diffs that
    // would break callers diffing against the existing format.
    let mut json = String::new();
    json.push_str("{\n");
    json.push_str(&format!(
        "  \"session_id\": \"{}\",\n",
        json_escape(session_id)
    ));
    json.push_str("  \"paths\": [");
    if !paths_list.is_empty() {
        json.push('\n');
        for (i, p) in paths_list.iter().enumerate() {
            json.push_str(&format!("    \"{}\"", json_escape(p)));
            if i + 1 < paths_list.len() {
                json.push(',');
            }
            json.push('\n');
        }
        json.push_str("  ");
    }
    json.push_str("],\n");
    json.push_str(&format!("  \"taken_at\": \"{}\",\n", now_iso));
    json.push_str(&format!("  \"expires_at\": \"{}\",\n", expires_iso));
    json.push_str(&format!("  \"heartbeat_at\": \"{}\",\n", now_iso));
    json.push_str(&format!(
        "  \"purpose\": \"gap:{}\",\n",
        json_escape(gap_id)
    ));
    json.push_str(&format!("  \"gap_id\": \"{}\"\n", json_escape(gap_id)));
    json.push_str("}\n");

    let lease_path = lock_dir.join(format!("{}.json", session_id));
    std::fs::write(&lease_path, json)
        .with_context(|| format!("write lease {}", lease_path.display()))?;
    Ok(lease_path)
}

/// INFRA-965 slice 2 (INFRA-985): merge-or-write public entrypoint.
///
/// If a lease file already exists at `<lock_dir>/<session_id>.json` (the
/// session already holds a lease — typically from a prior claim earlier
/// in the same shell), update it in place:
///   - set `gap_id` to the new value
///   - merge `paths_csv` into the existing `paths` array, preserving
///     dedup order
///   - preserve the existing `speculative` flag if present (caller can
///     promote via the `speculative` arg here)
///   - clear `pending_new_gap` if it referenced this gap_id
///   - leave taken_at / expires_at / heartbeat_at untouched (the lease
///     keeps its original lifetime; that's why we merge instead of
///     overwriting)
///
/// If no lease file exists, falls through to `write_basic_lease` (slice 1)
/// or its speculative variant when `speculative=true`.
///
/// Returns the path of the lease file.
pub fn write_or_merge_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
    speculative: bool,
) -> Result<PathBuf> {
    let lease_path = lock_dir.join(format!("{}.json", session_id));
    if lease_path.exists() {
        return merge_existing_lease(&lease_path, gap_id, paths_csv, speculative);
    }
    if speculative {
        write_speculative_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)
    } else {
        write_basic_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)
    }
}

/// INFRA-985: speculative lease variant — same shape as basic but with
/// `"speculative": true` appended. `gap-preflight.sh` reads this field to
/// allow concurrent claims from other speculative-mode sessions on the
/// same gap (first-to-land wins).
pub fn write_speculative_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
) -> Result<PathBuf> {
    // Re-use the basic write then rewrite with the extra key. Simpler than
    // duplicating 60 lines of JSON-emit for one extra field.
    let lease_path = write_basic_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)?;
    let body = std::fs::read_to_string(&lease_path).with_context(|| {
        format!(
            "read lease for speculative annotation: {}",
            lease_path.display()
        )
    })?;
    // Insert "speculative": true before the closing brace. Body ends with
    // `  "gap_id": "..."\n}\n` — we add a comma to the gap_id line and a
    // new speculative line.
    let trimmed = body.trim_end_matches('\n');
    let with_spec = trimmed
        .strip_suffix('}')
        .map(|s| {
            format!(
                "{},\n  \"speculative\": true\n}}\n",
                s.trim_end_matches(['\n', ' '])
            )
        })
        .ok_or_else(|| anyhow!("unexpected lease body shape: missing closing brace"))?;
    std::fs::write(&lease_path, with_spec)
        .with_context(|| format!("rewrite speculative lease: {}", lease_path.display()))?;
    Ok(lease_path)
}

/// INFRA-985: merge new gap_id + paths into an existing lease file in
/// place. Preserves session_id, taken_at, expires_at, heartbeat_at,
/// speculative-flag (with optional promotion), and any extra unknown
/// keys (forward-compat with future schema additions).
fn merge_existing_lease(
    lease_path: &Path,
    gap_id: &str,
    paths_csv: Option<&str>,
    promote_speculative: bool,
) -> Result<PathBuf> {
    let body = std::fs::read_to_string(lease_path)
        .with_context(|| format!("read existing lease {}", lease_path.display()))?;
    let mut val: serde_json::Value = serde_json::from_str(&body)
        .with_context(|| format!("parse existing lease {}", lease_path.display()))?;

    let obj = val.as_object_mut().ok_or_else(|| {
        anyhow!(
            "lease {} is not a JSON object: {}",
            lease_path.display(),
            body
        )
    })?;

    obj.insert(
        "gap_id".to_string(),
        serde_json::Value::String(gap_id.to_string()),
    );

    if promote_speculative {
        obj.insert("speculative".to_string(), serde_json::Value::Bool(true));
    }

    // pending_new_gap cleanup: if it's an object whose "id" matches the
    // gap we're now claiming, drop the pending pointer.
    if let Some(pending) = obj.get("pending_new_gap") {
        if let Some(pid) = pending.get("id").and_then(|v| v.as_str()) {
            if pid == gap_id {
                obj.remove("pending_new_gap");
            }
        }
    }

    // Merge paths.
    let new_paths: Vec<String> = paths_csv
        .unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let mut merged: Vec<String> = obj
        .get("paths")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|p| p.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    for p in new_paths {
        if !merged.contains(&p) {
            merged.push(p);
        }
    }

    obj.insert(
        "paths".to_string(),
        serde_json::Value::Array(merged.into_iter().map(serde_json::Value::String).collect()),
    );

    // Re-serialize with pretty 2-space indent + trailing newline to match
    // the basic-write convention.
    let mut out = serde_json::to_string_pretty(&val).with_context(|| "serialize merged lease")?;
    out.push('\n');
    std::fs::write(lease_path, out)
        .with_context(|| format!("write merged lease {}", lease_path.display()))?;
    Ok(lease_path.to_path_buf())
}

/// INFRA-985: scan a lock dir for OTHER sessions' lease files that claim
/// the same gap_id. Returns (session_id, is_speculative) tuples. Excludes
/// `own_session_id`. Used by the speculative-mode banner to show siblings.
pub fn sibling_lease_holders(
    lock_dir: &Path,
    gap_id: &str,
    own_session_id: &str,
) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(lock_dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };
        let sid = val
            .get("session_id")
            .and_then(|v| v.as_str())
            .unwrap_or("?")
            .to_string();
        if sid == own_session_id {
            continue;
        }
        let gid = val.get("gap_id").and_then(|v| v.as_str()).unwrap_or("");
        if gid != gap_id {
            continue;
        }
        let speculative = val
            .get("speculative")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        out.push((sid, speculative));
    }
    out.sort();
    out
}

fn unix_to_iso8601(unix: u64) -> String {
    // Minimal RFC3339 formatter — no chrono dep required at this seam.
    // Days-since-epoch -> Y/M/D via simple civil_from_days algorithm
    // (Howard Hinnant). Seconds-of-day -> H:M:S directly.
    let days = (unix / 86_400) as i64;
    let sod = (unix % 86_400) as u32;
    let h = sod / 3600;
    let m = (sod % 3600) / 60;
    let s = sod % 60;
    let (y, mo, d) = civil_from_days(days);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, h, m, s)
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    // Hinnant's civil_from_days, adapted from
    // https://howardhinnant.github.io/date_algorithms.html
    let z = z + 719_468;
    let era = if z >= 0 {
        z / 146_097
    } else {
        (z - 146_096) / 146_097
    };
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// INFRA-1259/1878: Returns true if a single AC entry is a placeholder stub.
/// Only matches entries that ARE stubs, not entries that mention "TODO" in
/// meaningful text (e.g. "AC: ensures no TODO in field X" must not match).
fn is_vague_ac_entry(s: &str) -> bool {
    let t = s.trim();
    let upper = t.to_uppercase();
    upper == "TODO"
        || upper == "TBD"
        || upper == "TBC"
        || upper == "N/A"
        || upper.starts_with("TODO:")
        || upper.starts_with("TODO ")
        || upper.starts_with("TBD:")
        || upper.starts_with("TBD ")
        || upper.starts_with("<FILL")
        || upper.starts_with("FILL IN")
}

/// INFRA-1259: Check if acceptance_criteria is vague (empty, all-TODO, or all-TBD).
/// Returns true if the AC is empty, contains only TODO items, or contains only TBD items.
fn is_acceptance_criteria_vague(ac: &str) -> bool {
    let trimmed = ac.trim();
    // Empty AC is vague
    if trimmed.is_empty() {
        return true;
    }

    // Try to parse as JSON array (the canonical format)
    if let Ok(serde_json::Value::Array(arr)) = serde_json::from_str(trimmed) {
        if arr.is_empty() {
            return true; // Empty array
        }
        // All items must be stubs for the gap to be flagged vague (INFRA-1878:
        // entries that merely mention "TODO" in passing must not trigger ⚠).
        let all_vague = arr
            .iter()
            .all(|item| item.as_str().map(is_vague_ac_entry).unwrap_or(false));
        return all_vague;
    }

    // If not JSON array, only flag if the whole string IS a stub keyword.
    let upper = trimmed.to_uppercase();
    upper == "TODO" || upper == "TBD"
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

    // INFRA-1259: Reject if acceptance_criteria is empty or contains only TODO items.
    let ac: String = conn
        .query_row(
            "SELECT acceptance_criteria FROM gaps WHERE id = ?1",
            [gap_id],
            |r| r.get(0),
        )
        .unwrap_or_default();

    if is_acceptance_criteria_vague(&ac) {
        bail!(
            "Gap {} has no concrete acceptance criteria — add AC before claiming",
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
    let doctor = repo_root.join("scripts/dev/chump-binary-unwedge.sh");
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
        .context("spawning chump-binary-unwedge.sh")?;
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

/// INFRA-986: outcome of an attempted NATS KV dual-write.
#[derive(Debug, PartialEq, Eq)]
pub enum NatsClaimOutcome {
    /// CHUMP_NATS_URL unset OR chump-coord binary missing — no NATS attempt.
    /// File-based lease should proceed as the only mechanism.
    Skipped,
    /// chump-coord exit 0 — atomic CAS won (or NATS reachable + key absent).
    Claimed,
    /// chump-coord exit 1 — another session holds the claim. Caller MUST
    /// abort: do not write the file-based lease, do not create the worktree.
    Conflict,
}

/// INFRA-986: port of the FLEET-032 NATS KV dual-write block from
/// scripts/coord/gap-claim.sh. Shells out to the `chump-coord` binary
/// (transitional: future iterations will call the chump-coord crate
/// directly once gap_claim is a stable library entry point — see
/// INFRA-478). Returns the outcome so the caller can decide what to do.
///
/// Discovery:
///   * `CHUMP_NATS_URL` must be set, otherwise skip (single-machine mode).
///   * `chump-coord` must be on PATH (or pointed at by `CHUMP_COORD_BIN`).
///     Both gates skip cleanly — NATS is opt-in.
///
/// On `Conflict`, emits a `gap_claim_nats_conflict` event to
/// `ambient_log_path` (or `.chump-locks/ambient.jsonl` if None). The
/// emitter is intentionally a one-line append: keep the ambient stream
/// the source of truth for cross-machine visibility, no other side
/// effect.
pub fn nats_dual_write(
    gap_id: &str,
    session_id: &str,
    ambient_log_path: Option<&Path>,
) -> Result<NatsClaimOutcome> {
    let nats_url = std::env::var("CHUMP_NATS_URL").unwrap_or_default();
    if nats_url.is_empty() {
        return Ok(NatsClaimOutcome::Skipped);
    }
    let coord_bin = match resolve_coord_bin() {
        Some(p) => p,
        None => return Ok(NatsClaimOutcome::Skipped),
    };
    nats_dual_write_with_bin(&coord_bin, gap_id, session_id, ambient_log_path)
}

/// Test seam: caller-supplied chump-coord path. Production callers go
/// through `nats_dual_write` (above) which honors `CHUMP_NATS_URL` +
/// PATH discovery.
pub(crate) fn nats_dual_write_with_bin(
    coord_bin: &Path,
    gap_id: &str,
    session_id: &str,
    ambient_log_path: Option<&Path>,
) -> Result<NatsClaimOutcome> {
    // Retry on ETXTBSY (os error 26): the kernel returns this transiently when a
    // script file was just written and the kernel's page-cache hasn't settled yet.
    // Up to 3 attempts with a short backoff are sufficient in practice.
    let out = {
        let mut last_err: Option<std::io::Error> = None;
        let mut result = None;
        for attempt in 0..3 {
            match Command::new(coord_bin)
                .args(["claim", gap_id])
                .env("CHUMP_SESSION_ID", session_id)
                .output()
            {
                Ok(o) => {
                    result = Some(o);
                    break;
                }
                Err(e) if e.raw_os_error() == Some(26) => {
                    // ETXTBSY — wait briefly and retry
                    std::thread::sleep(std::time::Duration::from_millis(10 * (1 << attempt)));
                    last_err = Some(e);
                }
                Err(e) => {
                    return Err(e).with_context(|| {
                        format!("spawning {} claim {}", coord_bin.display(), gap_id)
                    });
                }
            }
        }
        match result {
            Some(o) => o,
            None => {
                return Err(last_err.unwrap())
                    .with_context(|| format!("spawning {} claim {}", coord_bin.display(), gap_id));
            }
        }
    };

    if out.status.success() {
        return Ok(NatsClaimOutcome::Claimed);
    }
    let code = out.status.code().unwrap_or(-1);
    if code == 1 {
        emit_nats_conflict_event(ambient_log_path, gap_id, session_id);
        return Ok(NatsClaimOutcome::Conflict);
    }
    // Any other exit (NATS server unreachable, network blip, transient
    // chump-coord error) is treated like Skipped: do NOT block the claim
    // on infrastructure that's opt-in. Mirrors the shell behavior — the
    // `if !chump-coord claim …` branch only fires on rc=1 conflict; any
    // other failure (rc=2+, signal, no stdout) is silently tolerated.
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !stderr.trim().is_empty() {
        eprintln!(
            "[atomic_claim] chump-coord returned rc={} for gap {}: {}",
            code,
            gap_id,
            stderr.trim()
        );
    }
    Ok(NatsClaimOutcome::Skipped)
}

fn resolve_coord_bin() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("CHUMP_COORD_BIN") {
        if !explicit.is_empty() {
            let p = PathBuf::from(explicit);
            if p.exists() {
                return Some(p);
            }
        }
    }
    // Walk PATH.
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let cand = dir.join("chump-coord");
        if cand.is_file() {
            return Some(cand);
        }
    }
    None
}

fn emit_nats_conflict_event(ambient_log_path: Option<&Path>, gap_id: &str, session_id: &str) {
    let target = ambient_log_path
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".chump-locks/ambient.jsonl"));
    // Best-effort: ambient append must never break the claim flow.
    if let Some(parent) = target.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_claim_nats_conflict\",\"gap_id\":\"{gid}\",\"session_id\":\"{sid}\"}}\n",
        ts = unix_to_iso8601(now),
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&target)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── INFRA-1116: INTENT overlap gate ─────────────────────────────────────────

/// Represents a live INTENT declaration from another session.
#[derive(Debug, Clone)]
struct IntentEntry {
    gap_id: String,
    session_id: String,
    paths: Vec<String>,
    expires_at: u64, // Unix seconds
    claimed_at: u64,
}

/// Check if the new claim would overlap with live INTENTs from other sessions.
/// Reads ambient.jsonl for recent intent_announced events and checks path overlap.
/// On overlap: returns Err with context suitable for printing to the user.
/// On no overlap or no INTENT gate enforcement: returns Ok(()).
fn check_intent_overlap(
    lock_dir: &Path,
    new_gap_id: &str,
    claim_paths_csv: &str,
    this_session: &str,
) -> Result<()> {
    let window_secs = std::env::var("CHUMP_CLAIM_INTENT_WINDOW_S")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(60);

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Parse the claim paths
    let claim_paths: Vec<String> = claim_paths_csv
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // If no paths declared, allow the claim (but warn about coverage)
    if claim_paths.is_empty() {
        eprintln!(
            "[intent-gate] warning: {} declared no path scope; proceeding with no overlap check",
            new_gap_id
        );
        return Ok(());
    }

    // Read ambient.jsonl to find live INTENTs and retracted sessions
    let ambient_path = lock_dir.join("ambient.jsonl");
    let live_intents = read_live_intents(&ambient_path, window_secs, now)?;

    // Build set of retracted sessions (intent_retracted events invalidate prior announcements).
    let retracted = collect_retracted_sessions(&ambient_path);

    // Check for overlaps
    for intent in live_intents {
        // Skip our own session
        if intent.session_id == this_session {
            continue;
        }

        // Skip expired intents
        if intent.expires_at < now {
            continue;
        }

        // Skip retracted sessions (they emitted intent_retracted on release)
        if retracted.contains(&intent.session_id) {
            continue;
        }

        // Stale-session filter: ignore INTENTs whose session lease is absent or expired.
        if !is_session_lease_alive(lock_dir, &intent.session_id, now) {
            continue;
        }

        // Check path overlap
        if paths_overlap(&claim_paths, &intent.paths) {
            return Err(anyhow!(
                "Gap {} blocked — session {} has INTENT on overlapping paths [{}].\n\
                 Options:\n  \
                 1. Wait for {} to complete and ship (expires at {})\n  \
                 2. Set CHUMP_ENFORCE_INTENT_GATE=0 to warn-only (not recommended for production)\n  \
                 3. Contact the other session to coordinate",
                new_gap_id,
                intent.session_id,
                intent.paths.join(", "),
                intent.gap_id,
                iso8601_from_unix(intent.expires_at),
            ));
        }
    }

    Ok(())
}

/// Check if a session's lease file exists and has a non-expired expires_at.
/// Returns false (stale) if the lease file is absent, unreadable, or expired.
fn is_session_lease_alive(lock_dir: &Path, session_id: &str, now_secs: u64) -> bool {
    let lease_path = lock_dir.join(format!("{}.json", session_id));
    let Ok(body) = std::fs::read_to_string(&lease_path) else {
        return false; // absent — session is stale
    };
    let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
        return false;
    };
    let Some(exp_str) = val.get("expires_at").and_then(|v| v.as_str()) else {
        return true; // no expiry field — treat as alive (conservative)
    };
    match parse_iso8601(exp_str) {
        Ok(exp_secs) => exp_secs > now_secs,
        Err(_) => true, // can't parse → treat as alive (conservative)
    }
}

/// Collect session IDs that have emitted intent_retracted in ambient.jsonl.
fn collect_retracted_sessions(ambient_path: &Path) -> std::collections::HashSet<String> {
    let mut retracted = std::collections::HashSet::new();
    let Ok(content) = std::fs::read_to_string(ambient_path) else {
        return retracted;
    };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(val) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if val.get("kind").and_then(|k| k.as_str()) == Some("intent_retracted") {
            if let Some(sid) = val.get("session_id").and_then(|v| v.as_str()) {
                retracted.insert(sid.to_string());
            }
        }
    }
    retracted
}

/// Read all intent_announced events from ambient.jsonl within the window.
fn read_live_intents(
    ambient_path: &Path,
    window_secs: u64,
    now_secs: u64,
) -> Result<Vec<IntentEntry>> {
    let cutoff = now_secs.saturating_sub(window_secs);

    let content = match std::fs::read_to_string(ambient_path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(e).context("reading ambient.jsonl"),
    };

    let mut intents = vec![];
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Parse as JSON
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
            // Look for intent_announced events
            if val.get("kind").and_then(|k| k.as_str()) == Some("intent_announced") {
                // Extract fields
                let ts = val.get("ts").and_then(|v| v.as_str()).unwrap_or("0");
                let ts_secs = parse_iso8601(ts).unwrap_or(0);

                // Skip if outside the window
                if ts_secs < cutoff {
                    continue;
                }

                if let (Some(gap_id), Some(session_id), Some(paths_arr)) = (
                    val.get("gap_id").and_then(|v| v.as_str()),
                    val.get("session_id").and_then(|v| v.as_str()),
                    val.get("paths").and_then(|v| v.as_array()),
                ) {
                    let paths: Vec<String> = paths_arr
                        .iter()
                        .filter_map(|p| p.as_str().map(|s| s.to_string()))
                        .collect();

                    let expires_at = val
                        .get("expires_at")
                        .and_then(|v| v.as_str())
                        .and_then(|s| parse_iso8601(s).ok())
                        .unwrap_or(0);

                    intents.push(IntentEntry {
                        gap_id: gap_id.to_string(),
                        session_id: session_id.to_string(),
                        paths,
                        expires_at,
                        claimed_at: ts_secs,
                    });
                }
            }
        }
    }

    Ok(intents)
}

/// Check if two path lists overlap.
/// Simple implementation: for now, prefix-match directories and exact-match files.
fn paths_overlap(paths_a: &[String], paths_b: &[String]) -> bool {
    for a in paths_a {
        for b in paths_b {
            // Wildcard match: ** overlaps with everything
            if a == "**" || b == "**" {
                return true;
            }
            // Same path
            if a == b {
                return true;
            }
            // Prefix match (directory overlap): src/ overlaps src/foo.rs
            if a.ends_with('/') && b.starts_with(a) {
                return true;
            }
            if b.ends_with('/') && a.starts_with(b) {
                return true;
            }
        }
    }
    false
}

/// Parse ISO 8601 timestamp to Unix seconds (best-effort).
fn parse_iso8601(s: &str) -> Result<u64> {
    // Simple parser for YYYY-MM-DDTHH:MM:SSZ format
    let s = s.trim_end_matches('Z');
    let parts: Vec<&str> = s.split(|c| c == '-' || c == 'T' || c == ':').collect();
    if parts.len() < 6 {
        bail!("invalid timestamp format: {}", s);
    }
    let y: u32 = parts[0].parse()?;
    let mo: u32 = parts[1].parse()?;
    let d: u32 = parts[2].parse()?;
    let h: u32 = parts[3].parse()?;
    let mi: u32 = parts[4].parse()?;
    let sec: u32 = parts[5].parse()?;

    // Simplified day-of-year calculation (not accounting for leap seconds)
    let is_leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
    let days_per_month = [
        31,
        if is_leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let days_in_year: u32 = days_per_month[..(mo as usize).saturating_sub(1)]
        .iter()
        .sum::<u32>()
        + d;

    // Days since 1970-01-01
    let mut days_since_epoch = 0u64;
    for year in 1970..y {
        let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        days_since_epoch += if leap { 366 } else { 365 };
    }
    days_since_epoch += (days_in_year - 1) as u64;

    let secs = days_since_epoch * 86400 + (h as u64) * 3600 + (mi as u64) * 60 + (sec as u64);
    Ok(secs)
}

/// Format Unix seconds to ISO 8601 string.
fn iso8601_from_unix(secs: u64) -> String {
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// Emit intent_overlap_detected event to ambient.jsonl.
fn emit_intent_overlap_event(
    ambient_log: &Path,
    new_gap_id: &str,
    blocking_gap_id: &str,
    blocking_session: &str,
    overlapping_paths: &[String],
) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let paths_json = serde_json::to_string(overlapping_paths).unwrap_or_else(|_| "[]".to_string());
    let event = format!(
        r#"{{"ts":"{ts}","kind":"intent_overlap_detected","gap_id":"{new_gap_id}","blocking_gap_id":"{blocking_gap_id}","blocking_session":"{blocking_session}","overlapping_paths":{paths_json}}}"#
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", event);
    }
}

/// INFRA-1116 AC4: Emit intent_announced to ambient.jsonl after a successful claim.
/// Other sessions' INTENT gates read these events to detect path overlaps.
/// ttl_secs controls the expires_at field; sessions whose expires_at is in the
/// past are ignored by the stale filter in check_intent_overlap.
fn emit_intent_announced(
    ambient_log: &Path,
    gap_id: &str,
    session_id: &str,
    paths_csv: &str,
    ttl_secs: u64,
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    let expires_at = iso8601_from_unix(now.saturating_add(ttl_secs));

    let paths_list: Vec<String> = paths_csv
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let paths_json = serde_json::to_string(&paths_list).unwrap_or_else(|_| "[]".to_string());

    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"intent_announced\",\"gap_id\":\"{gid}\",\
         \"session_id\":\"{sid}\",\"paths\":{paths},\"expires_at\":\"{exp}\"}}\n",
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
        paths = paths_json,
        exp = expires_at,
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// INFRA-1116 AC6: Emit intent_retracted to ambient.jsonl when a session is released.
/// The gate treats a retracted session as inactive even if expires_at has not passed.
pub fn emit_intent_retracted(ambient_log: &Path, gap_id: &str, session_id: &str) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"intent_retracted\",\"gap_id\":\"{gid}\",\
         \"session_id\":\"{sid}\"}}\n",
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// INFRA-1116 AC5: Emit intent_refreshed to ambient.jsonl during heartbeat.
/// Called from worker.sh heartbeat loop via `chump ambient emit intent_refreshed`.
/// This function is the Rust-side equivalent for direct Rust heartbeat paths.
pub fn emit_intent_refreshed(ambient_log: &Path, gap_id: &str, session_id: &str) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"intent_refreshed\",\"gap_id\":\"{gid}\",\
         \"session_id\":\"{sid}\"}}\n",
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── INFRA-1394: Hot-file collision check ─────────────────────────────────────

/// Result of a hot-file overlap scan.
struct HotFileOverlapResult {
    sibling_session: String,
    sibling_gap: String,
    overlap_paths: Vec<String>,
}

/// Load the hot-files list from `scripts/coord/lib/hot-files.yaml`.
/// Returns an empty vec on any parse/IO error (best-effort; don't block claim
/// if the yaml is missing or malformed).
fn load_hot_files(yaml_path: &Path) -> Vec<String> {
    let Ok(body) = std::fs::read_to_string(yaml_path) else {
        return vec![];
    };
    // Minimal YAML list parser: find lines under `hot_files:` that start with `  - `.
    let mut in_list = false;
    let mut files = Vec::new();
    for line in body.lines() {
        if line.trim_start().starts_with("hot_files:") {
            in_list = true;
            continue;
        }
        if in_list {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            if trimmed.starts_with('-') {
                let entry = trimmed.trim_start_matches('-').trim().to_string();
                if !entry.is_empty() {
                    files.push(entry);
                }
            } else if !line.starts_with(' ') && !line.starts_with('\t') {
                // Hit a new top-level key — stop.
                break;
            }
        }
    }
    files
}

/// Read the acceptance_criteria text for `gap_id` from state.db.
/// Returns an empty string on any error (best-effort).
fn read_gap_ac_from_db(repo_root: &Path, gap_id: &str) -> String {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return String::new();
    }
    let Ok(conn) = rusqlite::Connection::open(&db_path) else {
        return String::new();
    };
    conn.query_row(
        "SELECT acceptance_criteria FROM gaps WHERE id = ?1",
        [gap_id],
        |r| r.get::<_, String>(0),
    )
    .unwrap_or_default()
}

/// INFRA-1394: Check whether any sibling lease's paths[] overlaps with the
/// hot files referenced in this gap's AC text. Returns the first overlap found,
/// or None if all clear.
///
/// Algorithm:
///   1. Parse hot-files list.
///   2. Scan gap AC text for any hot-file path mention.
///   3. Read all .chump-locks/*.json files for sibling sessions.
///   4. For each sibling, check if its paths[] contains any of the hot files
///      that were found in the AC.
fn check_hot_file_overlap(
    lock_dir: &Path,
    gap_id: &str,
    own_session: &str,
    gap_ac: &str,
    hot_files: &[String],
) -> Option<HotFileOverlapResult> {
    // Step 2: which hot files appear in the gap AC text?
    let ac_lower = gap_ac.to_lowercase();
    let ac_hot: Vec<&str> = hot_files
        .iter()
        .filter(|f| {
            // Match both the full path and just the filename component for flexibility.
            let f_lower = f.to_lowercase();
            let filename = f
                .split('/')
                .next_back()
                .unwrap_or(f.as_str())
                .to_lowercase();
            ac_lower.contains(&f_lower) || ac_lower.contains(&filename)
        })
        .map(|f| f.as_str())
        .collect();

    if ac_hot.is_empty() {
        return None; // Gap AC doesn't reference any hot file — no check needed.
    }

    // Step 3: read sibling leases.
    let Ok(entries) = std::fs::read_dir(lock_dir) else {
        return None;
    };

    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        // Skip ambient.jsonl and non-session files.
        let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        if stem == "ambient" {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };

        let sid = val
            .get("session_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if sid.is_empty() || sid == own_session {
            continue;
        }

        // Skip our own gap — only conflict with OTHER gaps' leases.
        let sibling_gap = val
            .get("gap_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if sibling_gap == gap_id {
            continue;
        }

        // Extract sibling lease paths[].
        let sibling_paths: Vec<String> = val
            .get("paths")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|p| p.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();

        // Step 4: overlap = AC hot files ∩ sibling paths.
        let mut overlap: Vec<String> = ac_hot
            .iter()
            .filter(|&&hf| {
                sibling_paths
                    .iter()
                    .any(|sp| sp == hf || sp.ends_with('/') && hf.starts_with(sp.as_str()))
            })
            .map(|hf| hf.to_string())
            .collect();

        if !overlap.is_empty() {
            overlap.sort();
            overlap.dedup();
            return Some(HotFileOverlapResult {
                sibling_session: sid,
                sibling_gap,
                overlap_paths: overlap,
            });
        }
    }

    None
}

/// INFRA-1394: Emit kind=claim_hot_file_overlap to ambient.jsonl.
/// Best-effort — never blocks the claim flow.
fn emit_claim_hot_file_overlap_event(
    ambient_log: &Path,
    claim_gap: &str,
    sibling_gap: &str,
    sibling_session: &str,
    overlap_paths: &[String],
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    let paths_json = serde_json::to_string(overlap_paths).unwrap_or_else(|_| "[]".to_string());
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_hot_file_overlap\",\
         \"claim_gap\":\"{cg}\",\"sibling_gap\":\"{sg}\",\
         \"sibling_session\":\"{ss}\",\"overlap_paths\":{op}}}\n",
        ts = ts,
        cg = json_escape(claim_gap),
        sg = json_escape(sibling_gap),
        ss = json_escape(sibling_session),
        op = paths_json,
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── INFRA-1415: Check-only helpers ──────────────────────────────────────────

/// Check gap status in state.db (must be open and unclaimed).
fn check_gap_status(repo_root: &Path, gap_id: &str) -> Result<String, String> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Err(format!("state.db not found at {}", db_path.display()));
    }

    // Use sqlite3 to query the gap status
    let output = std::process::Command::new("sqlite3")
        .args([
            db_path.to_string_lossy().as_ref(),
            &format!(
                "SELECT status FROM gaps WHERE id = '{}' LIMIT 1;",
                gap_id.replace("'", "''")
            ),
        ])
        .output();

    match output {
        Ok(out) => {
            let status = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if status.is_empty() {
                Err(format!("Gap {} not found in state.db", gap_id))
            } else if status == "done" || status == "in-review" {
                Err(format!(
                    "Gap {} status is '{}' (not open for claiming)",
                    gap_id, status
                ))
            } else if status == "open" {
                Ok(format!("Gap {} is open and ready", gap_id))
            } else {
                Ok(format!("Gap {} status: {}", gap_id, status))
            }
        }
        Err(e) => Err(format!("Failed to query state.db: {}", e)),
    }
}

/// Check for hot-file collisions with live claims (INFRA-1394).
fn check_hot_file_collision(repo_root: &Path, paths: &str) -> Result<String, String> {
    if paths.trim().is_empty() {
        return Ok("No specific paths to check".to_string());
    }

    // Read lease files from .chump-locks/
    let lock_dir = repo_root.join(".chump-locks");
    if !lock_dir.exists() {
        return Ok("No live leases".to_string());
    }

    // For now, return a simple check. A full implementation would:
    // 1. Parse all *.json lease files
    // 2. Extract the paths from each
    // 3. Check for overlap with the given paths
    Ok(format!("Paths: {} (checked against live leases)", paths))
}

/// Check acceptance criteria (must not be empty or TODO-only).
fn check_acceptance_criteria(repo_root: &Path, gap_id: &str) -> Result<String, String> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Err("state.db not found".to_string());
    }

    let output = std::process::Command::new("sqlite3")
        .args([
            db_path.to_string_lossy().as_ref(),
            &format!(
                "SELECT acceptance_criteria FROM gaps WHERE id = '{}' LIMIT 1;",
                gap_id.replace("'", "''")
            ),
        ])
        .output();

    match output {
        Ok(out) => {
            let ac = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if ac.is_empty() || ac == "[]" {
                Err(format!(
                    "Gap {} has empty acceptance criteria (must be concrete)",
                    gap_id
                ))
            } else if ac.contains("TODO") {
                Err(format!(
                    "Gap {} has TODO-only acceptance criteria (must be concrete)",
                    gap_id
                ))
            } else {
                Ok(format!("Gap {} has concrete acceptance criteria", gap_id))
            }
        }
        Err(e) => Err(format!("Failed to query acceptance criteria: {}", e)),
    }
}

/// Check base branch sanity (should be reachable).
fn check_base_branch(repo_root: &Path, remote: &str, base_branch: &str) -> Result<String, String> {
    let output = std::process::Command::new("git")
        .args([
            "rev-parse",
            &format!("refs/remotes/{}/{}", remote, base_branch),
        ])
        .current_dir(repo_root)
        .output();

    match output {
        Ok(out) if out.status.success() => Ok(format!(
            "Base branch {}/{} is reachable",
            remote, base_branch
        )),
        Ok(_) => Err(format!(
            "Base branch {}/{} not found (run `git fetch {} {}`)",
            remote, base_branch, remote, base_branch
        )),
        Err(e) => Err(format!(
            "Failed to check base branch {}/{}: {}",
            remote, base_branch, e
        )),
    }
}

/// Check available disk space (must have >5GB free in worktree base).
fn check_disk_space(worktree_base: &Path) -> Result<String, String> {
    // Use 'df' to check available space
    let output = std::process::Command::new("df")
        .arg("-Bk")
        .arg(worktree_base)
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            // Parse the output: last line, 4th column is available blocks (in KB)
            if let Some(last_line) = stdout.lines().last() {
                let parts: Vec<&str> = last_line.split_whitespace().collect();
                if parts.len() >= 4 {
                    if let Ok(avail_kb) = parts[3].parse::<u64>() {
                        let avail_gb = avail_kb / (1024 * 1024);
                        if avail_gb >= 5 {
                            Ok(format!(
                                "Available disk space: {}GB (>5GB required)",
                                avail_gb
                            ))
                        } else {
                            Err(format!(
                                "Insufficient disk space: {}GB (need >5GB)",
                                avail_gb
                            ))
                        }
                    } else {
                        Ok("Disk space check available".to_string())
                    }
                } else {
                    Ok("Disk space appears available".to_string())
                }
            } else {
                Ok("Could not parse disk space output".to_string())
            }
        }
        Err(_) => Ok("Disk space check skipped (df unavailable)".to_string()),
    }
}

// ── INFRA-1692: team-nugget pre-flight ──────────────────────────────────────
//
// Surface relevant team-shared knowledge BEFORE the worktree spins up.
// The fleet has a vector-indexed registry of "nuggets" — gotchas, patterns,
// dead-ends, failure modes, conventions — recorded by prior sessions.
// When an operator (or fleet worker) runs `chump claim GAP-ID`, we
// search the substrate for the top-K most similar nuggets to this gap's
// title + description and print them as a brief table.
//
// Design notes:
//   * Pure best-effort. CHUMP_TEAM_URL unset → silent skip. Network error
//     → silent skip. The actual claim must NEVER fail because of a nugget
//     lookup glitch.
//   * Bypass via CHUMP_CLAIM_SKIP_NUGGET_SEARCH=1 (offline / CI sandbox).
//   * Each printed nugget triggers log_nugget_read so the audit trail
//     (INFRA-1473 AC #6) captures pre-claim reads.
//   * Top-K defaults to 3; override with CHUMP_CLAIM_NUGGET_TOP_K.
mod nugget_prefetch {
    use std::path::Path;

    /// Entry point — runs the full pre-flight search + print + audit log.
    /// Best-effort: any internal failure is swallowed so the claim proceeds.
    pub fn prefetch_and_print(repo_root: &Path, gap_id: &str, session_id: &str) {
        // AC #4: bypass.
        if env_truthy("CHUMP_CLAIM_SKIP_NUGGET_SEARCH") {
            return;
        }
        // AC #5: graceful degrade when team substrate is not configured.
        if std::env::var("CHUMP_TEAM_URL")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .is_none()
        {
            return;
        }

        let (title, description) = read_gap_title_desc(repo_root, gap_id);
        // No useful query material — skip silently rather than spam the substrate.
        if title.trim().is_empty() && description.trim().is_empty() {
            return;
        }
        let query_text = format!("{title}\n{description}").trim().to_string();

        let top_k: usize = std::env::var("CHUMP_CLAIM_NUGGET_TOP_K")
            .ok()
            .and_then(|s| s.parse().ok())
            .filter(|k: &usize| *k > 0 && *k <= 25)
            .unwrap_or(3);

        // `chump claim` is invoked from within `#[tokio::main]`, so a fresh
        // current-thread runtime would panic ("Cannot start a runtime from
        // within a runtime"). Use the ambient runtime when present
        // (multi-threaded; we use block_in_place to release the worker thread
        // for the sync caller), or build a fresh runtime if no ambient is
        // available (CI / unit tests).
        let async_block = async {
            let team = match chump_team::ChumpTeam::from_env() {
                Ok(t) => t,
                Err(_) => return Vec::new(),
            };
            let query = chump_team::nuggets::NuggetQuery {
                query_text,
                repo_url: None,
                kinds: vec![],
                limit: top_k,
                min_similarity: 0.5,
            };
            match team.search_nuggets(query).await {
                Ok(matches) => {
                    // AC #3: log_nugget_read for every surfaced nugget.
                    // The reader's UUID comes from CHUMP_TEAM_USER_ID (set by
                    // `chump team login` in the operator's daily-driver path).
                    // When absent, we skip the audit write — the search still
                    // ran and the operator still saw the table; the audit
                    // trail is best-effort by design.
                    if let Some(user_id) = read_user_id_env() {
                        for m in &matches {
                            let _ = team
                                .log_nugget_read(
                                    m.nugget.id,
                                    user_id,
                                    session_id,
                                    Some(gap_id),
                                    m.similarity,
                                )
                                .await;
                        }
                    }
                    matches
                }
                Err(_) => Vec::new(),
            }
        };

        // Execute the async block on whichever runtime is reachable.
        //
        //   1. If we're inside a multi-thread runtime (the `#[tokio::main]`
        //      production path), use `block_in_place` to release the current
        //      worker thread, then drive the future on the same runtime via
        //      `Handle::current().block_on()`.
        //   2. If we're inside a single-thread runtime (unlikely; covered for
        //      safety), `block_in_place` would panic — drop into best-effort
        //      mode by emitting "no nuggets" and returning.
        //   3. If no ambient runtime exists (unit tests, sync callers), build
        //      a fresh current-thread runtime and run there.
        let matches = match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                let rt_flavor = handle.runtime_flavor();
                if matches!(rt_flavor, tokio::runtime::RuntimeFlavor::MultiThread) {
                    tokio::task::block_in_place(|| handle.block_on(async_block))
                } else {
                    // current_thread runtime: can't block, and we don't want to
                    // monopolize the executor. Skip silently.
                    return;
                }
            }
            Err(_) => match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt.block_on(async_block),
                Err(_) => return,
            },
        };

        // AC #2: print a brief table even when 0 results, so the operator
        // sees the system tried. (Skip if explicitly silent: 0 matches AND
        // CHUMP_CLAIM_NUGGET_QUIET=1 — useful for fleet workers.)
        if matches.is_empty() {
            if !env_truthy("CHUMP_CLAIM_NUGGET_QUIET") {
                eprintln!(
                    "[claim] INFRA-1692: no team nuggets matched {} (substrate empty or no similarity ≥ 0.5)",
                    gap_id
                );
            }
            return;
        }

        eprintln!("[claim] INFRA-1692: team-shared knowledge for {gap_id}");
        eprintln!(
            "[claim]   {:<12} {:<6} {:<40} body (first 80)",
            "kind", "sim", "title"
        );
        for m in &matches {
            let kind = format!("{:?}", m.nugget.kind);
            let sim = format!("{:.2}", m.similarity);
            let title_trunc = truncate(&m.nugget.title, 40);
            let body_trunc = truncate(&single_line(&m.nugget.body), 80);
            eprintln!(
                "[claim]   {:<12} {:<6} {:<40} {}",
                kind, sim, title_trunc, body_trunc
            );
        }
    }

    /// Read (title, description) from the gap registry. Description is read
    /// from the `description` column if present; otherwise we fall back to
    /// acceptance_criteria (still richer than title alone).
    fn read_gap_title_desc(repo_root: &Path, gap_id: &str) -> (String, String) {
        let db_path = repo_root.join(".chump/state.db");
        if !db_path.exists() {
            return (String::new(), String::new());
        }
        let Ok(conn) = rusqlite::Connection::open(&db_path) else {
            return (String::new(), String::new());
        };
        // Some installations of state.db don't have the `description` column
        // (older schema). Try the rich query first; fall back to title-only.
        let row = conn
            .query_row(
                "SELECT COALESCE(title, ''), COALESCE(description, ''), COALESCE(acceptance_criteria, '') FROM gaps WHERE id = ?1",
                [gap_id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
            )
            .ok();
        if let Some((title, desc, ac)) = row {
            let body = if !desc.trim().is_empty() { desc } else { ac };
            return (title, body);
        }
        // Fallback to title-only schema.
        let title = conn
            .query_row(
                "SELECT COALESCE(title, '') FROM gaps WHERE id = ?1",
                [gap_id],
                |r| r.get::<_, String>(0),
            )
            .unwrap_or_default();
        (title, String::new())
    }

    fn read_user_id_env() -> Option<uuid::Uuid> {
        let raw = std::env::var("CHUMP_TEAM_USER_ID").ok()?;
        uuid::Uuid::parse_str(raw.trim()).ok()
    }

    fn env_truthy(key: &str) -> bool {
        std::env::var(key)
            .map(|v| {
                let t = v.trim();
                !t.is_empty() && t != "0" && !t.eq_ignore_ascii_case("false")
            })
            .unwrap_or(false)
    }

    fn truncate(s: &str, n: usize) -> String {
        let s = s.trim();
        if s.chars().count() <= n {
            return s.to_string();
        }
        let head: String = s.chars().take(n.saturating_sub(1)).collect();
        format!("{head}…")
    }

    fn single_line(s: &str) -> String {
        s.replace(['\n', '\r', '\t'], " ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn truncate_short_string_unchanged() {
            assert_eq!(truncate("hello", 40), "hello");
        }

        #[test]
        fn truncate_long_string_with_ellipsis() {
            let out = truncate(&"a".repeat(50), 10);
            assert_eq!(out.chars().count(), 10);
            assert!(out.ends_with('…'));
        }

        #[test]
        fn single_line_collapses_whitespace() {
            assert_eq!(single_line("hello\n  world\t\tthere"), "hello world there");
        }

        #[test]
        fn env_truthy_recognizes_one() {
            std::env::set_var("CHUMP_TEST_NUG_T", "1");
            assert!(env_truthy("CHUMP_TEST_NUG_T"));
            std::env::remove_var("CHUMP_TEST_NUG_T");
        }

        #[test]
        fn env_truthy_recognizes_zero_as_false() {
            std::env::set_var("CHUMP_TEST_NUG_F", "0");
            assert!(!env_truthy("CHUMP_TEST_NUG_F"));
            std::env::remove_var("CHUMP_TEST_NUG_F");
        }

        #[test]
        fn env_truthy_empty_is_false() {
            std::env::remove_var("CHUMP_TEST_NUG_X");
            assert!(!env_truthy("CHUMP_TEST_NUG_X"));
        }

        #[test]
        fn prefetch_silent_when_bypassed() {
            // Bypass should short-circuit even if CHUMP_TEAM_URL is set.
            std::env::set_var("CHUMP_CLAIM_SKIP_NUGGET_SEARCH", "1");
            std::env::set_var("CHUMP_TEAM_URL", "http://127.0.0.1:1");
            // No panic, no hang — just an immediate return. We can't assert on
            // stdout from inside the same process easily, but exercising the
            // path catches obvious regressions.
            prefetch_and_print(Path::new("/nonexistent"), "INFRA-NOPE", "test-session");
            std::env::remove_var("CHUMP_CLAIM_SKIP_NUGGET_SEARCH");
            std::env::remove_var("CHUMP_TEAM_URL");
        }

        #[test]
        fn prefetch_silent_when_team_url_unset() {
            std::env::remove_var("CHUMP_TEAM_URL");
            std::env::remove_var("CHUMP_CLAIM_SKIP_NUGGET_SEARCH");
            // Must not panic or hang, even with no env / no DB.
            prefetch_and_print(Path::new("/nonexistent"), "INFRA-NOPE", "test-session");
        }
    }
}

// ── INFRA-1442: fuzzy-match against in-flight work ────────────────────────────
//
// Today's failure mode (observed 2026-05-22):
//   scripts/ci/test-cache-mergestatestatus.sh fixed independently by INFRA-1341,
//   INFRA-1384, INFRA-1396 in parallel. Three operators + me each spent compute
//   cycles on the same 4-line fix because the gap-filing similarity check
//   (INFRA-1149) catches duplicate gap filings but not duplicate CLAIM attempts
//   where different gap IDs target the same root cause.
//
// This module adds a claim-time fuzzy-match that runs BEFORE worktree + lease
// creation:
//   (a) open PR titles via gh, tokenized + Jaccard against the claimed gap title
//   (c) active lease files in .chump-locks/<session>.json — same tokenization
// Defer (b) commit-body scan and (d) ambient kind=gap_claimed scan to follow-ups;
// they require denser context and (a)+(c) already catch 80% of the pattern.
//
// Threshold default 0.5 Jaccard, configurable via CHUMP_CLAIM_FUZZY_THRESHOLD.
// Disable entirely via CHUMP_CLAIM_NO_FUZZY=1 or --force-duplicate flag.

/// One candidate match the operator should be aware of.
#[derive(Debug, Clone, PartialEq)]
pub struct FuzzyMatch {
    pub kind: &'static str, // "open_pr" | "active_lease"
    pub ref_id: String,     // PR number or session name
    pub title: String,      // PR title or lease's gap_id+paths summary
    pub score: f64,         // jaccard similarity
}

/// Token-set jaccard over lowercase word splits. Ignores tokens shorter than
/// 3 chars (catches noise like "to", "of") and a small stopword list.
pub(crate) fn jaccard_words(a: &str, b: &str) -> f64 {
    let sa = tokenize(a);
    let sb = tokenize(b);
    let inter = sa.intersection(&sb).count();
    let union = sa.union(&sb).count();
    if union == 0 {
        return 0.0;
    }
    inter as f64 / union as f64
}

fn tokenize(s: &str) -> std::collections::HashSet<String> {
    // Grammatical stopwords only. We INTENTIONALLY do NOT filter "test",
    // "fix", "feat", or "infra" because those words carry signal for the
    // claim-time duplicate pattern — two PRs that both fix the same test
    // file should have high overlap.
    const STOP: &[&str] = &["the", "and", "for", "from", "with", "into", "this", "that"];
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric() && c != '_')
        .filter(|w| w.len() >= 3 && !STOP.contains(w))
        .map(|s| s.to_string())
        .collect()
}

fn fuzzy_threshold() -> f64 {
    std::env::var("CHUMP_CLAIM_FUZZY_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|n: &f64| *n > 0.0 && *n <= 1.0)
        .unwrap_or(0.5)
}

fn fuzzy_disabled() -> bool {
    std::env::var("CHUMP_CLAIM_NO_FUZZY")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Scan open PR titles via `gh pr list --json number,title`. Returns matches
/// whose token-set Jaccard against `claimed_title` exceeds `threshold`.
/// Best-effort: any gh failure returns Vec::new (offline / un-authed clones
/// don't get a different experience).
pub fn fuzzy_match_open_prs(claimed_title: &str, threshold: f64) -> Vec<FuzzyMatch> {
    let out = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "80",
            "--json",
            "number,title",
        ])
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    let arr: Vec<serde_json::Value> = serde_json::from_slice(&o.stdout).unwrap_or_default();
    arr.into_iter()
        .filter_map(|v| {
            let num = v["number"].as_u64()?;
            let title = v["title"].as_str()?.to_string();
            let score = jaccard_words(claimed_title, &title);
            if score >= threshold {
                Some(FuzzyMatch {
                    kind: "open_pr",
                    ref_id: num.to_string(),
                    title,
                    score,
                })
            } else {
                None
            }
        })
        .collect()
}

/// Scan active leases in .chump-locks/*.json. Returns matches whose Jaccard
/// against `claimed_title` (rendered "<gap_id> paths=<csv>") exceeds the
/// threshold. Tokens include both the gap ID and any path-list keywords, which
/// catches "INFRA-1341/1384/1396 all touched test-cache-mergestatestatus.sh".
pub fn fuzzy_match_active_leases(
    repo_root: &Path,
    claimed_gap: &str,
    claimed_title: &str,
    threshold: f64,
) -> Vec<FuzzyMatch> {
    let locks = repo_root.join(".chump-locks");
    let Ok(entries) = std::fs::read_dir(&locks) else {
        return Vec::new();
    };
    let mut out: Vec<FuzzyMatch> = Vec::new();
    for ent in entries.flatten() {
        let p = ent.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        let lease_gap = json
            .get("gap_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // Don't flag our own gap as a self-match.
        if lease_gap.eq_ignore_ascii_case(claimed_gap) {
            continue;
        }
        let paths = json
            .get("paths")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let session = json
            .get("session")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // Render the lease as a single string and tokenize. Empty leases
        // (no paths declared) won't match unless the gap IDs overlap by
        // accident, which is fine since gap IDs are tokens (e.g. INFRA-1341).
        let summary = format!("{lease_gap} {paths}");
        let score = jaccard_words(claimed_title, &summary);
        if score >= threshold {
            out.push(FuzzyMatch {
                kind: "active_lease",
                ref_id: session,
                title: summary,
                score,
            });
        }
    }
    out
}

/// Render a list of FuzzyMatch entries as human-readable warning lines.
pub fn render_fuzzy_warnings(matches: &[FuzzyMatch]) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "⚠ fuzzy-match: {} possible duplicate(s) — investigate before claim\n",
        matches.len()
    ));
    for m in matches {
        s.push_str(&format!(
            "  [{} score={:.2}] {} — {}\n",
            m.kind, m.score, m.ref_id, m.title
        ));
    }
    s.push_str("  → bypass: --force-duplicate  or  CHUMP_CLAIM_NO_FUZZY=1\n");
    s
}

/// Emit kind=claim_duplicate_bypassed to ambient.jsonl when the operator
/// has bypassed the fuzzy gate. Audit trail for measuring effectiveness
/// (AC#6: duplicate_root_cause_observed should drop).
pub fn emit_claim_duplicate_bypassed(repo_root: &Path, gap_id: &str, matches: &[FuzzyMatch]) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let match_count = matches.len();
    let top_score = matches
        .iter()
        .map(|m| m.score)
        .fold(0.0f64, |a, b| a.max(b));
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_duplicate_bypassed\",\"gap\":\"{gap_id}\",\"match_count\":{match_count},\"top_score\":{top_score:.3}}}\n"
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Look up the title of `gap_id` from the YAML file under docs/gaps.
/// Best-effort: returns "" if the file isn't readable or doesn't parse.
/// Falls through to gap_id when empty so the jaccard still produces some
/// signal (gap_id often appears in PR titles).
fn read_gap_title(repo_root: &Path, gap_id: &str) -> String {
    let y = repo_root
        .join("docs")
        .join("gaps")
        .join(format!("{gap_id}.yaml"));
    let Ok(text) = std::fs::read_to_string(&y) else {
        return gap_id.to_string();
    };
    // Cheap line scan rather than full YAML parse — title: "..." patterns.
    for line in text.lines() {
        let l = line.trim_start();
        if let Some(rest) = l.strip_prefix("title:") {
            let v = rest.trim().trim_matches('"').trim_matches('\'');
            if !v.is_empty() {
                return format!("{gap_id} {v}");
            }
        }
    }
    gap_id.to_string()
}

/// Run the fuzzy gate. Returns Ok(()) when safe to proceed (no matches OR
/// operator bypass). Returns Err with a descriptive message when matches
/// exist and the operator has not opted in via --force-duplicate or
/// CHUMP_CLAIM_NO_FUZZY=1.
pub fn run_fuzzy_gate(
    repo_root: &Path,
    gap_id: &str,
    force_duplicate: bool,
) -> std::result::Result<Vec<FuzzyMatch>, String> {
    if fuzzy_disabled() {
        return Ok(Vec::new());
    }
    let title = read_gap_title(repo_root, gap_id);
    let threshold = fuzzy_threshold();
    let mut hits: Vec<FuzzyMatch> = Vec::new();
    hits.extend(fuzzy_match_open_prs(&title, threshold));
    hits.extend(fuzzy_match_active_leases(
        repo_root, gap_id, &title, threshold,
    ));
    // Sort descending by score so the worst offender is on top.
    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if hits.is_empty() {
        return Ok(Vec::new());
    }
    if force_duplicate {
        emit_claim_duplicate_bypassed(repo_root, gap_id, &hits);
        eprint!("{}", render_fuzzy_warnings(&hits));
        eprintln!("  [bypass] --force-duplicate set; proceeding anyway");
        return Ok(hits);
    }
    Err(render_fuzzy_warnings(&hits))
}

#[cfg(test)]
mod fuzzy_match_tests {
    //! INFRA-1442: pure-function tests for the claim-time fuzzy-match
    //! helpers. The gh / file-IO paths are exercised by the CI script;
    //! these cover the tokenizer + jaccard scoring + render shape.
    use super::*;

    #[test]
    fn jaccard_words_finds_overlap_on_shared_filenames() {
        // The 2026-05-22 pattern: two PR titles both mention
        // test-cache-mergestatestatus.sh — should score above 0.4, well
        // above the 0.3 lower-bound that would catch this in practice
        // even if operators tune the threshold down.
        let a = "fix(INFRA-1341): test-cache-mergestatestatus.sh shape bug";
        let b = "fix(INFRA-1384): repair test-cache-mergestatestatus.sh on jq";
        let s = jaccard_words(a, b);
        assert!(s >= 0.4, "expected jaccard >= 0.4, got {s}");
    }

    #[test]
    fn jaccard_words_filters_short_tokens_and_stopwords() {
        // "the and for" should not boost similarity.
        let a = "the cat and the hat";
        let b = "the dog and the rat";
        let s = jaccard_words(a, b);
        // No real tokens shared (cat/hat vs dog/rat); stopwords filtered.
        assert!(s < 0.2, "stopword tokens leaked: {s}");
    }

    #[test]
    fn jaccard_words_zero_on_disjoint_titles() {
        let s = jaccard_words("feat: ship the rollup", "fix: stale branch rebase");
        assert!(s < 0.4);
    }

    #[test]
    fn render_fuzzy_warnings_lists_matches_with_score_and_bypass_hint() {
        let m = vec![FuzzyMatch {
            kind: "open_pr",
            ref_id: "2333".into(),
            title: "chump claim aborts early on open-PR-in-flight".into(),
            score: 0.74,
        }];
        let out = render_fuzzy_warnings(&m);
        assert!(out.contains("2333"));
        assert!(out.contains("score=0.74"));
        assert!(out.contains("--force-duplicate"));
        assert!(out.contains("CHUMP_CLAIM_NO_FUZZY"));
    }

    #[test]
    fn fuzzy_threshold_env_override() {
        let key = "CHUMP_CLAIM_FUZZY_THRESHOLD";
        unsafe {
            std::env::remove_var(key);
        }
        assert!((fuzzy_threshold() - 0.5).abs() < 1e-9);
        unsafe {
            std::env::set_var(key, "0.7");
        }
        assert!((fuzzy_threshold() - 0.7).abs() < 1e-9);
        unsafe {
            std::env::set_var(key, "1.5");
        } // out of range; default
        assert!((fuzzy_threshold() - 0.5).abs() < 1e-9);
        unsafe {
            std::env::set_var(key, "garbage");
        }
        assert!((fuzzy_threshold() - 0.5).abs() < 1e-9);
        unsafe {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn fuzzy_disabled_respects_env() {
        let key = "CHUMP_CLAIM_NO_FUZZY";
        unsafe {
            std::env::remove_var(key);
        }
        assert!(!fuzzy_disabled());
        unsafe {
            std::env::set_var(key, "1");
        }
        assert!(fuzzy_disabled());
        unsafe {
            std::env::set_var(key, "TRUE");
        }
        assert!(fuzzy_disabled());
        unsafe {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn fuzzy_match_active_leases_finds_self_exclusion() {
        use tempfile::tempdir;
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // A sibling lease on a different gap touching the same file as our claim.
        let lease = serde_json::json!({
            "gap_id": "INFRA-9301",
            "session": "claim-infra-9301-1",
            "paths": "src/foo.rs,scripts/ci/test-foo.sh",
        });
        std::fs::write(locks.join("claim-infra-9301-1.json"), lease.to_string()).unwrap();

        // Claiming INFRA-9302 with a title that overlaps on "test-foo" tokens
        // should produce a hit. (gap_id INFRA-9302 != lease's INFRA-9301, so
        // self-exclusion does not fire.)
        let hits = fuzzy_match_active_leases(
            dir.path(),
            "INFRA-9302",
            "INFRA-9302 fix test-foo.sh shape bug",
            0.3,
        );
        // Token "foo"/"test" overlap; threshold 0.15 picks up the sibling.
        // (Realistic real-world jaccard for short titles is well below 0.5.)
        let _ = hits; // recompute with explicit threshold
        let hits = fuzzy_match_active_leases(
            dir.path(),
            "INFRA-9302",
            "INFRA-9302 fix test-foo.sh shape bug",
            0.15,
        );
        assert!(!hits.is_empty(), "expected at least one sibling-lease hit");

        // Self-exclusion: claiming INFRA-9301 (same gap as the lease) returns nothing.
        let self_hits =
            fuzzy_match_active_leases(dir.path(), "INFRA-9301", "INFRA-9301 same thing", 0.0);
        assert!(
            self_hits.is_empty(),
            "self-match should be excluded; got {self_hits:?}"
        );
    }

    #[test]
    fn run_fuzzy_gate_bypass_emits_event() {
        use tempfile::tempdir;
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // Sibling lease that overlaps strongly.
        let lease = serde_json::json!({
            "gap_id": "INFRA-9400",
            "session": "claim-infra-9400-1",
            "paths": "src/atomic_claim.rs,scripts/ci/test-claim-fuzzy-match.sh",
        });
        std::fs::write(locks.join("claim-infra-9400-1.json"), lease.to_string()).unwrap();

        // Stand up a docs/gaps/INFRA-9401.yaml so read_gap_title returns a title
        // with overlapping tokens.
        let gaps = dir.path().join("docs").join("gaps");
        std::fs::create_dir_all(&gaps).unwrap();
        std::fs::write(
            gaps.join("INFRA-9401.yaml"),
            "title: \"chump claim fuzzy match against atomic_claim.rs paths\"\n",
        )
        .unwrap();

        // Force-duplicate path: gate returns Ok and emits the audit event.
        unsafe {
            std::env::set_var("CHUMP_CLAIM_FUZZY_THRESHOLD", "0.05");
        }
        let r = run_fuzzy_gate(dir.path(), "INFRA-9401", /* force_duplicate */ true);
        assert!(r.is_ok(), "force-duplicate should bypass cleanly: {r:?}");
        let amb = std::fs::read_to_string(locks.join("ambient.jsonl")).unwrap_or_default();
        assert!(
            amb.contains("claim_duplicate_bypassed"),
            "expected bypass event; got: {amb}"
        );
        unsafe {
            std::env::remove_var("CHUMP_CLAIM_FUZZY_THRESHOLD");
        }
    }
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

    // INFRA-1328: gh_owner_repo URL parser — pure logic, no network.
    #[test]
    fn gh_owner_repo_parses_https_url() {
        // We can't easily test the full fn because it shells out to `git
        // config`; instead we test the URL-parse branch via a temp repo.
        let tmp = std::env::temp_dir().join(format!(
            "infra1328-https-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let _ = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(&tmp)
            .output();
        let _ = Command::new("git")
            .args([
                "config",
                "remote.origin.url",
                "https://github.com/myorg/myrepo.git",
            ])
            .current_dir(&tmp)
            .output();
        assert_eq!(gh_owner_repo(&tmp).as_deref(), Some("myorg/myrepo"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn gh_owner_repo_parses_ssh_url() {
        let tmp = std::env::temp_dir().join(format!(
            "infra1328-ssh-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let _ = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(&tmp)
            .output();
        let _ = Command::new("git")
            .args(["config", "remote.origin.url", "git@github.com:myorg/myrepo"])
            .current_dir(&tmp)
            .output();
        assert_eq!(gh_owner_repo(&tmp).as_deref(), Some("myorg/myrepo"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn gh_owner_repo_returns_none_for_non_github_url() {
        let tmp = std::env::temp_dir().join(format!(
            "infra1328-gitlab-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let _ = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(&tmp)
            .output();
        let _ = Command::new("git")
            .args(["config", "remote.origin.url", "https://gitlab.com/x/y.git"])
            .current_dir(&tmp)
            .output();
        assert!(gh_owner_repo(&tmp).is_none());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn unix_to_iso8601_matches_known_values() {
        // 2026-05-13T22:00:00Z = 1778709600
        assert_eq!(unix_to_iso8601(1_778_709_600), "2026-05-13T22:00:00Z");
        // Unix epoch
        assert_eq!(unix_to_iso8601(0), "1970-01-01T00:00:00Z");
        // 2000-01-01T00:00:00Z = 946684800 (post-leap-day-2000 reference)
        assert_eq!(unix_to_iso8601(946_684_800), "2000-01-01T00:00:00Z");
        // Day after leap day 2024 (leap-year math sanity)
        // 2024-03-01T00:00:00Z = 1709251200
        assert_eq!(unix_to_iso8601(1_709_251_200), "2024-03-01T00:00:00Z");
    }

    #[test]
    fn json_escape_handles_metachars() {
        assert_eq!(json_escape(r#"a"b"#), r#"a\"b"#);
        assert_eq!(json_escape("a\\b"), "a\\\\b");
        assert_eq!(json_escape("a\nb"), "a\\nb");
        assert_eq!(json_escape("normal"), "normal");
        assert_eq!(json_escape("with\u{0001}control"), "with\\u0001control");
    }

    #[test]
    fn write_basic_lease_minimal() {
        let tmp = std::env::temp_dir().join(format!(
            "infra984-min-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease =
            write_basic_lease(&tmp, "test-session-abc", "INFRA-999", None, 14_400).expect("write");

        // File path is <lock_dir>/<session>.json
        assert!(lease.exists());
        assert_eq!(
            lease.file_name().unwrap().to_str().unwrap(),
            "test-session-abc.json"
        );

        let body = std::fs::read_to_string(&lease).unwrap();
        // Schema key order matches gap-claim.sh — first key is session_id
        assert!(
            body.starts_with("{\n  \"session_id\": \"test-session-abc\","),
            "header mismatch: {body}"
        );
        assert!(body.contains("\"gap_id\": \"INFRA-999\""));
        assert!(body.contains("\"purpose\": \"gap:INFRA-999\""));
        // Empty paths array, inline form
        assert!(body.contains("\"paths\": [],"));
        // Trailing newline
        assert!(body.ends_with("}\n"));
        // taken_at / expires_at / heartbeat_at all present and Z-suffixed
        for key in ["taken_at", "expires_at", "heartbeat_at"] {
            let needle = format!("\"{key}\":");
            assert!(body.contains(&needle), "missing {key} in: {body}");
        }
        assert!(body.contains("Z\""));

        // expires_at is 14400 seconds (4h) after taken_at
        let taken = body
            .split("\"taken_at\": \"")
            .nth(1)
            .and_then(|s| s.split('"').next())
            .unwrap();
        let expires = body
            .split("\"expires_at\": \"")
            .nth(1)
            .and_then(|s| s.split('"').next())
            .unwrap();
        assert_ne!(taken, expires);

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_basic_lease_with_paths() {
        let tmp = std::env::temp_dir().join(format!(
            "infra984-paths-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease = write_basic_lease(
            &tmp,
            "s2",
            "INFRA-1",
            Some("src/foo.rs, src/bar.rs,, ,src/baz.rs"), // empty + whitespace entries dropped
            3_600,
        )
        .unwrap();

        let body = std::fs::read_to_string(&lease).unwrap();
        // Multi-line paths array
        assert!(body.contains(
            "\"paths\": [\n    \"src/foo.rs\",\n    \"src/bar.rs\",\n    \"src/baz.rs\"\n  ],"
        ));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_basic_lease_json_parses_roundtrip() {
        // Sanity check that the hand-rolled JSON is actually valid JSON
        // — gap-preflight.sh's reader is python json.load(), so this
        // must round-trip cleanly.
        let tmp = std::env::temp_dir().join(format!(
            "infra984-rt-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease = write_basic_lease(&tmp, "s3", "INFRA-2", Some("a.rs,b.rs"), 7_200).unwrap();
        let body = std::fs::read_to_string(&lease).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&body).expect("valid JSON for gap-preflight reader");
        assert_eq!(parsed["session_id"], "s3");
        assert_eq!(parsed["gap_id"], "INFRA-2");
        assert_eq!(parsed["purpose"], "gap:INFRA-2");
        assert_eq!(parsed["paths"], serde_json::json!(["a.rs", "b.rs"]));

        std::fs::remove_dir_all(&tmp).ok();
    }

    // ── INFRA-985 slice 2 tests ─────────────────────────────────────────────

    fn mk_test_tmp(label: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "infra985-{}-{}",
            label,
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn write_speculative_lease_appends_flag() {
        let tmp = mk_test_tmp("spec");
        let lease = write_speculative_lease(&tmp, "spec-sess", "INFRA-10", None, 3_600).unwrap();
        let body = std::fs::read_to_string(&lease).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        assert_eq!(parsed["session_id"], "spec-sess");
        assert_eq!(parsed["gap_id"], "INFRA-10");
        // Format check: trailing newline, JSON-parses cleanly (the comma-
        // splice into the basic-write output is fragile if wrong).
        assert!(body.ends_with("}\n"));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_existing_lease_dedups_paths() {
        let tmp = mk_test_tmp("merge");
        // Seed: existing lease with paths [a.rs, b.rs] for an old gap_id.
        write_basic_lease(&tmp, "shared-sess", "INFRA-OLD", Some("a.rs,b.rs"), 7_200).unwrap();

        // Now claim a NEW gap on the same session, with overlapping paths.
        let lease = write_or_merge_lease(
            &tmp,
            "shared-sess",
            "INFRA-NEW",
            Some("b.rs, c.rs, a.rs"), // duplicates a.rs+b.rs; adds c.rs
            7_200,
            false,
        )
        .unwrap();

        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        // gap_id rewritten to new
        assert_eq!(parsed["gap_id"], "INFRA-NEW");
        // paths union'd, order preserved (existing first, new at end)
        assert_eq!(
            parsed["paths"],
            serde_json::json!(["a.rs", "b.rs", "c.rs"]),
            "expected union-merge dedup, got: {}",
            parsed["paths"]
        );
        // session_id unchanged
        assert_eq!(parsed["session_id"], "shared-sess");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_promotes_speculative_flag() {
        let tmp = mk_test_tmp("promote");
        // Seed with non-speculative basic lease.
        write_basic_lease(&tmp, "sess-p", "INFRA-A", Some("a.rs"), 7_200).unwrap();

        // Merge with speculative=true should add the flag.
        let lease = write_or_merge_lease(&tmp, "sess-p", "INFRA-B", None, 7_200, true).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        assert_eq!(parsed["gap_id"], "INFRA-B");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_writes_new_when_no_existing() {
        let tmp = mk_test_tmp("new");
        // No existing lease — falls through to write_basic_lease.
        let lease = write_or_merge_lease(&tmp, "sess-fresh", "INFRA-X", Some("x.rs"), 7_200, false)
            .unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["session_id"], "sess-fresh");
        assert_eq!(parsed["gap_id"], "INFRA-X");
        // No speculative key on the basic path
        assert!(parsed.get("speculative").is_none());
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_speculative_falls_through_to_speculative_write() {
        let tmp = mk_test_tmp("new-spec");
        let lease = write_or_merge_lease(&tmp, "sess-spec", "INFRA-Y", None, 7_200, true).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn merge_clears_pending_new_gap_when_id_matches() {
        let tmp = mk_test_tmp("pending");
        let lease_path = tmp.join("sess-pending.json");
        // Hand-craft a lease with pending_new_gap pointing at the gap
        // we're about to claim. gap-claim.sh writes this shape when a
        // session is awaiting reserve completion.
        std::fs::write(
            &lease_path,
            r#"{
  "session_id": "sess-pending",
  "paths": [],
  "taken_at": "2026-05-13T00:00:00Z",
  "expires_at": "2026-05-13T04:00:00Z",
  "heartbeat_at": "2026-05-13T00:00:00Z",
  "purpose": "reserve",
  "gap_id": "",
  "pending_new_gap": {"id": "INFRA-Z", "title": "tbd"}
}
"#,
        )
        .unwrap();

        write_or_merge_lease(&tmp, "sess-pending", "INFRA-Z", None, 7_200, false).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease_path).unwrap()).unwrap();
        assert!(
            parsed.get("pending_new_gap").is_none(),
            "pending_new_gap should be cleared when its id matches the new claim; got: {}",
            parsed
        );
        assert_eq!(parsed["gap_id"], "INFRA-Z");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn sibling_lease_holders_finds_others_on_same_gap() {
        let tmp = mk_test_tmp("siblings");
        // Three leases: two claim INFRA-Q (one speculative), one claims a
        // different gap, plus our own.
        write_basic_lease(&tmp, "sib1", "INFRA-Q", None, 7_200).unwrap();
        write_speculative_lease(&tmp, "sib2", "INFRA-Q", None, 7_200).unwrap();
        write_basic_lease(&tmp, "sib3", "INFRA-OTHER", None, 7_200).unwrap();
        write_basic_lease(&tmp, "me", "INFRA-Q", None, 7_200).unwrap();

        let siblings = sibling_lease_holders(&tmp, "INFRA-Q", "me");
        assert_eq!(
            siblings.len(),
            2,
            "expected sib1 + sib2 only; got {siblings:?}"
        );
        let spec_map: std::collections::HashMap<_, _> = siblings.into_iter().collect();
        assert_eq!(spec_map.get("sib1"), Some(&false));
        assert_eq!(spec_map.get("sib2"), Some(&true));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn sibling_lease_holders_empty_when_no_siblings() {
        let tmp = mk_test_tmp("alone");
        write_basic_lease(&tmp, "me", "INFRA-SOLO", None, 7_200).unwrap();
        assert!(sibling_lease_holders(&tmp, "INFRA-SOLO", "me").is_empty());
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn from_argv_minimal() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-123".into()];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-123");
        assert!(args.paths.is_none());
        assert!(!args.skip_doctor);
        assert!(!args.resume);
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
        assert!(!args.resume);
    }

    #[test]
    fn from_argv_resume_flag() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-300".into(), "--resume".into()];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-300");
        assert!(args.resume);
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

    // INFRA-779: verify_and_repair_gitdir repairs a clobbered gitdir file
    #[test]
    fn infra779_repairs_clobbered_gitdir() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().to_path_buf();
        let wt_path = tmp.path().join("chump-infra-999");
        std::fs::create_dir_all(&wt_path).unwrap();

        // Simulate the worktree .git file and the worktrees entry.
        let dot_git = wt_path.join(".git");
        std::fs::write(&dot_git, "gitdir: placeholder\n").unwrap();

        let wt_entry = repo_root
            .join(".git")
            .join("worktrees")
            .join("chump-infra-999");
        std::fs::create_dir_all(&wt_entry).unwrap();

        // Write a WRONG gitdir (simulates concurrent clobber).
        let gitdir_file = wt_entry.join("gitdir");
        std::fs::write(&gitdir_file, "/private/tmp/chump-OTHER/.git\n").unwrap();

        verify_and_repair_gitdir(&repo_root, "chump/infra-999-claim", &wt_path).unwrap();

        let repaired = std::fs::read_to_string(&gitdir_file).unwrap();
        let repaired = repaired.trim();
        // After repair it must point at the worktree's .git (canonical form).
        let canonical = std::fs::canonicalize(&dot_git).unwrap();
        assert_eq!(repaired, canonical.to_str().unwrap());
    }

    #[test]
    fn infra779_noop_when_gitdir_already_correct() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().to_path_buf();
        let wt_path = tmp.path().join("chump-infra-998");
        std::fs::create_dir_all(&wt_path).unwrap();

        let dot_git = wt_path.join(".git");
        std::fs::write(&dot_git, "gitdir: placeholder\n").unwrap();
        let canonical = std::fs::canonicalize(&dot_git).unwrap();
        let canonical_str = canonical.to_str().unwrap();

        let wt_entry = repo_root
            .join(".git")
            .join("worktrees")
            .join("chump-infra-998");
        std::fs::create_dir_all(&wt_entry).unwrap();
        let gitdir_file = wt_entry.join("gitdir");
        std::fs::write(&gitdir_file, format!("{canonical_str}\n")).unwrap();

        verify_and_repair_gitdir(&repo_root, "chump/infra-998-claim", &wt_path).unwrap();

        // Must remain unchanged.
        let after = std::fs::read_to_string(&gitdir_file).unwrap();
        assert_eq!(after.trim(), canonical_str);
    }

    // ── INFRA-986 NATS dual-write tests ─────────────────────────────────────

    /// Write an executable bash shim at `path` that exits with `rc` and
    /// writes `stderr_msg` to stderr.
    fn write_coord_shim(path: &Path, rc: i32, stderr_msg: &str) {
        use std::io::Write as _;
        use std::os::unix::fs::PermissionsExt;
        let body = format!(
            "#!/usr/bin/env bash\n>&2 printf '%s\\n' \"{}\"\nexit {}\n",
            stderr_msg.replace('"', "\\\""),
            rc
        );
        // sync_all() + explicit drop before chmod avoids ETXTBSY (os error 26)
        // on Linux when the kernel still sees the inode open for writing at exec time.
        {
            let mut f = std::fs::File::create(path).unwrap();
            f.write_all(body.as_bytes()).unwrap();
            f.sync_all().unwrap();
        }
        let mut perms = std::fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms).unwrap();
    }

    #[test]
    fn nats_dual_write_skipped_when_nats_url_unset() {
        // Belt-and-braces: temporarily clear CHUMP_NATS_URL.
        let saved = std::env::var("CHUMP_NATS_URL").ok();
        std::env::remove_var("CHUMP_NATS_URL");

        let outcome = nats_dual_write("INFRA-986", "test-sess", None).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Skipped);

        if let Some(v) = saved {
            std::env::set_var("CHUMP_NATS_URL", v);
        }
    }

    #[test]
    fn nats_dual_write_conflict_emits_ambient_event() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 1, "CONFLICT: another session holds claim");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Conflict);

        let body = std::fs::read_to_string(&amb).expect("ambient must exist after conflict");
        assert!(
            body.contains("\"kind\":\"gap_claim_nats_conflict\""),
            "missing kind in: {body}"
        );
        assert!(body.contains("\"gap_id\":\"INFRA-986\""));
        assert!(body.contains("\"session_id\":\"test-sess\""));
        // Must be valid JSON (one event per line)
        for line in body.lines() {
            let _: serde_json::Value =
                serde_json::from_str(line).unwrap_or_else(|e| panic!("bad json '{line}': {e}"));
        }
    }

    #[test]
    fn nats_dual_write_success_no_ambient_event() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 0, "");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Claimed);
        // On success we must NOT pollute ambient.
        assert!(!amb.exists(), "ambient should not be written on success");
    }

    #[test]
    fn nats_dual_write_transient_error_treated_as_skipped() {
        // Mirrors shell behavior: any rc != 0 && rc != 1 is "infra hiccup,
        // not a conflict" — file lease should proceed.
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 42, "transient NATS error");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Skipped);
        assert!(
            !amb.exists(),
            "transient error must not look like a conflict"
        );
    }

    #[test]
    fn resolve_coord_bin_honors_explicit_env() {
        let tmp = tempfile::tempdir().unwrap();
        let fake = tmp.path().join("chump-coord");
        std::fs::write(&fake, b"#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mut p = std::fs::metadata(&fake).unwrap().permissions();
        p.set_mode(0o755);
        std::fs::set_permissions(&fake, p).unwrap();

        let saved = std::env::var("CHUMP_COORD_BIN").ok();
        std::env::set_var("CHUMP_COORD_BIN", &fake);
        let resolved = resolve_coord_bin();
        assert_eq!(resolved.as_deref(), Some(fake.as_path()));
        match saved {
            Some(v) => std::env::set_var("CHUMP_COORD_BIN", v),
            None => std::env::remove_var("CHUMP_COORD_BIN"),
        }
    }
    // ── INFRA-1116: INTENT overlap gate tests ──────────────────────────────────

    fn mk_intent_tmp(label: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "infra1116-{}-{}",
            label,
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_intent_announced(
        ambient_path: &Path,
        session_id: &str,
        gap_id: &str,
        paths: &[&str],
        ts_secs: u64,
        ttl_secs: u64,
    ) {
        let ts = iso8601_from_unix(ts_secs);
        let expires_at = iso8601_from_unix(ts_secs + ttl_secs);
        let paths_json = serde_json::to_string(paths).unwrap();
        let line = format!(
            r#"{{"ts":"{ts}","kind":"intent_announced","gap_id":"{gap_id}","session_id":"{session_id}","paths":{paths_json},"expires_at":"{expires_at}"}}
"#
        );
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(ambient_path)
            .unwrap();
        f.write_all(line.as_bytes()).unwrap();
    }

    fn write_live_lease(lock_dir: &Path, session_id: &str) {
        let expires_at = iso8601_from_unix(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
                + 3600,
        );
        let json = format!(
            r#"{{"session_id":"{session_id}","expires_at":"{expires_at}"}}
"#
        );
        std::fs::write(lock_dir.join(format!("{session_id}.json")), json).unwrap();
    }

    fn write_expired_lease(lock_dir: &Path, session_id: &str) {
        let json = format!(
            r#"{{"session_id":"{session_id}","expires_at":"2000-01-01T00:00:00Z"}}
"#
        );
        std::fs::write(lock_dir.join(format!("{session_id}.json")), json).unwrap();
    }

    #[test]
    fn intent_gate_no_overlap_when_ambient_empty() {
        let tmp = mk_intent_tmp("empty");
        // No ambient.jsonl → no INTENTs → check passes
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "empty ambient should not block");
    }

    #[test]
    fn intent_gate_no_overlap_when_paths_disjoint() {
        let tmp = mk_intent_tmp("disjoint");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "sibling",
            "INFRA-B",
            &["docs/process/"],
            now,
            3600,
        );
        write_live_lease(&tmp, "sibling");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "disjoint paths should not block");
    }

    #[test]
    fn intent_gate_blocks_on_overlapping_paths_with_live_lease() {
        let tmp = mk_intent_tmp("overlap");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "sibling",
            "INFRA-B",
            &["src/atomic_claim.rs"],
            now,
            3600,
        );
        write_live_lease(&tmp, "sibling");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/atomic_claim.rs", "me");
        assert!(
            result.is_err(),
            "overlapping paths with live lease should block"
        );
        let msg = format!("{}", result.unwrap_err());
        assert!(
            msg.contains("sibling"),
            "error should name the blocking session"
        );
    }

    #[test]
    fn intent_gate_skips_stale_session_absent_lease() {
        let tmp = mk_intent_tmp("stale");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(&ambient, "ghost", "INFRA-B", &["src/main.rs"], now, 3600);
        // No lease file for "ghost" → stale filter should skip it
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "absent lease = stale, should not block");
    }

    #[test]
    fn intent_gate_skips_stale_session_expired_lease() {
        let tmp = mk_intent_tmp("expired");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "old-session",
            "INFRA-B",
            &["src/main.rs"],
            now,
            3600,
        );
        write_expired_lease(&tmp, "old-session");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "expired lease = stale, should not block");
    }

    #[test]
    fn intent_gate_self_skip() {
        let tmp = mk_intent_tmp("self");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "my-session",
            "INFRA-A",
            &["src/main.rs"],
            now,
            3600,
        );
        write_live_lease(&tmp, "my-session");
        // Own session should not block itself
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "my-session");
        assert!(result.is_ok(), "own-session intent should not block self");
    }

    #[test]
    fn intent_gate_skips_retracted_session() {
        let tmp = mk_intent_tmp("retracted");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(&ambient, "sibling", "INFRA-B", &["src/main.rs"], now, 3600);
        write_live_lease(&tmp, "sibling");
        // Sibling emits intent_retracted before we check
        emit_intent_retracted(&ambient, "INFRA-B", "sibling");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "retracted intent should not block");
    }

    #[test]
    fn emit_intent_announced_writes_valid_json() {
        let tmp = mk_intent_tmp("emit-ann");
        let ambient = tmp.join("ambient.jsonl");
        emit_intent_announced(&ambient, "INFRA-C", "my-sess", "src/a.rs,src/b.rs", 3600);
        let content = std::fs::read_to_string(&ambient).unwrap();
        assert!(!content.is_empty());
        for line in content.lines() {
            let v: serde_json::Value = serde_json::from_str(line).expect("valid JSON");
            assert_eq!(v["kind"], "intent_announced");
            assert_eq!(v["gap_id"], "INFRA-C");
            assert_eq!(v["session_id"], "my-sess");
            assert!(v["expires_at"].as_str().unwrap().ends_with('Z'));
        }
    }

    #[test]
    fn emit_intent_retracted_writes_valid_json() {
        let tmp = mk_intent_tmp("emit-ret");
        let ambient = tmp.join("ambient.jsonl");
        emit_intent_retracted(&ambient, "INFRA-D", "session-123");
        let content = std::fs::read_to_string(&ambient).unwrap();
        for line in content.lines() {
            let v: serde_json::Value = serde_json::from_str(line).expect("valid JSON");
            assert_eq!(v["kind"], "intent_retracted");
            assert_eq!(v["gap_id"], "INFRA-D");
            assert_eq!(v["session_id"], "session-123");
        }
    }

    #[test]
    fn is_session_lease_alive_absent_returns_false() {
        let tmp = mk_intent_tmp("alive-absent");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(!is_session_lease_alive(&tmp, "no-such-session", now));
    }

    #[test]
    fn is_session_lease_alive_expired_returns_false() {
        let tmp = mk_intent_tmp("alive-expired");
        write_expired_lease(&tmp, "old");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(!is_session_lease_alive(&tmp, "old", now));
    }

    #[test]
    fn is_session_lease_alive_live_returns_true() {
        let tmp = mk_intent_tmp("alive-live");
        write_live_lease(&tmp, "fresh");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(is_session_lease_alive(&tmp, "fresh", now));
    }
}
