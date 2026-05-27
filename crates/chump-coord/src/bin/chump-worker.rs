//! `chump-worker` — Rust port of `scripts/dispatch/worker.sh` (INFRA-2002).
//!
//! META-107 sub-gap #6 of 6. Routed via `CHUMP_WORKER_RUST=1` from the
//! bash shim; the legacy 1807-LOC bash body stays in place for the
//! parallel-run window.
//!
//! ## CLI surface
//!
//! ```text
//! chump-worker [--once] [--idle-sleep-s SECS] [--session-id ID]
//! ```
//!
//! Env (all optional; defaults mirror worker.sh):
//!   WORKER_SKILLS=rust,shell        comma-separated capability tags
//!   WORKER_MACHINE=macbook          machine label
//!   WORKER_BACKEND=claude           backend identifier
//!   FLEET_TIMEOUT_S=1800            per-cycle child timeout
//!   CHUMP_GAP_CLAIM_TTL_SECS=14400  lease TTL
//!   CHUMP_WORKER_EXEC_OVERRIDE=PATH test seam (e.g. /usr/bin/true)
//!   CHUMP_SESSION_ID=...            stable worker identity
//!
//! ## Phase 1 scope
//!
//! - PULL-mode happy path against state.db (no NATS subscribe).
//! - Single-iteration `--once` for tests.
//! - No new ambient event kinds emitted.

use anyhow::{Context, Result};
use chump_coord::worker::{run_one_cycle, CycleEnv, CycleOutcome};
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

struct CliArgs {
    once: bool,
    idle_sleep_s: u64,
    session_id_override: Option<String>,
    help: bool,
}

fn parse_args(argv: &[String]) -> CliArgs {
    let mut once = false;
    let mut idle_sleep_s = 60u64;
    let mut session_id_override: Option<String> = None;
    let mut help = false;
    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--once" => {
                once = true;
                i += 1;
            }
            "--idle-sleep-s" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse().ok()) {
                    idle_sleep_s = v;
                }
                i += 2;
            }
            "--session-id" => {
                session_id_override = argv.get(i + 1).cloned();
                i += 2;
            }
            "-h" | "--help" => {
                help = true;
                i += 1;
            }
            _ => i += 1,
        }
    }
    CliArgs {
        once,
        idle_sleep_s,
        session_id_override,
        help,
    }
}

fn print_help() {
    eprintln!(
        "chump-worker — Rust port of scripts/dispatch/worker.sh (INFRA-2002)\n\n\
         USAGE:\n\
         \x20   chump-worker [--once] [--idle-sleep-s SECS] [--session-id ID]\n\n\
         FLAGS:\n\
         \x20   --once               run a single cycle then exit (test/CI use)\n\
         \x20   --idle-sleep-s SECS  seconds to sleep between cycles when no work (default 60)\n\
         \x20   --session-id ID      override session id (default: CHUMP_SESSION_ID env or generated)\n\
         \x20   -h, --help           print this message\n\n\
         ENV:\n\
         \x20   WORKER_SKILLS, WORKER_MACHINE, WORKER_BACKEND   capability filters\n\
         \x20   FLEET_TIMEOUT_S                                 per-cycle child timeout (default 1800)\n\
         \x20   CHUMP_GAP_CLAIM_TTL_SECS                        lease TTL (default 14400)\n\
         \x20   CHUMP_WORKER_EXEC_OVERRIDE                      override binary spawned (test seam)\n"
    );
}

fn resolve_session_id(override_id: Option<String>) -> String {
    if let Some(id) = override_id {
        return id;
    }
    if let Ok(id) = env::var("CHUMP_SESSION_ID") {
        if !id.is_empty() {
            return id;
        }
    }
    if let Ok(id) = env::var("CLAUDE_SESSION_ID") {
        if !id.is_empty() {
            return id;
        }
    }
    format!("chump-worker-{}", std::process::id())
}

fn resolve_repo_root() -> Result<PathBuf> {
    if let Ok(r) = env::var("CHUMP_REPO_ROOT") {
        if !r.is_empty() {
            return Ok(PathBuf::from(r));
        }
    }
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .context("running `git rev-parse --show-toplevel`")?;
    if !out.status.success() {
        anyhow::bail!("git rev-parse --show-toplevel exited non-zero");
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        anyhow::bail!("git rev-parse returned empty path");
    }
    Ok(PathBuf::from(s))
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let argv: Vec<String> = env::args().collect();
    let cli = parse_args(&argv);
    if cli.help {
        print_help();
        return ExitCode::SUCCESS;
    }

    let repo_root = match resolve_repo_root() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[chump-worker] cannot resolve repo root: {e}");
            return ExitCode::from(2);
        }
    };
    let session_id = resolve_session_id(cli.session_id_override);
    let cenv = CycleEnv::from_env(repo_root, session_id.clone());

    eprintln!(
        "[chump-worker] starting session={} skills={:?} machine={:?} backend={:?} once={} idle={}s",
        session_id,
        cenv.capability.skills,
        cenv.capability.machine,
        cenv.capability.backend,
        cli.once,
        cli.idle_sleep_s,
    );

    // Phase 1: NATS PUSH path is stubbed — emit a debug message if
    // CHUMP_NATS_URL is set, then fall through to PULL.
    if env::var("CHUMP_NATS_URL").is_ok() {
        eprintln!(
            "[chump-worker] CHUMP_NATS_URL set but PUSH consumer not implemented in Phase 1 \
             (FLEET-034 follow-up); falling back to PULL"
        );
    }

    loop {
        let outcome = run_one_cycle(&cenv).await;
        let should_sleep = outcome.should_idle_sleep();
        match &outcome {
            CycleOutcome::Shipped { gap_id } => {
                eprintln!("[chump-worker] {} SHIPPED {}", session_id, gap_id);
            }
            CycleOutcome::ChildFailed { gap_id, rc } => {
                eprintln!(
                    "[chump-worker] {} CHILD_FAILED {} rc={}",
                    session_id, gap_id, rc
                );
            }
            CycleOutcome::ChildTimeout { gap_id, timeout_s } => {
                eprintln!(
                    "[chump-worker] {} CHILD_TIMEOUT {} after {}s",
                    session_id, gap_id, timeout_s
                );
            }
            CycleOutcome::NoPickableGap => {
                eprintln!("[chump-worker] {} no pickable gap", session_id);
            }
            CycleOutcome::StateError { reason } => {
                eprintln!("[chump-worker] {} state-error: {}", session_id, reason);
            }
            CycleOutcome::LostClaimRace { gap_id } => {
                eprintln!(
                    "[chump-worker] {} lost claim race for {}",
                    session_id, gap_id
                );
            }
            CycleOutcome::WorktreeError { gap_id, reason } => {
                eprintln!(
                    "[chump-worker] {} worktree-error gap={} reason={}",
                    session_id, gap_id, reason
                );
            }
        }
        if cli.once {
            return match outcome {
                CycleOutcome::Shipped { .. } => ExitCode::SUCCESS,
                _ => ExitCode::SUCCESS, // --once always exits 0; outcome is in stderr
            };
        }
        if should_sleep {
            tokio::time::sleep(Duration::from_secs(cli.idle_sleep_s)).await;
        }
    }
}
