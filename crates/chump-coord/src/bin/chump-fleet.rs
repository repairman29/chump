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
use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use std::env;
use std::process::ExitCode;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
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

/// Best-effort CPU count; defaults to 4 if unavailable (matches the
/// convention in `chump-preflight::available_cpus`).
fn available_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}

/// RESILIENT-1014 (a): cap concurrent build-agents to the node's core count.
/// VERIFIED bug: 4 `claude -p` build agents on a 2-core box oversubscribes
/// the CPU. `requested` is clamped down to `cpus` (never below 1) so the
/// supervisor can never spawn more agents than the node can run at once.
fn clamp_size_to_cpus(requested: usize, cpus: usize) -> usize {
    requested.min(cpus.max(1))
}

/// RESILIENT-1014 (c): unique AGENT_ID per node. VERIFIED clash: two
/// different nodes (cuphead, mugman) both reported AGENT_ID=1 because the
/// id was a bare per-process worker index with no node identity baked in.
/// `CHUMP_NODE_ID_OVERRIDE` is a test seam; production reads the kernel
/// hostname (Linux) or falls back to `HOSTNAME`/`unknown-node`.
fn node_id_component() -> String {
    if let Ok(v) = env::var("CHUMP_NODE_ID_OVERRIDE") {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    if let Ok(hostname) = std::fs::read_to_string("/proc/sys/kernel/hostname") {
        let trimmed = hostname.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    if let Ok(v) = env::var("HOSTNAME") {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    "unknown-node".to_string()
}

/// One row of `ps -eo pid,ppid,comm`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ProcEntry {
    pid: u32,
    ppid: u32,
    comm: String,
}

/// RESILIENT-1014 (b): find worker processes that are NOT children of this
/// supervisor process. VERIFIED bug: 9 `worker.sh` processes alive for 1
/// supervised unit on cuphead — stacked/orphaned workers survive a
/// supervisor restart (or a supervisor crash that leaves children
/// reparented) and silently keep claiming leases forever, invisible to a
/// `--size N` cap that only counts this generation's direct children.
fn find_orphaned_worker_pids(procs: &[ProcEntry], own_pid: u32, worker_bin_name: &str) -> Vec<u32> {
    procs
        .iter()
        .filter(|p| p.pid != own_pid && p.ppid != own_pid && p.comm.contains(worker_bin_name))
        .map(|p| p.pid)
        .collect()
}

/// Best-effort `ps` scan. Returns an empty list on any failure (missing
/// `ps`, permission denied, non-Linux quirks) — reaping is a hygiene pass,
/// not a correctness gate, so it must never crash the supervisor.
fn list_processes() -> Vec<ProcEntry> {
    let out = std::process::Command::new("ps")
        .args(["-eo", "pid,ppid,comm", "--no-headers"])
        .output();
    let Ok(out) = out else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let pid = parts.next()?.parse().ok()?;
            let ppid = parts.next()?.parse().ok()?;
            let comm = parts.next()?.to_string();
            Some(ProcEntry { pid, ppid, comm })
        })
        .collect()
}

/// Reap orphaned/stacked worker processes via SIGKILL. Returns the count
/// reaped. Skips entirely when `CHUMP_FLEET_NO_REAP=1` (test/CI seam — CI
/// containers often run unrelated `*-worker`-named processes that must
/// never be killed by an unrelated supervisor's test run).
fn reap_orphaned_workers(own_pid: u32, worker_bin_name: &str) -> usize {
    if env::var("CHUMP_FLEET_NO_REAP").is_ok() {
        return 0;
    }
    let procs = list_processes();
    let orphans = find_orphaned_worker_pids(&procs, own_pid, worker_bin_name);
    for pid in &orphans {
        eprintln!(
            "[chump-fleet] RESILIENT-1014(b): reaping orphaned worker pid={pid} (not a child of this supervisor, pid={own_pid})"
        );
        let _ = std::process::Command::new("kill")
            .args(["-9", &pid.to_string()])
            .status();
    }
    orphans.len()
}

/// RESILIENT-1014: worker-pool health gauge, emitted to `ambient.jsonl` as
/// `kind=worker_pool_health` so `fleet-brief` can surface pool saturation,
/// idle-lane-widening, and reap activity without an operator having to
/// grep supervisor stderr by hand.
struct WorkerPoolHealth {
    node_id: String,
    size: usize,
    cpus: usize,
    active: usize,
    reaped_orphans: usize,
}

fn worker_pool_health_emit_args(h: &WorkerPoolHealth) -> EmitArgs {
    EmitArgs {
        kind: "worker_pool_health".to_string(),
        source: Some("chump-fleet".to_string()),
        fields: vec![
            ("node_id".to_string(), h.node_id.clone()),
            ("size".to_string(), h.size.to_string()),
            ("cpus".to_string(), h.cpus.to_string()),
            ("active".to_string(), h.active.to_string()),
            ("reaped_orphans".to_string(), h.reaped_orphans.to_string()),
        ],
        ..Default::default()
    }
}

