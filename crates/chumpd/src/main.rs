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

// ── MISSION-068: Hetzner substrate configuration ─────────────────────────
mod substrate {
    //! chumpd was born on macOS (Homebrew paths, sandbox-exec, launchd).
    //! Running on a Hetzner Linux host requires different paths, no
    //! sandbox-exec, and systemd-friendly signal handling. This module
    //! provides a single substrate-detection point so the rest of chumpd
    //! stays OS-agnostic.
    //!
    //! AC #1: Hetzner-specific infrastructure constants and config structures.
    //! AC #2: Substrate provider logic integrated into the MISSION init path.
    //! AC #3: Toggleable via `CHUMP_SUBSTRATE` env var or auto-detection.

    /// The substrate chumpd is running on.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Substrate {
        /// macOS (Apple Silicon or Intel) — the original target.
        MacOS,
        /// Hetzner Linux host (Ubuntu/Debian on dedicated or cloud).
        Hetzner,
    }

    impl Substrate {
        /// Detect the substrate from the environment or auto-detect from
        /// the OS.  `CHUMP_SUBSTRATE=hetzner` forces Hetzner;
        /// `CHUMP_SUBSTRATE=macos` forces macOS. Unset falls through to
        /// compile-time OS detection.
        pub fn detect() -> Self {
            if let Ok(v) = std::env::var("CHUMP_SUBSTRATE") {
                match v.to_lowercase().as_str() {
                    "hetzner" | "linux" => return Substrate::Hetzner,
                    "macos" | "darwin" => return Substrate::MacOS,
                    _ => { /* fall through to auto-detect */ }
                }
            }
            Self::auto()
        }

        fn auto() -> Self {
            if cfg!(target_os = "linux") {
                Substrate::Hetzner
            } else {
                Substrate::MacOS
            }
        }

        pub fn label(&self) -> &'static str {
            match self {
                Substrate::MacOS => "macos",
                Substrate::Hetzner => "hetzner",
            }
        }

        // ── AC #1: infrastructure constants ──────────────────────────

        /// Extra PATH entries prepended for the worker process.
        /// macOS needs Homebrew; Hetzner needs nothing beyond standard
        /// system paths (already in the base PATH).
        pub fn extra_path_entries(&self, home: &str) -> String {
            match self {
                Substrate::MacOS => {
                    format!("/opt/homebrew/bin:{home}/.local/bin:{home}/.cargo/bin",)
                }
                Substrate::Hetzner => format!("{home}/.local/bin:{home}/.cargo/bin",),
            }
        }

        /// Whether a process-level file sandbox is available.
        pub fn sandbox_available(&self) -> bool {
            matches!(self, Substrate::MacOS)
        }

        /// Path to the `tmux` binary (used by `takeover`).
        pub fn tmux_path(&self) -> &'static str {
            match self {
                Substrate::MacOS => "/opt/homebrew/bin/tmux",
                Substrate::Hetzner => "/usr/bin/tmux",
            }
        }

        /// Path to the `pkill` binary.
        pub fn pkill_path(&self) -> &'static str {
            "/usr/bin/pkill"
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn detect_respects_env_override() {
            unsafe {
                std::env::set_var("CHUMP_SUBSTRATE", "hetzner");
            }
            assert_eq!(Substrate::detect(), Substrate::Hetzner);
            unsafe {
                std::env::set_var("CHUMP_SUBSTRATE", "linux");
            }
            assert_eq!(Substrate::detect(), Substrate::Hetzner);
            unsafe {
                std::env::set_var("CHUMP_SUBSTRATE", "macos");
            }
            assert_eq!(Substrate::detect(), Substrate::MacOS);
            unsafe {
                std::env::remove_var("CHUMP_SUBSTRATE");
            }
        }

        #[test]
        fn hetzner_path_has_no_homebrew() {
            let s = Substrate::Hetzner;
            let extra = s.extra_path_entries("/home/chump");
            assert!(!extra.contains("homebrew"));
            assert!(extra.contains("/home/chump/.cargo/bin"));
        }

        #[test]
        fn macos_path_includes_homebrew() {
            let s = Substrate::MacOS;
            let extra = s.extra_path_entries("/Users/jeff");
            assert!(extra.contains("/opt/homebrew/bin"));
        }

        #[test]
        fn hetzner_has_no_sandbox() {
            assert!(!Substrate::Hetzner.sandbox_available());
        }

        #[test]
        fn macos_has_sandbox() {
            assert!(Substrate::MacOS.sandbox_available());
        }

        #[test]
        fn tmux_path_differs_by_substrate() {
            assert_eq!(Substrate::MacOS.tmux_path(), "/opt/homebrew/bin/tmux");
            assert_eq!(Substrate::Hetzner.tmux_path(), "/usr/bin/tmux");
        }

        #[test]
        fn label_is_stable() {
            assert_eq!(Substrate::MacOS.label(), "macos");
            assert_eq!(Substrate::Hetzner.label(), "hetzner");
        }
    }
}

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

