//! `chump-fleet` — Rust port of `scripts/dispatch/run-fleet.sh` (INFRA-2002).
//!
//! META-107 sub-gap #6 of 6. Routed via `CHUMP_FLEET_RUST=1` from the bash
//! shim; the legacy 750-LOC bash body stays in place for the parallel-run
//! window.
//!
//! ## What it does
//!
//! Spawns N worker subprocesses (each running `chump-worker`), restarts
//! any that exit early with exponential backoff, and exits cleanly on
//! SIGTERM / SIGINT.
//!
//! ## CLI surface
//!
//! ```text
//! chump-fleet [--size N] [--worker-skills CSV] [--worker-machine NAME]
//!             [--worker-backend NAME] [--once] [--idle-sleep-s SECS]
//! ```
//!
//! - `--size N`         number of worker subprocesses (default 1).
//! - `--once`           pass `--once` to each worker (single-cycle test mode).
//! - `--idle-sleep-s S` pass through to workers as their idle sleep.
//!
//! ## Phase 1 scope
//!
//! - PULL-mode only (workers stub the NATS PUSH path).
//! - No `worker_restarted` emission (kind not registered; would require
//!   EVENT_REGISTRY edit which is forbidden for this PR).
//! - Restart with linear 5s backoff for now (exponential deferred).

use anyhow::{Context, Result};
use std::env;
use std::process::ExitCode;
use std::time::Duration;
use tokio::process::Command;
use tokio::signal;
use tokio::sync::watch;

struct CliArgs {
    size: usize,
    worker_skills: Option<String>,
    worker_machine: Option<String>,
    worker_backend: Option<String>,
    once: bool,
    idle_sleep_s: u64,
    help: bool,
}

fn parse_args(argv: &[String]) -> CliArgs {
    let mut size = 1usize;
    let mut worker_skills = None;
    let mut worker_machine = None;
    let mut worker_backend = None;
    let mut once = false;
    let mut idle_sleep_s = 60u64;
    let mut help = false;
    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--size" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse().ok()) {
                    size = v;
                }
                i += 2;
            }
            "--worker-skills" => {
                worker_skills = argv.get(i + 1).cloned();
                i += 2;
            }
            "--worker-machine" => {
                worker_machine = argv.get(i + 1).cloned();
                i += 2;
            }
            "--worker-backend" => {
                worker_backend = argv.get(i + 1).cloned();
                i += 2;
            }
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
            "-h" | "--help" => {
                help = true;
                i += 1;
            }
            _ => i += 1,
        }
    }
    CliArgs {
        size,
        worker_skills,
        worker_machine,
        worker_backend,
        once,
        idle_sleep_s,
        help,
    }
}

fn print_help() {
    eprintln!(
        "chump-fleet — Rust port of scripts/dispatch/run-fleet.sh (INFRA-2002)\n\n\
         USAGE:\n\
         \x20   chump-fleet [--size N] [--worker-skills CSV] [--worker-machine NAME]\n\
         \x20               [--worker-backend NAME] [--once] [--idle-sleep-s SECS]\n\n\
         FLAGS:\n\
         \x20   --size N             number of worker subprocesses (default 1)\n\
         \x20   --worker-skills CSV  comma-separated skills passed as WORKER_SKILLS to each worker\n\
         \x20   --worker-machine X   machine label passed as WORKER_MACHINE\n\
         \x20   --worker-backend X   backend label passed as WORKER_BACKEND\n\
         \x20   --once               pass --once to each worker (test/CI use)\n\
         \x20   --idle-sleep-s SECS  pass through to workers (default 60)\n\
         \x20   -h, --help           print this message\n\n\
         ENV:\n\
         \x20   CHUMP_WORKER_BIN     override path to chump-worker binary (default: 'chump-worker')\n"
    );
}