fn emit_worker_pool_health(h: &WorkerPoolHealth) {
    let _ = emit(&worker_pool_health_emit_args(h));
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
    let cpus = available_cpus();
    let size = clamp_size_to_cpus(cli.size, cpus);
    if size != cli.size {
        eprintln!(
            "[chump-fleet] RESILIENT-1014: requested size={} exceeds node capacity (cpus={}) — clamping to {} to avoid oversubscription",
            cli.size, cpus, size
        );
    }
    let node_id = node_id_component();
    eprintln!(
        "[chump-fleet] supervisor starting: size={} once={} idle={}s bin={} node_id={}",
        size, cli.once, cli.idle_sleep_s, bin, node_id
    );

    // RESILIENT-1014 (b): reap any stacked/orphaned worker processes left
    // behind by a prior supervisor generation before spawning our own, so
    // `--size N` reflects the real process count, not N-plus-leftovers.
    let reaped = reap_orphaned_workers(std::process::id(), &bin);
    if reaped > 0 {
        eprintln!("[chump-fleet] RESILIENT-1014(b): reaped {reaped} orphaned worker(s) at startup");
    }
    emit_worker_pool_health(&WorkerPoolHealth {
        node_id: node_id.clone(),
        size,
        cpus,
        active: size,
        reaped_orphans: reaped,
    });

    let active = Arc::new(AtomicUsize::new(0));
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let mut handles = Vec::with_capacity(size);
    for i in 0..size {
        let session_id = format!("chump-fleet-{}-{}", std::process::id(), i);
        let agent_id = format!("{}-{}", node_id, i);
        let bin = bin.clone();
        let skills = cli.worker_skills.clone();
        let machine = cli.worker_machine.clone();
        let backend = cli.worker_backend.clone();
        let once = cli.once;
        let idle = cli.idle_sleep_s;
        let mut rx = shutdown_rx.clone();
        let active = active.clone();
        let h = tokio::spawn(async move {
            let mut restart_backoff_s = 5u64;
            loop {
                if *rx.borrow() {
                    break;
                }
                active.fetch_add(1, Ordering::SeqCst);
                let rc = run_one_worker(&WorkerSpawnSpec {
                    bin: &bin,
                    session_id: &session_id,
                    agent_id: &agent_id,
                    skills: skills.as_deref(),
                    machine: machine.as_deref(),
                    backend: backend.as_deref(),
                    once,
                    idle_sleep_s: idle,
                })
                .await;
                active.fetch_sub(1, Ordering::SeqCst);
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

    // RESILIENT-1014: periodic worker_pool_health gauge + orphan-reap sweep
    // while supervising (skipped in --once, which is a single test cycle).
    let health_task = if cli.once {
        None
    } else {
        let node_id = node_id.clone();
        let bin = bin.clone();
        let active = active.clone();
        let mut rx = shutdown_rx.clone();
        Some(tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(60)) => {}
                    _ = rx.changed() => {
                        if *rx.borrow() { break; }
                    }
                }
                if *rx.borrow() {
                    break;
                }
                let reaped = reap_orphaned_workers(std::process::id(), &bin);
                if reaped > 0 {
                    eprintln!(
                        "[chump-fleet] RESILIENT-1014(b): reaped {reaped} orphaned worker(s) mid-flight"
                    );
                }
                emit_worker_pool_health(&WorkerPoolHealth {
                    node_id: node_id.clone(),
                    size,
                    cpus,
                    active: active.load(Ordering::SeqCst),
                    reaped_orphans: reaped,
                });
            }
        }))
    };

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
    if let Some(h) = health_task {
        h.abort();
    }
    ExitCode::SUCCESS
}

struct WorkerSpawnSpec<'a> {
    bin: &'a str,
    session_id: &'a str,
    agent_id: &'a str,
    skills: Option<&'a str>,
    machine: Option<&'a str>,
    backend: Option<&'a str>,
    once: bool,
    idle_sleep_s: u64,
}

