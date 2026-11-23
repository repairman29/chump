//! chumpd — MISSION-051 supervisor daemon v0 (ground-up step 2).
//!
//! One process owns the worker pool. Workers are supervised CHILD processes —
//! no tmux server to die silently, no launchd override DB to disable them, no
//! farmer/pool-keeper split-brain. This v0 deletes the failure classes that
//! killed the fleet five times on 2026-07-19:
//!
//!   - dead tmux server            → children of chumpd; launchd KeepAlive
//!     revives chumpd, chumpd revives workers
//!   - pgrep-pattern liveness      → direct child PID + heartbeat mtimes
//!   - relaunch-at-wrong-size      → single source: ~/.chump/fleet-desired-size
//!   - silent relaunch failure     → spawn errors are events, not banners
//!
//! The operator dial keeps working: chumpd polls ~/.chump/fleet-mode
//! (grind|travel|off) every tick. Status drops to /tmp/chumpd-status.json for
//! ChumpBar. Events append to .chump-locks/ambient.jsonl.
//!
//! v0 scope: supervise + restart + wedge-kill + mode obedience. The state-API
//! socket (CLI reads via chumpd) is the next slice; see MISSION-051 AC.

mod file_sandbox;
pub mod lease_reaper;
#[path = "../../../src/node_pause.rs"]
pub mod node_pause;
pub mod oauth_sync;
mod worker_loop;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::TcpListener;

/// 0 = running; nonzero = the raw signal number that requested shutdown.
/// Carrying the signal (not just a bool) lets `main` exit with the
/// conventional 128+n status code instead of always reporting a plain 0,
/// so a supervisor (systemd/launchd) or `wait $pid` can tell a SIGTERM
/// stop apart from a SIGINT stop apart from a clean internal exit.
static SHUTDOWN_SIGNAL: AtomicI32 = AtomicI32::new(0);

/// MISSION-073 AC3: map the signal that requested shutdown to a process
/// exit code. `0` (no signal — reserved for future non-signal shutdown
/// paths) exits clean; any real signal uses the standard `128 + signum`
/// convention shells and systemd/launchd already expect.
fn exit_code_for_signal(sig: i32) -> i32 {
    chump_pal::exit_code_for_signal(sig)
}

/// MISSION-073 AC2 / MISSION-069: fail-open disk-floor gate. Returns
/// `false` only when free space on the repo filesystem is measurably
/// below the critical threshold — an unreadable/unparseable disk probe never
/// blocks worker spawning, since chumpd's job is supervising the fleet,
/// not acting as a disk monitor of record (that's chump-disk-inventory).
fn disk_floor_gate_open(free_gb: Option<f64>, threshold_gb: f64) -> bool {
    match free_gb {
        Some(free) => !chump_disk_inventory::is_critical(free, threshold_gb),
        None => true,
    }
}

fn measure_free_gb(path: &Path) -> Option<f64> {
    chump_pal::free_disk_gb(path)
}

/// Derive CARGO_BUILD_JOBS from physical RAM (~1.2GB per rustc job, half of RAM
/// budgeted for builds), clamped to 1..=cpus. Falls back to 4 if RAM is unknown.
fn derive_cargo_build_jobs(total_ram_gb: Option<f64>, cpus: usize) -> usize {
    chump_pal::derive_cargo_build_jobs_from(total_ram_gb, cpus)
}

fn measure_total_ram_gb() -> Option<f64> {
    chump_pal::total_ram_gb()
}

fn cargo_build_jobs() -> usize {
    derive_cargo_build_jobs(measure_total_ram_gb(), chump_pal::available_cpus())
}

const TICK_SECS: u64 = 15;
/// Worker heartbeats write every ~60s (FLEET-042). m-effort cycles run up to
/// 2700s with the 1800s base; a heartbeat older than this means the worker is
/// wedged (its 60s writer died) even if the PID is alive.
const HEARTBEAT_WEDGE_SECS: u64 = 900;
/// Per-slot respawn budget: more than this many respawns in an hour marks the
/// slot broken and emits escalated=true instead of thrashing.
const RESPAWN_STORM_PER_HOUR: usize = 6;

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn iso_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