fn worker_bin() -> String {
    env::var("CHUMP_WORKER_BIN").unwrap_or_else(|_| "chump-worker".to_string())
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> ExitCode {
    let argv: Vec<String> = env::args().collect();
    let cli = parse_args(&argv);
    if cli.help {
        print_help();
        return ExitCode::SUCCESS;
    }
    if cli.size == 0 {
        eprintln!("[chump-fleet] --size 0 → nothing to do, exiting");
        return ExitCode::SUCCESS;
    }

    let bin = worker_bin();
    eprintln!(
        "[chump-fleet] supervisor starting: size={} once={} idle={}s bin={}",
        cli.size, cli.once, cli.idle_sleep_s, bin
    );

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let mut handles = Vec::with_capacity(cli.size);
    for i in 0..cli.size {
        let session_id = format!("chump-fleet-{}-{}", std::process::id(), i);
        let bin = bin.clone();
        let skills = cli.worker_skills.clone();
        let machine = cli.worker_machine.clone();
        let backend = cli.worker_backend.clone();
        let once = cli.once;
        let idle = cli.idle_sleep_s;
        let mut rx = shutdown_rx.clone();
        let h = tokio::spawn(async move {
            let mut restart_backoff_s = 5u64;
            loop {
                if *rx.borrow() {
                    break;
                }
                let rc = run_one_worker(
                    &bin,
                    &session_id,
                    skills.as_deref(),
                    machine.as_deref(),
                    backend.as_deref(),
                    once,
                    idle,
                )
                .await;
                match rc {
                    Ok(0) => {
                        eprintln!("[chump-fleet] worker {} exit 0", session_id);
                        if once {
                            break;
                        }
                        restart_backoff_s = 5;
                    }
                    Ok(code) => {
                        eprintln!(
                            "[chump-fleet] worker {} exit {} — restarting in {}s",
                            session_id, code, restart_backoff_s
                        );
                    }
                    Err(e) => {
                        eprintln!(
                            "[chump-fleet] worker {} spawn-error: {} — retrying in {}s",
                            session_id, e, restart_backoff_s
                        );
                    }
                }
                if once {
                    break;
                }
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(restart_backoff_s)) => {}
                    _ = rx.changed() => {
                        if *rx.borrow() { break; }
                    }
                }
                restart_backoff_s = (restart_backoff_s * 2).min(120);
            }
        });
        handles.push(h);
    }

    // Wait for signal or all workers to exit.
    let all_done = async {
        for h in handles {
            let _ = h.await;
        }
    };
    tokio::select! {
        _ = all_done => {
            eprintln!("[chump-fleet] all workers exited");
        }
        _ = wait_for_signal() => {
            eprintln!("[chump-fleet] signal received, shutting down");
            let _ = shutdown_tx.send(true);
            // Give workers a moment to notice the flag, but don't wait forever.
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
    ExitCode::SUCCESS
}

async fn run_one_worker(
    bin: &str,
    session_id: &str,
    skills: Option<&str>,
    machine: Option<&str>,
    backend: Option<&str>,
    once: bool,
    idle_sleep_s: u64,
) -> Result<i32> {
    let mut cmd = Command::new(bin);
    cmd.arg("--session-id")
        .arg(session_id)
        .arg("--idle-sleep-s")
        .arg(idle_sleep_s.to_string());
    if once {
        cmd.arg("--once");
    }
    if let Some(s) = skills {
        cmd.env("WORKER_SKILLS", s);
    }
    if let Some(m) = machine {
        cmd.env("WORKER_MACHINE", m);
    }
    if let Some(b) = backend {
        cmd.env("WORKER_BACKEND", b);
    }
    // Forward CHUMP_WORKER_EXEC_OVERRIDE if set (test seam).
    if let Ok(v) = env::var("CHUMP_WORKER_EXEC_OVERRIDE") {
        cmd.env("CHUMP_WORKER_EXEC_OVERRIDE", v);
    }
    if let Ok(v) = env::var("CHUMP_REPO_ROOT") {
        cmd.env("CHUMP_REPO_ROOT", v);
    }
    cmd.kill_on_drop(true);
    let status = cmd.status().await.context("spawning chump-worker")?;
    Ok(status.code().unwrap_or(-1))
}

async fn wait_for_signal() {
    #[cfg(unix)]
    {
        use signal::unix::{signal as unix_signal, SignalKind};
        let mut term = match unix_signal(SignalKind::terminate()) {
            Ok(s) => s,
            Err(_) => {
                let _ = signal::ctrl_c().await;
                return;
            }
        };
        let mut int = match unix_signal(SignalKind::interrupt()) {
            Ok(s) => s,
            Err(_) => {
                let _ = signal::ctrl_c().await;
                return;
            }
        };
        tokio::select! {
            _ = term.recv() => {}
            _ = int.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = signal::ctrl_c().await;
    }
}