async fn run_one_worker(spec: &WorkerSpawnSpec<'_>) -> Result<i32> {
    let mut cmd = Command::new(spec.bin);
    cmd.arg("--session-id")
        .arg(spec.session_id)
        .arg("--idle-sleep-s")
        .arg(spec.idle_sleep_s.to_string());
    if spec.once {
        cmd.arg("--once");
    }
    // RESILIENT-1014 (c): globally-unique AGENT_ID (node_id + local index) so
    // two nodes running the supervisor concurrently never report the same id.
    cmd.env("AGENT_ID", spec.agent_id);
    if let Some(s) = spec.skills {
        cmd.env("WORKER_SKILLS", s);
    }
    if let Some(m) = spec.machine {
        cmd.env("WORKER_MACHINE", m);
    }
    if let Some(b) = spec.backend {
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

#[cfg(test)]
mod tests {
    use super::*;

    // RESILIENT-1014 (a): concurrency cap must never exceed the node's cores.
    #[test]
    fn clamp_size_to_cpus_no_clamp_when_within_cap() {
        assert_eq!(clamp_size_to_cpus(2, 4), 2);
    }

    #[test]
    fn clamp_size_to_cpus_clamps_oversubscription() {
        // VERIFIED bug: 4 requested build-agents on a 2-core box.
        assert_eq!(clamp_size_to_cpus(4, 2), 2);
    }

    #[test]
    fn clamp_size_to_cpus_never_below_one() {
        assert_eq!(clamp_size_to_cpus(5, 0), 1);
    }

    // RESILIENT-1014 (c): AGENT_ID must be unique per node, not just per
    // in-process worker index.
    #[test]
    #[serial_test::serial(chump_fleet_node_id_env)]
    fn node_id_component_uses_override() {
        env::set_var("CHUMP_NODE_ID_OVERRIDE", "cuphead");
        assert_eq!(node_id_component(), "cuphead");
        env::remove_var("CHUMP_NODE_ID_OVERRIDE");
    }

    #[test]
    #[serial_test::serial(chump_fleet_node_id_env)]
    fn node_id_component_differs_across_nodes() {
        // Simulates the VERIFIED clash: two nodes must not collapse to the
        // same node identity, so their per-index AGENT_IDs never collide.
        env::set_var("CHUMP_NODE_ID_OVERRIDE", "cuphead");
        let cuphead_id = format!("{}-{}", node_id_component(), 1);
        env::set_var("CHUMP_NODE_ID_OVERRIDE", "mugman");
        let mugman_id = format!("{}-{}", node_id_component(), 1);
        env::remove_var("CHUMP_NODE_ID_OVERRIDE");
        assert_ne!(cuphead_id, mugman_id);
    }

    // RESILIENT-1014 (b): orphan detection must never flag our own children
    // (ppid == own_pid) or ourselves, only stacked leftovers from a prior
    // supervisor generation.
    #[test]
    fn find_orphaned_worker_pids_flags_only_non_children() {
        let own_pid = 100;
        let procs = vec![
            ProcEntry {
                pid: 101,
                ppid: 100,
                comm: "chump-worker".to_string(),
            }, // our own child — not an orphan
            ProcEntry {
                pid: 202,
                ppid: 1,
                comm: "chump-worker".to_string(),
            }, // VERIFIED case: reparented to init after a prior supervisor died
            ProcEntry {
                pid: 303,
                ppid: 1,
                comm: "chump-fleet".to_string(),
            }, // different binary — not a worker, must not be reaped
            ProcEntry {
                pid: 100,
                ppid: 1,
                comm: "chump-worker".to_string(),
            }, // our own pid — never self-reap
        ];
        let orphans = find_orphaned_worker_pids(&procs, own_pid, "chump-worker");
        assert_eq!(orphans, vec![202]);
    }

    #[test]
    fn find_orphaned_worker_pids_empty_when_all_are_children() {
        let own_pid = 5;
        let procs = vec![ProcEntry {
            pid: 6,
            ppid: 5,
            comm: "chump-worker".to_string(),
        }];
        assert!(find_orphaned_worker_pids(&procs, own_pid, "chump-worker").is_empty());
    }

    // RESILIENT-1014: worker_pool_health gauge fields must reflect the
    // clamped size (not the raw --size request) and the reap count from
    // this cycle, since fleet-brief reads these to detect oversubscription
    // and stacked-worker leaks without an operator grepping stderr.
    #[test]
    fn worker_pool_health_gauge_carries_reap_and_saturation_fields() {
        let h = WorkerPoolHealth {
            node_id: "cuphead".to_string(),
            size: 2,
            cpus: 2,
            active: 2,
            reaped_orphans: 3,
        };
        let args = worker_pool_health_emit_args(&h);
        assert_eq!(args.kind, "worker_pool_health");
        let field = |k: &str| {
            args.fields
                .iter()
                .find(|(fk, _)| fk == k)
                .map(|(_, v)| v.clone())
        };
        assert_eq!(field("node_id"), Some("cuphead".to_string()));
        assert_eq!(field("size"), Some("2".to_string()));
        assert_eq!(field("cpus"), Some("2".to_string()));
        assert_eq!(field("active"), Some("2".to_string()));
        assert_eq!(field("reaped_orphans"), Some("3".to_string()));
    }
}