#[derive(Clone)]
struct Config {
    repo: PathBuf,
    home: PathBuf,
    log_dir: PathBuf,
}

impl Config {
    fn load() -> Self {
        let home = chump_pal::user_home();
        let repo = std::env::var("CHUMP_REPO")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join("Projects/Chump"));
        let log_dir = chump_pal::temp_file_path(&format!("chumpd-fleet-{}", now_epoch()));
        Config {
            repo,
            home,
            log_dir,
        }
    }

    fn state_dir(&self) -> PathBuf {
        std::env::var("CHUMP_STATE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| self.home.join(".chump"))
    }

    fn is_paused(&self) -> bool {
        self.repo.join(".chump/fleet-paused").exists() || node_pause::is_paused(&self.state_dir())
    }

    fn mode(&self) -> String {
        if let Ok(s) = fs::read_to_string(self.home.join(".chump/fleet-mode")) {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
        chump_config::ChumpConfig::load_effective()
            .map(|c| c.fleet.mode.as_str().to_string())
            .unwrap_or_else(|_| "off".into())
    }

    fn desired_size(&self) -> usize {
        let from_file = fs::read_to_string(self.repo.join(".chump/fleet-desired-size"))
            .ok()
            .and_then(|s| s.trim().parse::<usize>().ok());
        let cfg_desired = chump_config::ChumpConfig::load_effective()
            .ok()
            .map(|c| c.fleet.desired_workers)
            .filter(|&n| n > 0);
        match (from_file.or(cfg_desired), self.mode().as_str()) {
            (Some(n), _) if n > 0 => n.min(64),
            (_, "grind") => 2,
            (_, "travel") => 2,
            _ => 0,
        }
    }

    fn ambient(&self) -> PathBuf {
        self.repo.join(".chump-locks/ambient.jsonl")
    }
}

fn emit(cfg: &Config, json: &str) {
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(cfg.ambient())
    {
        let _ = writeln!(f, "{}", json);
    }
    println!("{}", json);
}

fn heartbeat_dir() -> String {
    std::env::var("CHUMP_HEARTBEAT_DIR")
        .unwrap_or_else(|_| chump_pal::temp_dir().to_string_lossy().into_owned())
}

fn status_file_path() -> PathBuf {
    chump_pal::temp_file_path("chumpd-status.json")
}

fn heartbeat_age(agent_id: usize) -> Option<u64> {
    let p = format!(
        "{}/chump-fleet-worker-{}.heartbeat",
        heartbeat_dir(),
        agent_id
    );
    let meta = fs::metadata(p).ok()?;
    let mtime = meta.modified().ok()?;
    mtime.elapsed().ok().map(|d| d.as_secs())
}

fn spawn_worker(cfg: &Config, agent_id: usize) -> std::io::Result<Child> {
    fs::create_dir_all(&cfg.log_dir)?;
    // Reset the heartbeat clock to spawn time: a stale file left by a previous
    // fleet incarnation must not age-out the NEWBORN child (first live cutover
    // wedge-killed both workers every tick off 900s-old files).
    let hb = format!(
        "{}/chump-fleet-worker-{}.heartbeat",
        heartbeat_dir(),
        agent_id
    );
    let _ = fs::write(
        &hb,
        format!(
            "{}
",
            now_epoch()
        ),
    );
    let log_path = cfg.log_dir.join(format!("agent-{}.log", agent_id));
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)?;
    let log_err = log.try_clone()?;

    let worker = cfg.repo.join("scripts/dispatch/worker.sh");
    let use_legacy_sh = !cfg!(windows)
        && std::env::var("CHUMP_WORKER_LEGACY_SH").as_deref() == Ok("1")
        && worker.is_file();
    let chumpd_exe = std::env::current_exe().unwrap_or_else(|_| {
        PathBuf::from(if cfg!(windows) {
            "chumpd.exe"
        } else {
            "chumpd"
        })
    });

    let path_env = {
        let mut dirs: Vec<PathBuf> = vec![cfg.home.join(".cargo/bin"), cfg.home.join(".local/bin")];
        if !cfg!(windows) {
            dirs.insert(0, PathBuf::from("/opt/homebrew/bin"));
        }
        if let Some(existing) = std::env::var_os("PATH") {
            dirs.extend(std::env::split_paths(&existing));
        }
        std::env::join_paths(dirs)
            .map(|os| os.to_string_lossy().into_owned())
            .unwrap_or_default()
    };

    let worktree_base = std::env::var("CHUMP_WORKTREE_BASE").ok().map(PathBuf::from);
    let sandboxed = file_sandbox::worker_sandbox_enabled();
    let mut command = if sandboxed {
        let profile =
            file_sandbox::build_worker_profile(&cfg.repo, worktree_base.as_deref(), &cfg.home);
        let mut c = Command::new("/usr/bin/sandbox-exec");
        c.arg("-p").arg(profile);
        if use_legacy_sh {
            c.arg("/bin/sh").arg(&worker);
        } else {
            c.arg(&chumpd_exe).arg("worker").arg("--native");
        }
        c
    } else if use_legacy_sh {
        let mut c = Command::new("/bin/sh");
        c.arg(&worker);
        c
    } else {
        let mut c = Command::new(&chumpd_exe);
        c.arg("worker").arg("--native");
        c
    };
    chump_pal::configure_isolated_child(&mut command);

    // MISSION-051 / RESILIENT-184: backend selection. CHUMPD_FLEET_BACKEND
    // lets an operator run the fleet on an open model (chump-local) instead
    // of the Claude subscription.
    let state_dir = std::env::var("CHUMP_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| cfg.home.join(".chump"));
    let backend = std::env::var("CHUMPD_FLEET_BACKEND")
        .or_else(|_| std::env::var("FLEET_BACKEND"))
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| worker_loop::read_env_from_node_env(&state_dir, "FLEET_BACKEND"))
        .unwrap_or_else(|| "claude".into());
    // CREDIBLE-1612: honor FLEET_MODEL from env or <state_dir>/node.env,
    // defaulting to "sonnet" on the claude backend ("flash" on chump-local).
    let default_model = if backend == "chump-local" {
        "flash"
    } else {
        "sonnet"
    };
    let fleet_model = std::env::var("FLEET_MODEL")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| worker_loop::read_env_from_node_env(&state_dir, "FLEET_MODEL"))
        .unwrap_or_else(|| default_model.to_string());
    let effort_filter = if backend == "chump-local" {
        "xs,s"
    } else {
        "m"
    };

    let build_jobs = cargo_build_jobs();
    eprintln!("chumpd: worker {agent_id} CARGO_BUILD_JOBS={build_jobs} (derived from RAM/cpus)");

    let file_cfg = chump_config::ChumpConfig::load_effective().unwrap_or_default();
    let agent_harness = std::env::var("CHUMP_AGENT_HARNESS")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| file_cfg.effective_harness().to_string());

    for (k, v) in worker_loop::resolve_worker_child_env(&state_dir) {
        command.env(k, v);
    }

    command
        .current_dir(&cfg.repo)
        .env("PATH", path_env)
        .env("HOME", &cfg.home)
        .env("REPO_ROOT", &cfg.repo)
        .env("CHUMP_REPO", &cfg.repo)
        .env("FLEET_LOCKS_DIR", cfg.repo.join(".chump-locks"))
        .env("FLEET_LOG_DIR", &cfg.log_dir)
        .env("FLEET_TIMEOUT_S", "1800")
        .env("FLEET_PRIORITY_FILTER", "P0,P1")
        .env("FLEET_EFFORT_FILTER", effort_filter)
        .env("FLEET_BACKEND", &backend)
        .env("FLEET_MODEL", &fleet_model)
        .env("FLEET_SESSION", "chumpd")
        .env("FLEET_INLINE_BRIEFING", "1")
        .env("CHUMP_AGENT_HARNESS", &agent_harness)
        .env("CARGO_TARGET_DIR", cfg.repo.join("target"))
        .env("CARGO_BUILD_JOBS", build_jobs.to_string())
        .env(
            "CHUMP_OAUTH_TOKEN_FILE",
            cfg.home.join(".chump/oauth-token.json"),
        )
        .env("AGENT_ID", agent_id.to_string())
        .env("CHUMP_HEARTBEAT_DIR", heartbeat_dir())
        .env("CHUMPD_OWNED", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
}

