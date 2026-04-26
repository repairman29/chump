use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::repo_path;

static AUTOPILOT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

/// Pause auto-reconcile for this long after this many consecutive failures.
const MAX_CONSECUTIVE_START_FAILURES: u32 = 3;
const AUTO_RETRY_PAUSE_SECS: u64 = 3600;

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn lock() -> &'static Mutex<()> {
    AUTOPILOT_LOCK.get_or_init(|| Mutex::new(()))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutopilotState {
    pub desired_enabled: bool,
    pub actual_state: String, // running | starting | stopped | error
    pub run_id: Option<String>,
    pub pid: Option<i32>,
    pub started_at_secs: Option<u64>,
    pub last_heartbeat_log_ts: Option<u64>,
    pub last_error: Option<String>,
    pub updated_at_secs: u64,
    /// Incremented on failed start (preflight or shell); cleared on success or user start.
    #[serde(default)]
    pub consecutive_start_failures: u32,
    /// When set and `now < this`, auto-reconcile skips start attempts.
    #[serde(default)]
    pub auto_retry_paused_until_secs: Option<u64>,
}

impl Default for AutopilotState {
    fn default() -> Self {
        Self {
            desired_enabled: false,
            actual_state: "stopped".to_string(),
            run_id: None,
            pid: None,
            started_at_secs: None,
            last_heartbeat_log_ts: None,
            last_error: None,
            updated_at_secs: now_secs(),
            consecutive_start_failures: 0,
            auto_retry_paused_until_secs: None,
        }
    }
}

fn clear_backoff(state: &mut AutopilotState) {
    state.consecutive_start_failures = 0;
    state.auto_retry_paused_until_secs = None;
}

fn record_start_failure(state: &mut AutopilotState) {
    state.consecutive_start_failures = state.consecutive_start_failures.saturating_add(1);
    if state.consecutive_start_failures >= MAX_CONSECUTIVE_START_FAILURES {
        state.auto_retry_paused_until_secs = Some(now_secs() + AUTO_RETRY_PAUSE_SECS);
    }
    state.updated_at_secs = now_secs();
}

fn runtime_base() -> std::path::PathBuf {
    repo_path::runtime_base()
}

fn logs_dir() -> std::path::PathBuf {
    runtime_base().join("logs")
}

fn state_path() -> std::path::PathBuf {
    logs_dir().join("autopilot-state.json")
}

fn events_path() -> std::path::PathBuf {
    logs_dir().join("autopilot-events.jsonl")
}

fn ship_log_path() -> std::path::PathBuf {
    logs_dir().join("heartbeat-ship.log")
}

fn ship_lock_path() -> std::path::PathBuf {
    logs_dir().join("heartbeat-ship.lock")
}

fn ensure_logs_dir() -> Result<()> {
    std::fs::create_dir_all(logs_dir())?;
    Ok(())
}

fn read_state() -> AutopilotState {
    let path = state_path();
    match std::fs::read_to_string(&path) {
        Ok(s) => serde_json::from_str::<AutopilotState>(&s).unwrap_or_default(),
        Err(_) => AutopilotState::default(),
    }
}

fn write_state(state: &AutopilotState) -> Result<()> {
    ensure_logs_dir()?;
    let path = state_path();
    let s = serde_json::to_string_pretty(state)?;
    std::fs::write(path, s)?;
    Ok(())
}

fn append_event(kind: &str, details: serde_json::Value) {
    let _ = ensure_logs_dir();
    let payload = serde_json::json!({
        "ts": now_secs(),
        "kind": kind,
        "details": details
    });
    if let Ok(line) = serde_json::to_string(&payload) {
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(events_path())
            .and_then(|mut f| {
                use std::io::Write;
                writeln!(f, "{}", line)
            });
    }
}

fn append_ship_marker(marker: &str, details: &str) {
    let line = format!("[{}] AUTOPILOT {} {}", now_secs(), marker, details);
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ship_log_path())
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(f, "{}", line)
        });
}

