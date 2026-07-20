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

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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

struct Config {
    repo: PathBuf,
    home: PathBuf,
    log_dir: PathBuf,
}

impl Config {
    fn load() -> Self {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()));
        let repo = std::env::var("CHUMP_REPO")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join("Projects/Chump"));
        let log_dir = PathBuf::from(format!("/tmp/chumpd-fleet-{}", now_epoch()));
        Config {
            repo,
            home,
            log_dir,
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
        "/opt/homebrew/bin:{}/.local/bin:{}/.cargo/bin:/usr/local/bin:/usr/bin:/bin",
        cfg.home.display(),
        cfg.home.display()
    );

    Command::new("/bin/bash")
        .arg(&worker)
        .current_dir(&cfg.repo)
        .env("PATH", path_env)
        .env("HOME", &cfg.home)
        .env("REPO_ROOT", &cfg.repo)
        .env("CHUMP_REPO", &cfg.repo)
        .env("FLEET_LOCKS_DIR", cfg.repo.join(".chump-locks"))
        .env("FLEET_LOG_DIR", &cfg.log_dir)
        .env("FLEET_TIMEOUT_S", "1800")
        .env("FLEET_PRIORITY_FILTER", "P0,P1")
        .env("FLEET_EFFORT_FILTER", "xs,s,m")
        .env("FLEET_BACKEND", "claude")
        .env("FLEET_MODEL", "sonnet")
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
fn takeover(_cfg: &Config) {
    // Test harness / cohabitation guard: CHUMPD_TAKEOVER=0 skips the global
    // sweep (a CI fixture must never pkill a live fleet's workers).
    if std::env::var("CHUMPD_TAKEOVER").as_deref() == Ok("0") {
        return;
    }
    let _ = Command::new("/usr/bin/pkill")
        .args(["-f", "dispatch/worker.sh"])
        .status();
    let _ = Command::new("/bin/bash")
        .args([
            "-lc",
            "/opt/homebrew/bin/tmux kill-session -t chump-fleet 2>/dev/null; true",
        ])
        .status();
}

struct Slot {
    child: Option<Child>,
    respawns: Vec<u64>,
    broken: bool,
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

fn main() {
    // SAFETY: signal() with a signal-safe handler that only stores an atomic.
    unsafe {
        let handler = on_term as extern "C" fn(i32) as *const () as usize;
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
    }

    let cfg = Config::load();
    takeover(&cfg);
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

        // Scale down: kill children beyond desired (highest ids first).
        let mut ids: Vec<usize> = slots.keys().copied().collect();
        ids.sort_unstable();
        for id in ids.iter().rev() {
            if *id > desired {
                if let Some(slot) = slots.get_mut(id) {
                    if let Some(child) = slot.child.as_mut() {
                        let _ = child.kill();
                        let _ = child.wait();
                    }
                    slot.child = None;
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
                            r#"{{"ts":"{}","kind":"chumpd_worker_spawned","agent":{},"pid":{}}}"#,
                            iso_now(),
                            id,
                            child.id()
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
        std::thread::sleep(Duration::from_secs(TICK_SECS));
    }

    // Graceful shutdown: take the children with us (launchd owns OUR restart).
    for (_, slot) in slots.iter_mut() {
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