/// Clean-slate takeover: chumpd is the sole owner of the pool. Kill any
/// pre-existing tmux fleet and orphan worker loops so we never double-spawn.
fn takeover(_cfg: &Config) {
    // Test harness / cohabitation guard: CHUMPD_TAKEOVER=0 skips the global
    // sweep (a CI fixture must never pkill a live fleet's workers).
    let takeover_enabled = std::env::var("CHUMPD_TAKEOVER").as_deref() != Ok("0");
    #[cfg(unix)]
    if takeover_enabled {
        let _ = Command::new("pkill")
            .args(["-f", "dispatch/worker.sh"])
            .status();
        let _ = Command::new("tmux")
            .args(["kill-session", "-t", "chump-fleet"])
            .stderr(Stdio::null())
            .status();
    }
    #[cfg(not(unix))]
    let _ = takeover_enabled;
}

struct Slot {
    child: Option<Child>,
    respawns: Vec<u64>,
    broken: bool,
}

/// RESILIENT-178 AC#2: a blocked worker file access must be auditable, not
/// silent. sandbox-exec denials are logged by the kernel to the macOS
/// unified log; this polls the last `window_secs` for denial lines and
/// re-emits each as an ambient event carrying the attempted path, so the
/// same fleet-brief / infra-watcher consumers that already read
/// ambient.jsonl pick it up without a new subsystem. No-op on non-macOS
/// or when the `log` CLI is unavailable (dev boxes, CI).
fn scan_worker_sandbox_denials(cfg: &Config, window_secs: u64) {
    if !cfg!(target_os = "macos") || !Path::new("/usr/bin/log").is_file() {
        return;
    }
    let predicate = r#"eventMessage contains "deny(1) file-read" or eventMessage contains "deny(1) file-write""#;
    let out = Command::new("/usr/bin/log")
        .args([
            "show",
            "--style",
            "ndjson",
            "--last",
            &format!("{}s", window_secs),
            "--predicate",
            predicate,
        ])
        .output();
    let Ok(out) = out else { return };
    if !out.status.success() {
        return;
    }
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let msg = v.get("eventMessage").and_then(|m| m.as_str()).unwrap_or("");
        if msg.is_empty() {
            continue;
        }
        let process = v
            .get("processImagePath")
            .and_then(|p| p.as_str())
            .unwrap_or("unknown");
        // The kernel denial message ends with the offending path
        // ("...deny(1) file-read-data /Users/op/Desktop/x"); take the
        // trailing whitespace-delimited token as a best-effort path.
        let path = msg.rsplit(' ').next().unwrap_or("");
        // scanner-anchor: "kind":"chumpd_worker_sandbox_denied"
        emit(
            cfg,
            &format!(
                r#"{{"ts":"{}","kind":"chumpd_worker_sandbox_denied","path":"{}","process":"{}","raw":"{}"}}"#,
                iso_now(),
                path.replace('"', "'"),
                process.replace('"', "'"),
                msg.replace('"', "'")
            ),
        );
    }
}