fn pid_alive(pid: i32) -> bool {
    Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn kill_ship_pid_graceful(pid: i32) {
    let _ = Command::new("/bin/kill")
        .args(["-TERM", &pid.to_string()])
        .status();
    thread::sleep(Duration::from_secs(2));
    if pid_alive(pid) {
        let _ = Command::new("/bin/kill")
            .args(["-9", &pid.to_string()])
            .status();
    }
}

fn pkill_ship_fallback() {
    let _ = Command::new("pkill")
        .args(["-f", "heartbeat-ship.sh"])
        .status();
}

fn discover_ship_pid() -> Option<i32> {
    // Prefer lock file pid if valid.
    let lock_path = ship_lock_path();
    if let Ok(s) = std::fs::read_to_string(&lock_path) {
        if let Ok(pid) = s.trim().parse::<i32>() {
            if pid_alive(pid) {
                return Some(pid);
            }
        }
    }
    // Fallback to pgrep first result.
    let out = Command::new("pgrep")
        .args(["-f", "heartbeat-ship.sh"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let txt = String::from_utf8_lossy(&out.stdout);
    txt.lines().find_map(|l| l.trim().parse::<i32>().ok())
}

fn parse_last_round() -> Option<serde_json::Value> {
    let text = std::fs::read_to_string(ship_log_path()).ok()?;
    for line in text.lines().rev() {
        let line = line.trim();
        let round_pos = match line.find("Round ") {
            Some(p) => p,
            None => continue,
        };
        let rest = line[round_pos + 6..].trim_start();
        let num_end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(0);
        if num_end == 0 {
            continue;
        }
        let round = rest[..num_end].trim();
        let rest = rest[num_end..].trim_start();
        if !rest.starts_with('(') {
            continue;
        }
        let right = rest.find(')')?;
        let round_type = rest[1..right].trim();
        let status_raw = rest[right + 1..].trim();
        return Some(serde_json::json!({
            "round": round,
            "round_type": round_type,
            "status": status_raw
        }));
    }
    None
}

fn last_ship_log_mtime_secs() -> Option<u64> {
    let md = std::fs::metadata(ship_log_path()).ok()?;
    md.modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

fn run_shell_start() -> Result<()> {
    let root = runtime_base();
    let root_s = root.to_string_lossy();
    let cmd = format!(
        "cd '{}' && source .env 2>/dev/null || true; \
CHUMP_AUTOPILOT=1 AUTOPILOT_SLEEP_SECS=5 HEARTBEAT_INTERVAL=5s HEARTBEAT_DURATION=8h \
bash scripts/setup/ensure-ship-heartbeat.sh",
        root_s.replace('\'', "'\\''")
    );
    let out = Command::new("/bin/bash")
        .args(["-lc", &cmd])
        .output()
        .map_err(|e| anyhow!("start command failed: {}", e))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).to_string();
        let out = String::from_utf8_lossy(&out.stdout).to_string();
        return Err(anyhow!(
            "autopilot start failed: {}{}{}",
            err.trim(),
            if !err.is_empty() && !out.is_empty() {
                " | "
            } else {
                ""
            },
            out.trim()
        ));
    }
    Ok(())
}

fn run_preflight() -> Result<()> {
    let root = runtime_base();
    let root_s = root.to_string_lossy();
    let cmd = format!(
        "cd '{}' && source .env 2>/dev/null || true; scripts/ci/check-heartbeat-preflight.sh",
        root_s.replace('\'', "'\\''")
    );
    let out = Command::new("/bin/bash")
        .args(["-lc", &cmd])
        .output()
        .map_err(|e| anyhow!("preflight failed to execute: {}", e))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).to_string();
        let stdout = String::from_utf8_lossy(&out.stdout).to_string();
        let msg = format!(
            "{}{}{}",
            stdout.trim(),
            if !stdout.trim().is_empty() && !err.trim().is_empty() {
                " | "
            } else {
                ""
            },
            err.trim()
        );
        return Err(anyhow!("preflight failed: {}", msg.trim()));
    }
    Ok(())
}

/// User/API: clears backoff, then starts if needed.
pub fn start_autopilot() -> Result<AutopilotState> {
    let _guard = lock()
        .lock()
        .map_err(|_| anyhow!("autopilot lock poisoned"))?;
    let mut state = read_state();
    clear_backoff(&mut state);
    write_state(&state)?;
    start_autopilot_locked_after_backoff_clear(&mut state)
}

/// Auto-reconcile: only if `desired_enabled`, ship down, and not in pause window.
/// Returns `Ok(None)` if no action taken.
pub fn reconcile_autopilot_maybe_start() -> Result<Option<AutopilotState>> {
    let _guard = lock()
        .lock()
        .map_err(|_| anyhow!("autopilot lock poisoned"))?;
    let mut state = read_state();
    if !state.desired_enabled {
        return Ok(None);
    }
    if discover_ship_pid().is_some() {
        return Ok(None);
    }
    if let Some(until) = state.auto_retry_paused_until_secs {
        if now_secs() < until {
            return Ok(None);
        }
        clear_backoff(&mut state);
        write_state(&state)?;
    }
    Ok(Some(start_autopilot_locked_after_backoff_clear(
        &mut state,
    )?))
}