extern "C" fn on_term(_sig: i32) {
    SHUTDOWN.store(true, Ordering::SeqCst);
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
    // chrono-free ISO8601: date -u equivalent via libc time would drag deps in;
    // epoch seconds are unambiguous and every consumer parses ts loosely.
    format!("epoch:{}", now_epoch())
}

#[derive(Clone)]
struct Config {
    repo: PathBuf,
    home: PathBuf,
    log_dir: PathBuf,
    /// MISSION-068: the substrate chumpd is running on (macOS or Hetzner).
    substrate: substrate::Substrate,
}

impl Config {
    fn load() -> Self {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()));
        let repo = std::env::var("CHUMP_REPO")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join("Projects/Chump"));
        let log_dir = PathBuf::from(format!("/tmp/chumpd-fleet-{}", now_epoch()));
        let substrate = substrate::Substrate::detect();
        Config {
            repo,
            home,
            log_dir,
            substrate,
        }
    }

    fn mode(&self) -> String {
        fs::read_to_string(self.home.join(".chump/fleet-mode"))
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "off".into())
    }

    fn desired_size(&self) -> usize {
        let from_file = fs::read_to_string(self.repo.join(".chump/fleet-desired-size"))
            .ok()
            .and_then(|s| s.trim().parse::<usize>().ok());
        match (from_file, self.mode().as_str()) {
            (Some(n), _) if n > 0 => n.min(8),
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
    std::env::var("CHUMP_HEARTBEAT_DIR").unwrap_or_else(|_| "/tmp".into())
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
    let path_env = format!(
        "{}:/usr/local/bin:/usr/bin:/bin",
        cfg.substrate
            .extra_path_entries(&cfg.home.display().to_string()),
    );

    // RESILIENT-178: workers run with the operator's full user file
    // authority by default (macOS TCC prompt, 2026-07-19 — a stray
    // find/grep reached an iCloud-synced path and the OS attributed the
    // access-request dialog to the operator). chumpd is the chokepoint
    // that spawns every worker, so it wraps the process in a sandbox-exec
    // profile scoped to repo + worktrees + tmp + toolchains, with the
    // known TCC-prompting surfaces explicitly denied. Structural fix, not
    // advisory prompt discipline.
    //
    // MISSION-068: sandbox is macOS-only; Hetzner workers run without it.
    let worktree_base = std::env::var("CHUMP_WORKTREE_BASE").ok().map(PathBuf::from);
    let sandboxed = cfg.substrate.sandbox_available() && file_sandbox::worker_sandbox_enabled();
    let mut command = if sandboxed {
        let profile =
            file_sandbox::build_worker_profile(&cfg.repo, worktree_base.as_deref(), &cfg.home);
        let mut c = Command::new("/usr/bin/sandbox-exec");
        c.arg("-p").arg(profile).arg("/bin/bash").arg(&worker);
        c
    } else {
        let mut c = Command::new("/bin/bash");
        c.arg(&worker);
        c
    };

    // MISSION-051 / RESILIENT-184: backend selection. CHUMPD_FLEET_BACKEND
    // lets an operator run the fleet on an open model (chump-local) instead
    // of the Claude subscription.
    let backend = std::env::var("CHUMPD_FLEET_BACKEND").unwrap_or_else(|_| "claude".into());
    // RESILIENT-184: the model/effort gate in _pick_and_claim_gap.py is
    // keyed on FLEET_MODEL. The sonnet default made chump-local (MiniMax-M3)
    // workers REFUSE xs gaps (sonnet-xs gate, "don't burn frontier tokens on
    // cleanup") while ACCEPTING m-effort gaps M3 can't finish — exactly
    // backwards. Open models want the haiku gate (blocks m/l/xl, allows
    // xs/s) and an xs,s effort filter. Frozen-picker symptom on chumpd-eu
    // 2026-07-22: 0 patches across cycles, all on m-effort/empty-desc gaps.
    let (fleet_model, effort_filter) = if backend == "chump-local" {
        ("haiku", "xs,s")
    } else {
        ("sonnet", "xs,s,m")
    };

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
        .env("FLEET_MODEL", fleet_model)
        .env("FLEET_SESSION", "chumpd")
        .env("FLEET_INLINE_BRIEFING", "1")
        .env("CHUMP_AGENT_HARNESS", "claude")
        .env("CARGO_TARGET_DIR", cfg.repo.join("target"))
        // Memory guard: concurrent rustc jobs are the machine's top RAM
        // consumers (~1.2GB each); 2 workers x default parallelism spikes
        // past what a 24GB laptop shares with the operator's apps.
        .env("CARGO_BUILD_JOBS", "4")
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
fn takeover(cfg: &Config) {
    // Test harness / cohabitation guard: CHUMPD_TAKEOVER=0 skips the global
    // sweep (a CI fixture must never pkill a live fleet's workers).
    if std::env::var("CHUMPD_TAKEOVER").as_deref() == Ok("0") {
        return;
    }
    let _ = Command::new(cfg.substrate.pkill_path())
        .args(["-f", "dispatch/worker.sh"])
        .status();
    let _ = Command::new("/bin/bash")
        .args([
            "-lc",
            &format!(
                "{} kill-session -t chump-fleet 2>/dev/null; true",
                cfg.substrate.tmux_path()
            ),
        ])
        .status();
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
    let tmp = "/tmp/chumpd-status.json.tmp";
    if fs::write(tmp, status.to_string()).is_ok() {
        let _ = fs::rename(tmp, "/tmp/chumpd-status.json");
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

async fn handle_socket(cfg: Config, listener: UnixListener) {
    loop {
        match listener.accept().await {
            Ok((mut stream, _)) => {
                let cfg = cfg.clone();
                tokio::spawn(async move {
                    let mut buf = [0u8; 1024];
                    match stream.read(&mut buf).await {
                        Ok(n) if n > 0 => {
                            if let Ok(req) = serde_json::from_slice::<RpcRequest>(&buf[..n]) {
                                let resp = match req {
                                    RpcRequest::Ping => RpcResponse {
                                        status: "pong".into(),
                                        db_path: None,
                                        status_json: None,
                                    },
                                    RpcRequest::DbPath => RpcResponse {
                                        status: "ok".into(),
                                        db_path: Some(
                                            cfg.repo.join(".chump/state.db").display().to_string(),
                                        ),
                                        status_json: None,
                                    },
                                    RpcRequest::Status => {
                                        let status_raw =
                                            fs::read_to_string("/tmp/chumpd-status.json")
                                                .unwrap_or_else(|_| "{}".into());
                                        let status_json = serde_json::from_str(&status_raw).ok();
                                        RpcResponse {
                                            status: "ok".into(),
                                            db_path: None,
                                            status_json,
                                        }
                                    }
                                };
                                let _ = stream
                                    .write_all(serde_json::to_string(&resp).unwrap().as_bytes())
                                    .await;
                            }
                        }
                        _ => {}
                    }
                });
            }
            Err(e) => {
                eprintln!("socket accept error: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

#[tokio::main]
async fn main() {
    // SAFETY: signal() with a signal-safe handler that only stores an atomic.
    unsafe {
        let handler = on_term as extern "C" fn(i32) as *const () as usize;
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
    }

    let cfg = Config::load();
    takeover(&cfg);

    // MISSION-052: Start Unix socket API.
    let socket_path = cfg.home.join(".chump/chumpd.sock");
    let _ = fs::remove_file(&socket_path);
    if let Ok(listener) = UnixListener::bind(&socket_path) {
        let cfg_clone = cfg.clone();
        tokio::spawn(async move {
            handle_socket(cfg_clone, listener).await;
        });
    }

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

    while !SHUTDOWN.load(Ordering::SeqCst) {
        let mode = cfg.mode();
        let desired = if mode == "off" { 0 } else { cfg.desired_size() };

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

        // Scale up / respawn to desired.
        let now = now_epoch();
        for id in 1..=desired {
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
        std::thread::sleep(Duration::from_secs(TICK_SECS));
    }

    // Graceful shutdown: take the children with us (launchd owns OUR restart).
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
            r#"{{"ts":"{}","kind":"chumpd_stopped","note":"SIGTERM — children stopped with supervisor"}}"#,
            iso_now()
        ),
    );
}