fn write_status(_cfg: &Config, mode: &str, desired: usize, slots: &HashMap<usize, Slot>) {
    let workers: Vec<serde_json::Value> = slots
        .iter()
        .map(|(id, s)| {
            serde_json::json!({
                "id": id,
                "pid": s.child.as_ref().map(|c| c.id()),
                "broken": s.broken,
                "hb_age_s": heartbeat_age(*id),
            })
        })
        .collect();
    let status = serde_json::json!({
        "ts": iso_now(),
        "mode": mode,
        "desired": desired,
        "workers": workers,
    });
    let status_path = status_file_path();
    let tmp = chump_pal::temp_file_path("chumpd-status.json.tmp");
    if fs::write(&tmp, status.to_string()).is_ok() {
        let _ = fs::rename(&tmp, &status_path);
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "method", rename_all = "kebab-case")]
enum RpcRequest {
    Ping,
    Status,
    DbPath,
}

#[derive(Serialize)]
struct RpcResponse {
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    db_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    status_json: Option<serde_json::Value>,
}

async fn handle_ipc(cfg: Config, listener: TcpListener, expected_token: String) {
    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                let cfg = cfg.clone();
                let tok = expected_token.clone();
                tokio::spawn(async move {
                    if let Ok((req, mut stream)) =
                        chump_pal::ipc::accept_authenticated::<RpcRequest>(stream, peer, &tok).await
                    {
                        let resp = match req {
                            RpcRequest::Ping => RpcResponse {
                                status: "pong".into(),
                                db_path: None,
                                status_json: None,
                            },
                            RpcRequest::DbPath => RpcResponse {
                                status: "ok".into(),
                                db_path: Some(
                                    chump_store_path::state_db_path(&cfg.repo)
                                        .display()
                                        .to_string(),
                                ),
                                status_json: None,
                            },
                            RpcRequest::Status => {
                                let status_raw = fs::read_to_string(status_file_path())
                                    .unwrap_or_else(|_| "{}".into());
                                let status_json = serde_json::from_str(&status_raw).ok();
                                RpcResponse {
                                    status: "ok".into(),
                                    db_path: None,
                                    status_json,
                                }
                            }
                        };
                        let _ = chump_pal::ipc::write_json_response(&mut stream, &resp).await;
                    }
                });
            }
            Err(e) => {
                eprintln!("ipc accept error: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

#[tokio::main]
async fn main() {
    // PHASE-R R6 / INFRA-8575: thin `chumpd worker` arm — the per-worker loop
    // control (cadence, heartbeat, fleet-paused sentinel, per-tick budget).
    // Dispatched before any supervisor setup so it never binds the IPC server or
    // takes pool ownership; worker.sh execs this.
    let argv: Vec<String> = std::env::args().collect();
    if argv.get(1).map(String::as_str) == Some("worker") {
        std::process::exit(worker_loop::run(&argv[2..]));
    }

    chump_pal::install_shutdown_signal(&SHUTDOWN_SIGNAL);

    let cfg = Config::load();
    takeover(&cfg);

    // Cross-platform authenticated loopback TCP IPC (`<state_dir>/run/chumpd.ipc`).
    let ipc_path = chump_pal::ipc::ipc_file_path_in(&cfg.state_dir(), "chumpd");
    let _ipc_guard = match chump_pal::ipc::IpcServer::bind_at(&ipc_path) {
        Ok(server) => {
            if let Ok(listener) = server.tokio_listener() {
                let cfg_clone = cfg.clone();
                let tok = server.token().to_string();
                tokio::spawn(async move {
                    handle_ipc(cfg_clone, listener, tok).await;
                });
            }
            Some(server)
        }
        Err(e) => {
            eprintln!(
                "chumpd: failed to bind local ipc at {}: {e}",
                ipc_path.display()
            );
            None
        }
    };

    // Spawn native cross-platform maintenance organs (Milestone 4):
    // 1. Subscription OAuth token sync/refresher (every 5 min + immediate startup pass).
    let oauth_interval = std::env::var("CHUMP_OAUTH_REFRESH_INTERVAL_S")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(oauth_sync::DEFAULT_OAUTH_REFRESH_INTERVAL_SECS);
    oauth_sync::spawn_background_sync(oauth_sync::resolve_oauth_token_target(), oauth_interval);

    // 2. Pure-Rust stale `.chump-locks/*.json` lease reaper (every 60s + immediate pass).
    let reap_interval = std::env::var("CHUMP_LEASE_REAP_INTERVAL_S")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(lease_reaper::DEFAULT_LEASE_REAP_INTERVAL_SECS);
    lease_reaper::spawn_background_reaper(cfg.repo.join(".chump-locks"), reap_interval);

    // scanner-anchor: "kind":"chumpd_started"
    emit(
        &cfg,
        &format!(
            r#"{{"ts":"{}","kind":"chumpd_started","repo":"{}","note":"MISSION-051 v0 supervisor up; pool ownership taken (tmux fleet + orphan workers cleared)"}}"#,
            iso_now(),
            cfg.repo.display()
        ),
    );

    let mut slots: HashMap<usize, Slot> = HashMap::new();
    let mut last_mode = String::new();
    let mut disk_gate_open = true;

    while SHUTDOWN_SIGNAL.load(Ordering::SeqCst) == 0 {
        let mode = cfg.mode();
        let desired = if mode == "off" || cfg.is_paused() {
            0
        } else {
            cfg.desired_size()
        };

        // MISSION-073 AC2 / MISSION-069: disk-floor gate. Re-measured every
        // tick so a host that fills up mid-run stops handing out new worker
        // slots without needing a chumpd restart; a host that frees space
        // back up re-opens the gate the same way.
        let threshold_gb = chump_disk_inventory::resolve_threshold_gb();
        let free_gb = measure_free_gb(&cfg.repo);
        let gate_open_now = disk_floor_gate_open(free_gb, threshold_gb);
        if gate_open_now != disk_gate_open {
            // scanner-anchor: "kind":"chumpd_disk_floor_gate_changed"
            emit(
                &cfg,
                &format!(
                    r#"{{"ts":"{}","kind":"chumpd_disk_floor_gate_changed","open":{},"free_gb":{},"threshold_gb":{}}}"#,
                    iso_now(),
                    gate_open_now,
                    free_gb
                        .map(|g| format!("{:.2}", g))
                        .unwrap_or_else(|| "null".into()),
                    threshold_gb
                ),
            );
            disk_gate_open = gate_open_now;
        }

        if mode != last_mode {
            // scanner-anchor: "kind":"chumpd_mode_change"
            emit(
                &cfg,
                &format!(
                    r#"{{"ts":"{}","kind":"chumpd_mode_change","from":"{}","to":"{}","desired":{}}}"#,
                    iso_now(),
                    last_mode,
                    mode,
                    desired
                ),
            );
            last_mode = mode.clone();
        }

        // Reap exits + wedge-kill stale-heartbeat children.
        for (id, slot) in slots.iter_mut() {
            if slot.broken {
                continue;
            }
            let mut died = false;
            if let Some(child) = slot.child.as_mut() {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        // scanner-anchor: "kind":"chumpd_worker_exit"
                        emit(
                            &cfg,
                            &format!(
                                r#"{{"ts":"{}","kind":"chumpd_worker_exit","agent":{},"code":{}}}"#,
                                iso_now(),
                                id,
                                status.code().unwrap_or(-1)
                            ),
                        );
                        died = true;
                    }
                    Ok(None) => {
                        if let Some(age) = heartbeat_age(*id) {
                            if age > HEARTBEAT_WEDGE_SECS {
                                let _ = child.kill();
                                let _ = child.wait();
                                // scanner-anchor: "kind":"chumpd_worker_wedge_killed"
                                emit(
                                    &cfg,
                                    &format!(
                                        r#"{{"ts":"{}","kind":"chumpd_worker_wedge_killed","agent":{},"hb_age_s":{}}}"#,
                                        iso_now(),
                                        id,
                                        age
                                    ),
                                );
                                died = true;
                            }
                        }
                    }
                    Err(_) => died = true,
                }
            }
            if died {
                slot.child = None;
            }
        }

        // Scale down: kill children beyond desired (highest ids first) and
        // drop the slot entirely. RESILIENT-179 AC3: leaving a de-scaled
        // slot in the map (even with child=None) kept surfacing a stale
        // {pid: null, hb_age: ...} entry in chumpd-status.json forever —
        // remove() so write_status's iteration below never sees it again.
        let mut ids: Vec<usize> = slots.keys().copied().collect();
        ids.sort_unstable();
        for id in ids.iter().rev() {
            if *id > desired {
                if let Some(mut slot) = slots.remove(id) {
                    if let Some(child) = slot.child.as_mut() {
                        let _ = child.kill();
                        let _ = child.wait();
                    }
                }
            }
        }

        // Scale up / respawn to desired — gated on disk floor. Scale-down
        // above always runs (draining is never blocked by the gate).
        let now = now_epoch();
        for id in 1..=(if disk_gate_open { desired } else { 0 }) {
            let slot = slots.entry(id).or_insert(Slot {
                child: None,
                respawns: Vec::new(),
                broken: false,
            });
            if slot.broken || slot.child.is_some() {
                continue;
            }
            slot.respawns.retain(|t| now.saturating_sub(*t) < 3600);
            if slot.respawns.len() >= RESPAWN_STORM_PER_HOUR {
                slot.broken = true;
                // scanner-anchor: "kind":"chumpd_slot_broken"
                emit(
                    &cfg,
                    &format!(
                        r#"{{"ts":"{}","kind":"chumpd_slot_broken","agent":{},"respawns_last_hour":{},"escalated":true,"note":"persistent crash — slot parked, operator attention"}}"#,
                        iso_now(),
                        id,
                        slot.respawns.len()
                    ),
                );
                continue;
            }
            match spawn_worker(&cfg, id) {
                Ok(child) => {
                    // scanner-anchor: "kind":"chumpd_worker_spawned"
                    emit(
                        &cfg,
                        &format!(
                            r#"{{"ts":"{}","kind":"chumpd_worker_spawned","agent":{},"pid":{},"file_sandboxed":{}}}"#,
                            iso_now(),
                            id,
                            child.id(),
                            file_sandbox::worker_sandbox_enabled()
                        ),
                    );
                    slot.child = Some(child);
                    slot.respawns.push(now);
                }
                Err(e) => {
                    // scanner-anchor: "kind":"chumpd_spawn_failed"
                    emit(
                        &cfg,
                        &format!(
                            r#"{{"ts":"{}","kind":"chumpd_spawn_failed","agent":{},"error":"{}"}}"#,
                            iso_now(),
                            id,
                            e.to_string().replace('"', "'")
                        ),
                    );
                    slot.respawns.push(now);
                }
            }
        }

        write_status(&cfg, &mode, desired, &slots);
        scan_worker_sandbox_denials(&cfg, TICK_SECS);
        tokio::time::sleep(Duration::from_secs(TICK_SECS)).await;
    }

    // Graceful shutdown: take the children with us (launchd/systemd own OUR
    // restart). The disk-floor gate is implicitly closed the instant the
    // loop above exits — no spawn code runs again — so drain-then-report is
    // the whole sequence; no separate gate-close step is needed.
    let signal = SHUTDOWN_SIGNAL.load(Ordering::SeqCst);
    for slot in slots.values_mut() {
        if let Some(child) = slot.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    // scanner-anchor: "kind":"chumpd_stopped"
    emit(
        &cfg,
        &format!(
            r#"{{"ts":"{}","kind":"chumpd_stopped","signal":{},"note":"signal-triggered shutdown — disk-floor gate closed, all worker children drained"}}"#,
            iso_now(),
            signal
        ),
    );
    std::process::exit(exit_code_for_signal(signal));
}

#[cfg(test)]
mod signal_and_gate_tests {
    use super::*;

    #[test]
    fn build_jobs_scale_with_ram_and_clamp() {
        assert_eq!(derive_cargo_build_jobs(Some(24.0), 16), 10);
        assert_eq!(derive_cargo_build_jobs(Some(24.0), 4), 4);
        assert_eq!(derive_cargo_build_jobs(Some(1.0), 8), 1);
        assert_eq!(derive_cargo_build_jobs(None, 8), 4);
    }

    #[test]
    fn exit_code_zero_when_no_signal() {
        assert_eq!(exit_code_for_signal(0), 0);
    }

    #[test]
    fn exit_code_is_128_plus_signum_for_sigterm() {
        assert_eq!(exit_code_for_signal(chump_pal::SIGTERM_NUM), 143);
    }

    #[test]
    fn exit_code_is_128_plus_signum_for_sigint() {
        assert_eq!(exit_code_for_signal(chump_pal::SIGINT_NUM), 130);
    }

    #[test]
    fn disk_gate_open_when_measurement_unavailable() {
        assert!(disk_floor_gate_open(None, 5.0));
    }

    #[test]
    fn disk_gate_closes_below_threshold() {
        assert!(!disk_floor_gate_open(Some(2.0), 5.0));
    }

    #[test]
    fn disk_gate_open_above_threshold() {
        assert!(disk_floor_gate_open(Some(10.0), 5.0));
    }
}