fn start_autopilot_locked_after_backoff_clear(
    state: &mut AutopilotState,
) -> Result<AutopilotState> {
    if let Some(pid) = discover_ship_pid() {
        state.desired_enabled = true;
        state.pid = Some(pid);
        state.actual_state = "running".to_string();
        state.last_error = None;
        clear_backoff(state);
        state.updated_at_secs = now_secs();
        write_state(state)?;
        return Ok(state.clone());
    }

    if let Err(e) = run_preflight() {
        record_start_failure(state);
        state.updated_at_secs = now_secs();
        write_state(state)?;
        append_event(
            "autopilot_preflight_failed",
            serde_json::json!({ "error": e.to_string() }),
        );
        return Err(e);
    }

    state.desired_enabled = true;
    state.actual_state = "starting".to_string();
    state.updated_at_secs = now_secs();
    write_state(state)?;

    if let Err(e) = run_shell_start() {
        state.actual_state = "error".to_string();
        state.last_error = Some(e.to_string());
        record_start_failure(state);
        state.updated_at_secs = now_secs();
        let _ = write_state(state);
        append_event(
            "autopilot_start_failed",
            serde_json::json!({ "error": e.to_string() }),
        );
        append_ship_marker("START_FAILED", &e.to_string());
        return Err(e);
    }

    let pid = discover_ship_pid();
    let run_id = format!("ship-{}", now_secs());
    state.pid = pid;
    state.run_id = Some(run_id.clone());
    state.started_at_secs = Some(now_secs());
    state.last_heartbeat_log_ts = last_ship_log_mtime_secs();
    state.actual_state = if pid.is_some() {
        "running".to_string()
    } else {
        "error".to_string()
    };
    state.last_error = if pid.is_some() {
        None
    } else {
        Some("ship process did not stay up after start".to_string())
    };
    state.updated_at_secs = now_secs();
    if pid.is_none() {
        record_start_failure(state);
    } else {
        clear_backoff(state);
    }
    write_state(state)?;

    if pid.is_some() {
        append_ship_marker(
            "STARTED",
            &format!("run_id={} pid={}", run_id, state.pid.unwrap_or_default()),
        );
        append_event(
            "autopilot_started",
            serde_json::json!({ "run_id": run_id, "pid": state.pid }),
        );
        Ok(state.clone())
    } else {
        Err(anyhow!("ship process did not stay up after start",))
    }
}

pub fn stop_autopilot() -> Result<AutopilotState> {
    let _guard = lock()
        .lock()
        .map_err(|_| anyhow!("autopilot lock poisoned"))?;
    let mut state = read_state();
    let pid = discover_ship_pid();
    if let Some(p) = pid {
        kill_ship_pid_graceful(p);
    } else {
        pkill_ship_fallback();
    }
    let _ = std::fs::remove_file(ship_lock_path());
    state.desired_enabled = false;
    state.actual_state = "stopped".to_string();
    state.pid = None;
    state.last_error = None;
    clear_backoff(&mut state);
    state.updated_at_secs = now_secs();
    state.last_heartbeat_log_ts = last_ship_log_mtime_secs();
    write_state(&state)?;
    append_ship_marker("STOPPED", "requested_by_api");
    append_event("autopilot_stopped", serde_json::json!({}));
    Ok(state)
}

pub fn status_autopilot() -> Result<serde_json::Value> {
    let _guard = lock()
        .lock()
        .map_err(|_| anyhow!("autopilot lock poisoned"))?;
    let mut state = read_state();
    let live_pid = discover_ship_pid();
    let running = live_pid.is_some();

    // Reconcile persisted state with runtime truth.
    state.pid = live_pid;
    state.last_heartbeat_log_ts = last_ship_log_mtime_secs();
    state.updated_at_secs = now_secs();
    if running {
        state.actual_state = "running".to_string();
        state.last_error = None;
    } else if state.desired_enabled {
        state.actual_state = "error".to_string();
        if state.last_error.is_none() {
            state.last_error =
                Some("autopilot desired enabled but ship process is not running".to_string());
        }
    } else {
        state.actual_state = "stopped".to_string();
    }
    write_state(&state)?;

    // tail event log (last 10)
    let recent_events: Vec<serde_json::Value> = std::fs::read_to_string(events_path())
        .ok()
        .map(|s| {
            let mut lines: Vec<&str> = s.lines().collect();
            if lines.len() > 10 {
                lines = lines.split_off(lines.len() - 10);
            }
            lines
                .into_iter()
                .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    Ok(serde_json::json!({
        "desired_enabled": state.desired_enabled,
        "actual_state": state.actual_state,
        "run_id": state.run_id,
        "pid": state.pid,
        "started_at_secs": state.started_at_secs,
        "last_heartbeat_log_ts": state.last_heartbeat_log_ts,
        "last_error": state.last_error,
        "updated_at_secs": state.updated_at_secs,
        "consecutive_start_failures": state.consecutive_start_failures,
        "auto_retry_paused_until_secs": state.auto_retry_paused_until_secs,
        "ship_running": running,
        "ship_summary": parse_last_round(),
        "recent_events": recent_events
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_increments_and_pauses_at_threshold() {
        let mut s = AutopilotState::default();
        for i in 1..MAX_CONSECUTIVE_START_FAILURES {
            record_start_failure(&mut s);
            assert_eq!(s.consecutive_start_failures, i);
            assert!(s.auto_retry_paused_until_secs.is_none());
        }
        record_start_failure(&mut s);
        assert_eq!(s.consecutive_start_failures, MAX_CONSECUTIVE_START_FAILURES);
        assert!(s.auto_retry_paused_until_secs.is_some());
        let until = s.auto_retry_paused_until_secs.unwrap();
        assert!(until > now_secs());
    }

    #[test]
    fn clear_backoff_resets() {
        let mut s = AutopilotState::default();
        record_start_failure(&mut s);
        record_start_failure(&mut s);
        record_start_failure(&mut s);
        assert!(s.auto_retry_paused_until_secs.is_some());
        clear_backoff(&mut s);
        assert_eq!(s.consecutive_start_failures, 0);
        assert!(s.auto_retry_paused_until_secs.is_none());
    }
}
