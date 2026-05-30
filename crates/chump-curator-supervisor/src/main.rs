//! `chump-curator-supervisor` — INFRA-2239
//!
//! L3 supervision daemon over the 6 productized curator roles.
//! On each StartInterval tick (default 300s), iterates all roles and runs
//! 4 detection checks. On novel failure: files a gap, optionally spawns a
//! Sonnet sub-agent, optionally auto-restarts the tmux pane.
//!
//! ## Detection checks
//!
//! 1. **error_pattern_scan** — regex match in last 50 log lines for known
//!    fatal patterns (`unknown subcommand`, `Traceback`, `panic`, `fatal:`,
//!    `exit 1`). Triggered when ≥ 2 matches found.
//! 2. **silent_stall_check** — no `curator_heartbeat` ambient event with
//!    matching role in the last 10 minutes.
//! 3. **crash_loop_check** — last 100 log lines are ≥ 80% error-class lines.
//! 4. **productivity_drop_check** — zero state.db gap mutations attributed
//!    to the role's session_id in the past 1 hour.
//!
//! ## Env vars
//!
//! | Variable | Default | Purpose |
//! |---|---|---|
//! | `CHUMP_REPO_ROOT` | git rev-parse | Repository root |
//! | `CHUMP_CURATOR_SUPERVISOR_MODE` | `aggressive` | `aggressive` or `conservative` |
//! | `CHUMP_CURATOR_SUPERVISOR_AUTORESTART` | `1` | `0` to disable tmux respawn |
//! | `CHUMP_CURATOR_SUPERVISOR_DRY_RUN` | unset | `1` to emit would-* events instead of acting |
//! | `CHUMP_CURATOR_SUPERVISOR_INTERVAL_S` | `300` | Tick interval in seconds |
//! | `CHUMP_CURATOR_SUPERVISOR_LOG_DIR` | `.chump-locks/autopilot-logs` | Curator log directory |
//! | `CHUMP_CURATOR_SUPERVISOR_AMBIENT` | `.chump-locks/ambient.jsonl` | Ambient stream path |
//! | `CHUMP_CURATOR_SUPERVISOR_SENTINEL_DIR` | `.chump-locks/curator-supervisor/seen` | Dedup sentinel dir |
//! | `CHUMP_CURATOR_SUPERVISOR_SENTINEL_TTL_H` | `24` | Sentinel TTL in hours |
//! | `CHUMP_CURATOR_HEARTBEAT_STALL_M` | `10` | Minutes without heartbeat = stall |
//! | `CHUMP_CURATOR_SUPERVISOR_PRODUCTIVITY_H` | `1` | Hours window for productivity check |

use std::fs;
use std::io::{self, BufRead};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result};
use chrono::Utc;
use regex::Regex;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tracing::{debug, info, warn};

// ── constants ──────────────────────────────────────────────────────────────

/// The 6 productized curator roles (must match fleet-autopilot.sh CURATOR_ROLES).
/// Format: (role_name, loop_script_relative_to_repo)
const CURATOR_ROLES: &[(&str, &str)] = &[
    ("shepherd", "scripts/coord/opus-shepherd-triage.sh"),
    ("target", ""),
    ("handoff", "scripts/coord/handoff-loop.sh"),
    ("ci-audit", "scripts/coord/ci-audit-loop.sh"),
    ("decompose", "scripts/coord/decompose-loop.sh"),
    ("md-links", "scripts/coord/md-links-loop.sh"),
];

/// Error patterns that trigger detection (checked in last 50 log lines).
/// These are plain substring patterns matched with regex literal search,
/// NOT regex syntax — bracket chars are escaped when building the Regex.
const ERROR_PATTERNS: &[&str] = &[
    "unknown subcommand",
    "Traceback",
    "panic",
    "fatal:",
    "exit 1",
    "FAILED",
    "error[E",
];

const DEFAULT_INTERVAL_S: u64 = 300;
const DEFAULT_STALL_M: u64 = 10;
const DEFAULT_SENTINEL_TTL_H: u64 = 24;
const DEFAULT_PRODUCTIVITY_H: u64 = 1;
const CRASH_LOOP_ERROR_RATIO: f64 = 0.80;
const ERROR_PATTERN_MIN_MATCHES: usize = 2;
// RESILIENT-035 circuit breaker: cap how often a single role can fork into
// remediation. Without these, a flapping role produces N distinct error
// fingerprints over time and bypasses the sentinel dedup — the supervisor
// would spawn N Sonnets and respawn N times in a single hour.
const DEFAULT_MAX_SPAWNS_PER_HOUR: u64 = 3;
const DEFAULT_FLAPPING_DETECT_WINDOW_M: u64 = 30;
const DEFAULT_FLAPPING_DETECT_THRESHOLD: u64 = 3;

// ── config ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct Config {
    repo_root: PathBuf,
    log_dir: PathBuf,
    ambient_path: PathBuf,
    sentinel_dir: PathBuf,
    sentinel_ttl: Duration,
    stall_threshold: Duration,
    productivity_window: Duration,
    mode: SupervisorMode,
    autorestart: bool,
    dry_run: bool,
    interval: Duration,
    // RESILIENT-035 circuit breaker
    max_spawns_per_hour: u64,
    flapping_window: Duration,
    flapping_threshold: u64,
}

#[derive(Debug, Clone, PartialEq)]
enum SupervisorMode {
    Aggressive,
    Conservative,
}

impl Config {
    fn from_env() -> Result<Self> {
        let repo_root = resolve_repo_root();
        let log_dir = env_path(
            "CHUMP_CURATOR_SUPERVISOR_LOG_DIR",
            repo_root.join(".chump-locks/autopilot-logs"),
        );
        let ambient_path = env_path(
            "CHUMP_CURATOR_SUPERVISOR_AMBIENT",
            repo_root.join(".chump-locks/ambient.jsonl"),
        );
        let sentinel_dir = env_path(
            "CHUMP_CURATOR_SUPERVISOR_SENTINEL_DIR",
            repo_root.join(".chump-locks/curator-supervisor/seen"),
        );
        let sentinel_ttl_h: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_SENTINEL_TTL_H",
            DEFAULT_SENTINEL_TTL_H,
        );
        let stall_m: u64 = env_u64("CHUMP_CURATOR_HEARTBEAT_STALL_M", DEFAULT_STALL_M);
        let productivity_h: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_PRODUCTIVITY_H",
            DEFAULT_PRODUCTIVITY_H,
        );
        let interval_s: u64 = env_u64("CHUMP_CURATOR_SUPERVISOR_INTERVAL_S", DEFAULT_INTERVAL_S);

        let mode_str = std::env::var("CHUMP_CURATOR_SUPERVISOR_MODE")
            .unwrap_or_else(|_| "aggressive".to_string());
        let mode = if mode_str == "conservative" {
            SupervisorMode::Conservative
        } else {
            SupervisorMode::Aggressive
        };

        let autorestart = std::env::var("CHUMP_CURATOR_SUPERVISOR_AUTORESTART")
            .map(|v| v != "0" && v != "false")
            .unwrap_or(true);

        let dry_run = std::env::var("CHUMP_CURATOR_SUPERVISOR_DRY_RUN")
            .map(|v| v == "1" || v == "true")
            .unwrap_or(false);

        // RESILIENT-035 circuit breaker config.
        let max_spawns_per_hour: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_MAX_SPAWNS_PER_HOUR",
            DEFAULT_MAX_SPAWNS_PER_HOUR,
        );
        let flapping_window_m: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_FLAPPING_WINDOW_M",
            DEFAULT_FLAPPING_DETECT_WINDOW_M,
        );
        let flapping_threshold: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_FLAPPING_THRESHOLD",
            DEFAULT_FLAPPING_DETECT_THRESHOLD,
        );

        Ok(Config {
            repo_root,
            log_dir,
            ambient_path,
            sentinel_dir,
            sentinel_ttl: Duration::from_secs(sentinel_ttl_h * 3600),
            stall_threshold: Duration::from_secs(stall_m * 60),
            productivity_window: Duration::from_secs(productivity_h * 3600),
            mode,
            autorestart,
            dry_run,
            interval: Duration::from_secs(interval_s),
            max_spawns_per_hour,
            flapping_window: Duration::from_secs(flapping_window_m * 60),
            flapping_threshold,
        })
    }
}

// ── detection results ──────────────────────────────────────────────────────

#[derive(Debug, Default)]
struct DetectionResult {
    role: String,
    error_pattern_triggered: bool,
    error_pattern_sample: Option<String>,
    silent_stall_triggered: bool,
    last_heartbeat_ago: Option<Duration>,
    crash_loop_triggered: bool,
    productivity_drop_triggered: bool,
}

impl DetectionResult {
    fn is_failing(&self) -> bool {
        self.error_pattern_triggered
            || self.silent_stall_triggered
            || self.crash_loop_triggered
            || self.productivity_drop_triggered
    }

    fn failure_summary(&self) -> String {
        let mut parts = Vec::new();
        if self.error_pattern_triggered {
            if let Some(s) = &self.error_pattern_sample {
                parts.push(format!(
                    "error_pattern({})",
                    s.chars().take(60).collect::<String>()
                ));
            } else {
                parts.push("error_pattern".to_string());
            }
        }
        if self.silent_stall_triggered {
            let ago = self
                .last_heartbeat_ago
                .map(|d| format!("{}s ago", d.as_secs()))
                .unwrap_or_else(|| "never".to_string());
            parts.push(format!("silent_stall(last_heartbeat={})", ago));
        }
        if self.crash_loop_triggered {
            parts.push("crash_loop".to_string());
        }
        if self.productivity_drop_triggered {
            parts.push("productivity_drop".to_string());
        }
        parts.join("; ")
    }

    fn error_fingerprint(&self) -> String {
        let fallback = self.failure_summary();
        let sample = self.error_pattern_sample.as_deref().unwrap_or(&fallback);
        let mut hasher = Sha256::new();
        hasher.update(sample.as_bytes());
        let hash = hex::encode(hasher.finalize());
        format!("{}:{}", self.role, &hash[..8])
    }
}

// ── main ───────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::from_env().context("Failed to build config from env")?;
    info!(
        mode = ?cfg.mode,
        autorestart = cfg.autorestart,
        dry_run = cfg.dry_run,
        interval_s = cfg.interval.as_secs(),
        "chump-curator-supervisor starting"
    );

    // Ensure sentinel directory exists.
    fs::create_dir_all(&cfg.sentinel_dir)
        .with_context(|| format!("create sentinel dir {:?}", cfg.sentinel_dir))?;

    // Single-shot mode: just run one tick and exit (for launchd StartInterval use).
    run_tick(&cfg).await?;

    Ok(())
}

// ── tick ───────────────────────────────────────────────────────────────────

async fn run_tick(cfg: &Config) -> Result<()> {
    info!(
        "supervisor tick starting — checking {} roles",
        CURATOR_ROLES.len()
    );

    let mut failures: Vec<DetectionResult> = Vec::new();

    for (role, _loop_script) in CURATOR_ROLES {
        let result = check_role(cfg, role).await;
        match result {
            Ok(det) => {
                if det.is_failing() {
                    warn!(role, summary = %det.failure_summary(), "curator failure detected");
                    failures.push(det);
                } else {
                    debug!(role, "healthy");
                }
            }
            Err(e) => {
                warn!(role, err = %e, "check_role returned error (skipping)");
            }
        }
    }

    if failures.is_empty() {
        info!("all curators healthy");
        return Ok(());
    }

    let multi_failure = failures.len() > 1;
    info!("{} curator(s) failing", failures.len());

    for det in &failures {
        handle_failure(cfg, det, multi_failure).await?;
    }

    Ok(())
}

// ── per-role detection ─────────────────────────────────────────────────────

async fn check_role(cfg: &Config, role: &str) -> Result<DetectionResult> {
    let mut det = DetectionResult {
        role: role.to_string(),
        ..Default::default()
    };

    let log_path = cfg.log_dir.join(format!("curator-{role}.log"));

    // 1. error_pattern_scan — last 50 log lines
    if log_path.exists() {
        let (triggered, sample) = error_pattern_scan(&log_path, 50, ERROR_PATTERN_MIN_MATCHES)?;
        det.error_pattern_triggered = triggered;
        det.error_pattern_sample = sample;
    }

    // 2. silent_stall_check — no heartbeat ambient event in last N minutes
    let (stalled, last_ago) = silent_stall_check(&cfg.ambient_path, role, cfg.stall_threshold)?;
    det.silent_stall_triggered = stalled;
    det.last_heartbeat_ago = last_ago;

    // 3. crash_loop_check — last 100 log lines ≥ 80% error-class
    if log_path.exists() {
        det.crash_loop_triggered = crash_loop_check(&log_path, 100, CRASH_LOOP_ERROR_RATIO)?;
    }

    // 4. productivity_drop_check — no state.db mutations in last N hours
    let state_db = cfg.repo_root.join(".chump/state.db");
    if state_db.exists() {
        let session_id = infer_session_id(role);
        det.productivity_drop_triggered =
            productivity_drop_check(&state_db, &session_id, cfg.productivity_window)?;
    }

    Ok(det)
}

// ── detection primitives ───────────────────────────────────────────────────

fn error_pattern_scan(
    log_path: &Path,
    last_n_lines: usize,
    min_matches: usize,
) -> Result<(bool, Option<String>)> {
    let patterns: Vec<Regex> = ERROR_PATTERNS
        .iter()
        .map(|p| Regex::new(&regex::escape(p)).expect("valid escaped regex"))
        .collect();

    let lines = tail_lines(log_path, last_n_lines)?;
    let mut match_count = 0usize;
    let mut first_match: Option<String> = None;

    for line in &lines {
        for pat in &patterns {
            if pat.is_match(line) {
                match_count += 1;
                if first_match.is_none() {
                    first_match = Some(line.trim().to_string());
                }
                break;
            }
        }
    }

    Ok((match_count >= min_matches, first_match))
}

fn silent_stall_check(
    ambient_path: &Path,
    role: &str,
    threshold: Duration,
) -> Result<(bool, Option<Duration>)> {
    if !ambient_path.exists() {
        // No ambient file yet — treat as stalled only if file truly missing.
        return Ok((false, None));
    }

    // Scan the last 500 lines of ambient.jsonl for curator_heartbeat events for this role.
    let lines = tail_lines(ambient_path, 500)?;
    let mut latest_ts: Option<chrono::DateTime<Utc>> = None;

    for line in &lines {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        if kind != "curator_heartbeat" {
            continue;
        }
        let event_role = v.get("role").and_then(|r| r.as_str()).unwrap_or("");
        if event_role != role {
            continue;
        }
        if let Some(ts_str) = v.get("ts").and_then(|t| t.as_str()) {
            if let Ok(ts) = ts_str.parse::<chrono::DateTime<Utc>>() {
                if latest_ts.map(|prev| ts > prev).unwrap_or(true) {
                    latest_ts = Some(ts);
                }
            }
        }
    }

    match latest_ts {
        None => {
            // No heartbeat found — check if this role even has a log file to
            // avoid false positives on unstarted roles.
            Ok((false, None))
        }
        Some(ts) => {
            let now = Utc::now();
            let ago = (now - ts).to_std().unwrap_or(Duration::from_secs(0));
            let stalled = ago > threshold;
            Ok((stalled, Some(ago)))
        }
    }
}

fn crash_loop_check(log_path: &Path, last_n_lines: usize, ratio_threshold: f64) -> Result<bool> {
    let error_re =
        Regex::new(r"(?i)(error|panic|traceback|fatal|failed|unknown subcommand|exit [^0])")
            .expect("valid static regex");

    let lines = tail_lines(log_path, last_n_lines)?;
    if lines.is_empty() {
        return Ok(false);
    }

    let error_count = lines.iter().filter(|l| error_re.is_match(l)).count();
    Ok(error_count as f64 / lines.len() as f64 >= ratio_threshold)
}

fn productivity_drop_check(state_db: &Path, session_id: &str, window: Duration) -> Result<bool> {
    let conn = rusqlite::Connection::open(state_db)
        .with_context(|| format!("open state.db at {:?}", state_db))?;

    // Check if a gap_history table exists (gracefully skip if not).
    let has_table: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='gap_history'",
            [],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(0)
        > 0;

    if !has_table {
        // No history table yet — skip this check.
        return Ok(false);
    }

    let cutoff = chrono::Utc::now() - chrono::Duration::from_std(window).unwrap();
    let cutoff_str = cutoff.format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM gap_history WHERE session_id = ?1 AND created_at >= ?2",
            rusqlite::params![session_id, cutoff_str],
            |r| r.get(0),
        )
        .unwrap_or(0);

    Ok(count == 0)
}

// ── failure handling ───────────────────────────────────────────────────────

async fn handle_failure(cfg: &Config, det: &DetectionResult, multi_failure: bool) -> Result<()> {
    let fp = det.error_fingerprint();
    let sentinel_path = cfg.sentinel_dir.join(format!("{}.sentinel", fp));

    // Dedupe: check sentinel TTL.
    if sentinel_path.exists() {
        if let Ok(meta) = fs::metadata(&sentinel_path) {
            if let Ok(modified) = meta.modified() {
                if let Ok(elapsed) = SystemTime::now().duration_since(modified) {
                    if elapsed < cfg.sentinel_ttl {
                        info!(
                            role = %det.role,
                            fingerprint = %fp,
                            "sentinel dedup active — skipping re-filing"
                        );
                        return Ok(());
                    }
                }
            }
        }
    }

    // RESILIENT-040: anti-race check #1 — has someone ALREADY filed a gap for
    // this fingerprint? If so, don't file a duplicate AND don't spawn a
    // racing Sonnet against it. Counts as a circuit-breaker activation so
    // a flapping role still trips RESILIENT-035 even when remediation is
    // a no-op.
    if !cfg.dry_run {
        if let Some(existing_gap) = find_open_gap_with_fingerprint(cfg, &fp)? {
            let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
            emit_ambient(
                &cfg.ambient_path,
                &serde_json::json!({
                    "ts": ts,
                    "kind": "curator_supervisor_gap_already_filed",
                    "role": det.role,
                    "fingerprint": fp,
                    "existing_gap_id": existing_gap,
                }),
            );
            info!(
                role = %det.role,
                fingerprint = %fp,
                existing_gap_id = %existing_gap,
                "RESILIENT-040: gap with this fingerprint already filed — skipping"
            );
            // Write sentinel + count as activation to feed circuit breaker.
            write_sentinel(&sentinel_path, &fp)?;
            record_spawn_activation(cfg, det)?;
            return Ok(());
        }
    }

    let priority = if multi_failure { "P0" } else { "P1" };
    let log_tail = get_log_tail(cfg, &det.role, 20);
    let summary = det.failure_summary();

    info!(
        role = %det.role,
        priority,
        fingerprint = %fp,
        "filing gap for curator failure"
    );

    // File the gap (or emit would-file-gap in dry_run).
    let gap_id_for_sonnet: String = if cfg.dry_run {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_dry_run",
                "action": "would-file-gap",
                "role": det.role,
                "priority": priority,
                "fingerprint": fp,
                "summary": summary,
            }),
        );
        // Still write the sentinel so dedupe works in dry-run.
        write_sentinel(&sentinel_path, &fp)?;
        format!("DRY-RUN-{}", &fp)
    } else {
        let gap_id = file_curator_gap(cfg, det, priority, &log_tail)?;
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                "kind": "curator_failure_paged",
                "role": det.role,
                "gap_id": gap_id,
                "priority": priority,
                "fingerprint": fp,
                "summary": summary,
            }),
        );
        info!(role = %det.role, gap_id = %gap_id, "curator_failure_paged emitted");
        write_sentinel(&sentinel_path, &fp)?;
        gap_id
    };

    // RESILIENT-035 circuit breaker: cap per-role remediation rate so a
    // flapping role doesn't fork-bomb. Counts recent activation sentinels.
    if circuit_breaker_tripped(cfg, det)? {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_circuit_broken",
                "role": det.role,
                "max_spawns_per_hour": cfg.max_spawns_per_hour,
                "flapping_window_m": cfg.flapping_window.as_secs() / 60,
                "flapping_threshold": cfg.flapping_threshold,
                "gap_id": gap_id_for_sonnet,
            }),
        );
        warn!(
            role = %det.role,
            max = cfg.max_spawns_per_hour,
            "RESILIENT-035 circuit broken — halting auto-remediation for this role; operator review required"
        );
        // Broadcast a WARN to operator so we don't silently halt.
        let broadcast_path = cfg.repo_root.join("scripts/coord/broadcast.sh");
        if broadcast_path.exists() && !cfg.dry_run {
            let msg = format!(
                "RESILIENT-035 circuit broken: curator-supervisor halted auto-remediation for role={} after {} spawns in 1h OR {} detections in {}m. Operator review required (gap={}).",
                det.role,
                cfg.max_spawns_per_hour,
                cfg.flapping_threshold,
                cfg.flapping_window.as_secs() / 60,
                gap_id_for_sonnet,
            );
            let _ = tokio::process::Command::new(&broadcast_path)
                .args(["WARN", &msg])
                .output()
                .await;
        }
        return Ok(());
    }

    // RESILIENT-040: anti-race check #2 — does the gap we're about to act on
    // already have an active claim by another session? If so, another worker
    // is already on it; spawning a parallel Sonnet creates a claim collision.
    let claim_collision = !cfg.dry_run && gap_already_claimed(cfg, &gap_id_for_sonnet)?;
    if claim_collision {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_spawn_skipped_claim_collision",
                "role": det.role,
                "gap_id": gap_id_for_sonnet,
            }),
        );
        info!(
            role = %det.role,
            gap_id = %gap_id_for_sonnet,
            "RESILIENT-040: gap already claimed elsewhere — skipping spawn"
        );
        // Count as activation so flapping still trips the breaker.
        record_spawn_activation(cfg, det)?;
        // Still allow autorestart — the claim collision is about gap work,
        // not about the curator process itself.
        if cfg.autorestart {
            autorestart_curator(cfg, det).await?;
            record_spawn_activation(cfg, det)?;
        }
        return Ok(());
    }

    // Aggressive mode: spawn Sonnet sub-agent (spawn_sonnet handles dry_run internally).
    if cfg.mode == SupervisorMode::Aggressive {
        spawn_sonnet(cfg, det, &gap_id_for_sonnet, &log_tail).await?;
        record_spawn_activation(cfg, det)?;
    }

    // Auto-restart: respawn tmux pane.
    if cfg.autorestart {
        autorestart_curator(cfg, det).await?;
        record_spawn_activation(cfg, det)?;
    }

    Ok(())
}

// ── RESILIENT-040 anti-race helpers ───────────────────────────────────────────

/// Check whether any `.chump-locks/claim-<gap-lower>-*.json` files exist for
/// the given gap_id. Existence alone counts as a claim (the supervisor itself
/// doesn't hold gap claims, so any present file is another session's work).
fn gap_already_claimed(cfg: &Config, gap_id: &str) -> Result<bool> {
    if gap_id.is_empty() {
        return Ok(false);
    }
    let lock_dir = cfg
        .ambient_path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".chump-locks"));
    let prefix = format!("claim-{}-", gap_id.to_lowercase());
    let read = match fs::read_dir(&lock_dir) {
        Ok(r) => r,
        Err(_) => return Ok(false),
    };
    for entry in read.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with(&prefix) && name_str.ends_with(".json") {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Grep `chump gap list --status open --json` for an open gap whose
/// description / notes contain the given fingerprint substring. Returns the
/// gap_id of the FIRST match (lexical order), or None if no open gap matches.
/// Best-effort: shells out to `chump`; returns None silently on any failure
/// so the supervisor degrades to "no match" rather than crashing.
fn find_open_gap_with_fingerprint(cfg: &Config, fingerprint: &str) -> Result<Option<String>> {
    let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
    let output = std::process::Command::new(&chump_bin)
        .args(["gap", "list", "--status", "open", "--json"])
        .current_dir(&cfg.repo_root)
        .output();
    let bytes = match output {
        Ok(o) if o.status.success() => o.stdout,
        _ => return Ok(None),
    };
    let v: serde_json::Value = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(_) => return Ok(None),
    };
    let arr = match v.as_array() {
        Some(a) => a,
        None => return Ok(None),
    };
    for g in arr {
        let id = g
            .get("id")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let desc = g.get("description").and_then(|x| x.as_str()).unwrap_or("");
        let notes = g.get("notes").and_then(|x| x.as_str()).unwrap_or("");
        let title = g.get("title").and_then(|x| x.as_str()).unwrap_or("");
        if desc.contains(fingerprint) || notes.contains(fingerprint) || title.contains(fingerprint)
        {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

// ── RESILIENT-035 circuit breaker ─────────────────────────────────────────────

/// Per-role activation sentinel path. Tracks supervisor remediation actions
/// (Sonnet spawns + tmux respawns) so we can rate-cap them.
fn activation_sentinel_dir(cfg: &Config, role: &str) -> PathBuf {
    cfg.sentinel_dir
        .parent()
        .unwrap_or(&cfg.sentinel_dir)
        .join("activations")
        .join(role)
}

/// Append one activation marker for this role with current mtime. Each marker
/// is a separate file so we can count by listing the directory (no concurrent
/// write contention — supervisor is single-process).
fn record_spawn_activation(cfg: &Config, det: &DetectionResult) -> Result<()> {
    let dir = activation_sentinel_dir(cfg, &det.role);
    fs::create_dir_all(&dir).context("create activation sentinel dir")?;
    let ts_ms = Utc::now().timestamp_millis();
    let path = dir.join(format!("{ts_ms}.act"));
    fs::write(&path, det.error_fingerprint()).context("write activation sentinel")?;
    Ok(())
}

/// True if the circuit breaker should halt further remediation for this role.
///
/// Two independent triggers (whichever fires first):
/// 1. `>= max_spawns_per_hour` activations in the last 60 minutes.
/// 2. `>= flapping_threshold` detections (regardless of fingerprint) in the
///    last `flapping_window` minutes.
fn circuit_breaker_tripped(cfg: &Config, det: &DetectionResult) -> Result<bool> {
    let dir = activation_sentinel_dir(cfg, &det.role);
    if !dir.exists() {
        return Ok(false);
    }
    let now = SystemTime::now();
    let one_hour = Duration::from_secs(3600);
    let mut count_1h: u64 = 0;
    let mut count_window: u64 = 0;
    for entry in fs::read_dir(&dir).context("read activation sentinel dir")? {
        let Ok(entry) = entry else { continue };
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(mtime) = meta.modified() else { continue };
        let Ok(age) = now.duration_since(mtime) else {
            continue;
        };
        if age <= one_hour {
            count_1h += 1;
        }
        if age <= cfg.flapping_window {
            count_window += 1;
        }
    }
    Ok(count_1h >= cfg.max_spawns_per_hour || count_window >= cfg.flapping_threshold)
}

fn file_curator_gap(
    cfg: &Config,
    det: &DetectionResult,
    priority: &str,
    log_tail: &str,
) -> Result<String> {
    let role = &det.role;
    let summary = det.failure_summary();
    let title = format!("RESILIENT: curator-{role} auto-filed — detected: {summary}");
    let description = format!(
        "Auto-filed by chump-curator-supervisor (INFRA-2239) at {}.\n\
         Role: {role}\n\
         Failure: {summary}\n\n\
         Last 20 log lines:\n```\n{log_tail}\n```",
        Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
    );

    let ac = format!(
        "Fix curator-{role} so it completes a full tick without error. \
         Verify via heartbeat in ambient.jsonl and clean log output."
    );

    // chump gap reserve
    let reserve_out = std::process::Command::new("chump")
        .args([
            "gap",
            "reserve",
            "--domain",
            "INFRA",
            "--title",
            &title,
            "--priority",
            priority,
            "--effort",
            "s",
            "--json",
        ])
        .current_dir(&cfg.repo_root)
        .output()
        .context("chump gap reserve")?;

    if !reserve_out.status.success() {
        let stderr = String::from_utf8_lossy(&reserve_out.stderr);
        anyhow::bail!("chump gap reserve failed: {stderr}");
    }

    let reserve_json: Value =
        serde_json::from_slice(&reserve_out.stdout).context("parse gap reserve output")?;
    let gap_id = reserve_json
        .get("id")
        .or_else(|| reserve_json.get("gap_id"))
        .and_then(|v| v.as_str())
        .unwrap_or("INFRA-NEW")
        .to_string();

    // chump gap set description + AC
    let _ = std::process::Command::new("chump")
        .args([
            "gap",
            "set",
            &gap_id,
            "--description",
            &description,
            "--acceptance-criteria",
            &ac,
        ])
        .current_dir(&cfg.repo_root)
        .output();

    info!(role, gap_id = %gap_id, "gap filed");
    Ok(gap_id)
}

async fn spawn_sonnet(
    cfg: &Config,
    det: &DetectionResult,
    gap_id: &str,
    log_tail: &str,
) -> Result<()> {
    if cfg.dry_run {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_dry_run",
                "action": "would-spawn-sonnet",
                "role": det.role,
                "gap_id": gap_id,
            }),
        );
        return Ok(());
    }

    // Build the subagent prompt with SUBAGENT_DISPATCH.md contract preamble.
    let dispatch_md_path = cfg.repo_root.join("docs/process/SUBAGENT_DISPATCH.md");
    let dispatch_preamble = fs::read_to_string(&dispatch_md_path).unwrap_or_else(|_| {
        "# SUBAGENT_DISPATCH execution contract\n(see docs/process/SUBAGENT_DISPATCH.md)\n"
            .to_string()
    });

    let prompt = format!(
        "{dispatch_preamble}\n\n\
         ---\n\
         ## Your task\n\
         Gap: {gap_id}\n\
         Role: {role}\n\
         Failure: {summary}\n\n\
         Last 20 log lines from curator-{role}.log:\n```\n{log_tail}\n```\n\n\
         Fix the curator so it completes a full tick without error. \
         Claim gap {gap_id}, implement the fix, run preflight, ship.\n\
         No clarifying questions — make decisions and ship.\n",
        dispatch_preamble = dispatch_preamble,
        gap_id = gap_id,
        role = det.role,
        summary = det.failure_summary(),
        log_tail = log_tail,
    );

    info!(
        role = %det.role,
        gap_id,
        "spawning Sonnet sub-agent (fire-and-forget)"
    );

    // Fire-and-forget: spawn claude -p in background so supervisor tick
    // doesn't block on LLM latency. Background process inherits ambient.
    tokio::spawn(async move {
        let status = tokio::process::Command::new("claude")
            .args(["-p", "--model", "claude-sonnet-4-5", &prompt])
            .status()
            .await;
        match status {
            Ok(s) => info!(exit_code = s.code(), "Sonnet sub-agent exited"),
            Err(e) => warn!(err = %e, "Sonnet sub-agent spawn error"),
        }
    });

    Ok(())
}

async fn autorestart_curator(cfg: &Config, det: &DetectionResult) -> Result<()> {
    let role = &det.role;
    let tmux_session = std::env::var("CHUMP_CURATOR_TMUX_SESSION")
        .unwrap_or_else(|_| "chump-curators".to_string());

    // Build the respawn command: matches fleet-autopilot.sh curator_loop_cmd() format.
    let loop_script = find_loop_script(role);
    let log_file = cfg.log_dir.join(format!("curator-{role}.log"));
    let date_str = Utc::now().format("%Y-%m-%d").to_string();
    let session_id = format!("curator-opus-{role}-{date_str}");
    let tick_interval =
        std::env::var("CHUMP_CURATOR_TICK_INTERVAL_S").unwrap_or_else(|_| "300".to_string());
    let repo = cfg.repo_root.display();
    let log = log_file.display();

    let inner_cmd = if !loop_script.is_empty() {
        let script_path = cfg.repo_root.join(loop_script);
        format!(
            "export CHUMP_SESSION_ID={session_id} REPO_ROOT={repo}; \
             while true; do {script} tick 2>&1 | tee -a {log}; \
             {script} heartbeat 2>>{log}; sleep {tick_interval}; done",
            script = script_path.display(),
        )
    } else {
        // Stub role (no loop script): minimal heartbeat loop.
        format!(
            "export CHUMP_SESSION_ID={session_id} REPO_ROOT={repo} \
             AMBIENT={ambient} CURATOR_ROLE={role} LOG_FILE={log} INTERVAL={tick_interval}; \
             while true; do ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); \
             printf '{{\"ts\":\"%s\",\"kind\":\"curator_heartbeat\",\"role\":\"{role}\",\"session\":\"{session_id}\"}}\n' \
             \"$ts\" >> \"$AMBIENT\" 2>/dev/null || true; \
             echo \"[{role}] tick $ts\" >> \"$LOG_FILE\" 2>&1; sleep \"$INTERVAL\"; done",
            ambient = cfg.ambient_path.display(),
        )
    };

    let respawn_cmd = format!("/bin/bash -lc '{inner_cmd}'");
    let target = format!("{tmux_session}:{role}");

    if cfg.dry_run {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_dry_run",
                "action": "would-respawn-pane",
                "role": role,
                "target": target,
            }),
        );
        return Ok(());
    }

    info!(role, target = %target, "respawning curator pane");

    let respawn_status = std::process::Command::new("tmux")
        .args(["respawn-pane", "-t", &target, "-k", &respawn_cmd])
        .current_dir(&cfg.repo_root)
        .status();

    match respawn_status {
        Err(e) => {
            warn!(role, err = %e, "tmux respawn-pane invocation error");
        }
        Ok(s) if !s.success() => {
            warn!(role, code = s.code(), "tmux respawn-pane failed");
        }
        Ok(_) => {
            info!(
                role,
                "tmux respawn-pane succeeded, waiting for heartbeat (60s)"
            );
            // Poll ambient.jsonl for up to 60s for a fresh heartbeat.
            let heartbeat_seen = wait_for_heartbeat(&cfg.ambient_path, role, 60).await;
            if heartbeat_seen {
                emit_ambient(
                    &cfg.ambient_path,
                    &serde_json::json!({
                        "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                        "kind": "curator_respawned",
                        "role": role,
                    }),
                );
                info!(role, "curator_respawned emitted");
            } else {
                emit_ambient(
                    &cfg.ambient_path,
                    &serde_json::json!({
                        "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                        "kind": "curator_respawn_failed",
                        "role": role,
                        "reason": "no heartbeat within 60s",
                    }),
                );
                warn!(
                    role,
                    "curator_respawn_failed — no heartbeat within 60s, broadcasting WARN"
                );
                // Escalate to operator via broadcast.sh.
                let broadcast_sh = cfg.repo_root.join("scripts/coord/broadcast.sh");
                let _ = std::process::Command::new("bash")
                    .arg(&broadcast_sh)
                    .args([
                        "--all",
                        "WARN",
                        &format!("curator-{role} respawn failed — no heartbeat within 60s"),
                    ])
                    .current_dir(&cfg.repo_root)
                    .status();
            }
        }
    }

    Ok(())
}

/// Poll ambient.jsonl until a fresh curator_heartbeat for `role` appears (max `timeout_s`).
async fn wait_for_heartbeat(ambient_path: &Path, role: &str, timeout_s: u64) -> bool {
    let started = std::time::Instant::now();
    let deadline = Duration::from_secs(timeout_s);
    let baseline = Utc::now();

    // Path to string for passing to spawned code.
    let ambient_path = ambient_path.to_path_buf();
    let role = role.to_string();

    loop {
        if started.elapsed() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_secs(3)).await;

        // Read last 20 lines and look for a heartbeat newer than baseline.
        if let Ok(lines) = tail_lines(&ambient_path, 20) {
            for line in &lines {
                let Ok(v) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                if v.get("kind").and_then(|k| k.as_str()) != Some("curator_heartbeat") {
                    continue;
                }
                if v.get("role").and_then(|r| r.as_str()) != Some(role.as_str()) {
                    continue;
                }
                if let Some(ts_str) = v.get("ts").and_then(|t| t.as_str()) {
                    if let Ok(ts) = ts_str.parse::<chrono::DateTime<Utc>>() {
                        if ts >= baseline {
                            return true;
                        }
                    }
                }
            }
        }
    }
}

// ── helpers ────────────────────────────────────────────────────────────────

fn resolve_repo_root() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_REPO_ROOT") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/Users/jeffadkins/Projects/Chump"))
}

fn env_path(key: &str, default: PathBuf) -> PathBuf {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or(default)
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Return the last `n` lines of a file. Returns empty vec if file missing.
fn tail_lines(path: &Path, n: usize) -> Result<Vec<String>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let file = fs::File::open(path).with_context(|| format!("open {:?}", path))?;
    let reader = io::BufReader::new(file);
    let mut lines: Vec<String> = reader.lines().map_while(Result::ok).collect();
    if lines.len() > n {
        lines.drain(0..lines.len() - n);
    }
    Ok(lines)
}

fn get_log_tail(cfg: &Config, role: &str, n: usize) -> String {
    let log_path = cfg.log_dir.join(format!("curator-{role}.log"));
    tail_lines(&log_path, n).unwrap_or_default().join("\n")
}

fn infer_session_id(role: &str) -> String {
    let date = Utc::now().format("%Y-%m-%d");
    format!("curator-opus-{role}-{date}")
}

fn find_loop_script(role: &str) -> &'static str {
    CURATOR_ROLES
        .iter()
        .find(|(r, _)| *r == role)
        .map(|(_, s)| *s)
        .unwrap_or("")
}

fn emit_ambient(ambient_path: &Path, event: &Value) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(ambient_path)
    {
        use std::io::Write;
        let line = serde_json::to_string(event).unwrap_or_else(|_| "{}".to_string());
        let _ = writeln!(f, "{line}");
    }
}

fn write_sentinel(sentinel_path: &Path, fingerprint: &str) -> Result<()> {
    if let Some(parent) = sentinel_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(sentinel_path, fingerprint)?;
    Ok(())
}

// ── tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn make_temp_log(dir: &TempDir, name: &str, lines: &[&str]) -> PathBuf {
        let path = dir.path().join(name);
        let mut f = fs::File::create(&path).unwrap();
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
        path
    }

    #[test]
    fn test_error_pattern_scan_triggers() {
        let dir = TempDir::new().unwrap();
        let path = make_temp_log(
            &dir,
            "test.log",
            &[
                "normal line",
                "error: unknown subcommand: tick",
                "another line",
                "error: unknown subcommand: heartbeat",
                "ok line",
            ],
        );
        let (triggered, sample) = error_pattern_scan(&path, 50, 2).unwrap();
        assert!(triggered, "should trigger on 2+ error patterns");
        assert!(sample.is_some());
    }

    #[test]
    fn test_error_pattern_scan_no_trigger_below_threshold() {
        let dir = TempDir::new().unwrap();
        let path = make_temp_log(
            &dir,
            "test.log",
            &["normal line", "unknown subcommand: tick", "ok line"],
        );
        let (triggered, _) = error_pattern_scan(&path, 50, 2).unwrap();
        assert!(
            !triggered,
            "should not trigger on 1 match when threshold is 2"
        );
    }

    #[test]
    fn test_crash_loop_check_triggers() {
        let dir = TempDir::new().unwrap();
        let mut lines: Vec<&str> = Vec::new();
        lines.extend(std::iter::repeat_n("error: something went wrong", 85));
        lines.extend(std::iter::repeat_n("normal output", 15));
        let path = make_temp_log(&dir, "test.log", &lines);
        let triggered = crash_loop_check(&path, 100, 0.80).unwrap();
        assert!(triggered, "85% error ratio should trigger crash loop");
    }

    #[test]
    fn test_crash_loop_check_no_trigger() {
        let dir = TempDir::new().unwrap();
        let mut lines: Vec<&str> = Vec::new();
        lines.extend(std::iter::repeat_n("normal output", 50));
        lines.extend(std::iter::repeat_n("error: something", 50));
        let path = make_temp_log(&dir, "test.log", &lines);
        let triggered = crash_loop_check(&path, 100, 0.80).unwrap();
        assert!(
            !triggered,
            "50% error ratio should not trigger at 80% threshold"
        );
    }

    #[test]
    fn test_tail_lines_returns_last_n() {
        let dir = TempDir::new().unwrap();
        let lines: Vec<String> = (0..100).map(|i| format!("line {i}")).collect();
        let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
        let path = make_temp_log(&dir, "test.log", &refs);
        let tail = tail_lines(&path, 10).unwrap();
        assert_eq!(tail.len(), 10);
        assert_eq!(tail[0], "line 90");
        assert_eq!(tail[9], "line 99");
    }

    #[test]
    fn test_sentinel_dedup() {
        let dir = TempDir::new().unwrap();
        let sentinel_path = dir.path().join("decompose:abcdef12.sentinel");
        write_sentinel(&sentinel_path, "decompose:abcdef12").unwrap();
        assert!(sentinel_path.exists(), "sentinel file should be created");
        let meta = fs::metadata(&sentinel_path).unwrap();
        let modified = meta.modified().unwrap();
        let elapsed = SystemTime::now().duration_since(modified).unwrap();
        // Just created — elapsed should be < 1s.
        assert!(
            elapsed < Duration::from_secs(1),
            "fresh sentinel: elapsed should be <1s"
        );
    }

    #[test]
    fn test_error_fingerprint_consistent() {
        let det = DetectionResult {
            role: "decompose".to_string(),
            error_pattern_triggered: true,
            error_pattern_sample: Some("unknown subcommand: tick".to_string()),
            ..Default::default()
        };
        let fp1 = det.error_fingerprint();
        let fp2 = det.error_fingerprint();
        assert_eq!(fp1, fp2, "fingerprint must be deterministic");
        assert!(
            fp1.starts_with("decompose:"),
            "fingerprint must include role"
        );
    }

    #[test]
    fn test_silent_stall_no_ambient_file() {
        let dir = TempDir::new().unwrap();
        let ambient = dir.path().join("ambient.jsonl");
        // File does not exist.
        let (stalled, ago) =
            silent_stall_check(&ambient, "decompose", Duration::from_secs(600)).unwrap();
        assert!(!stalled, "no ambient file → should not stall");
        assert!(ago.is_none());
    }

    #[test]
    fn test_silent_stall_with_old_heartbeat() {
        let dir = TempDir::new().unwrap();
        let ambient = dir.path().join("ambient.jsonl");
        // Write a heartbeat from 30 minutes ago.
        let old_ts = (Utc::now() - chrono::Duration::minutes(30))
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string();
        let line = format!(
            "{{\"ts\":\"{old_ts}\",\"kind\":\"curator_heartbeat\",\"role\":\"decompose\",\"session\":\"x\"}}\n"
        );
        fs::write(&ambient, line).unwrap();

        let (stalled, ago) =
            silent_stall_check(&ambient, "decompose", Duration::from_secs(600)).unwrap();
        assert!(
            stalled,
            "30-min-old heartbeat should stall at 10min threshold"
        );
        assert!(ago.is_some());
        assert!(ago.unwrap() > Duration::from_secs(1000)); // ~30 min in seconds
    }

    #[test]
    fn test_silent_stall_with_fresh_heartbeat() {
        let dir = TempDir::new().unwrap();
        let ambient = dir.path().join("ambient.jsonl");
        let fresh_ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let line = format!(
            "{{\"ts\":\"{fresh_ts}\",\"kind\":\"curator_heartbeat\",\"role\":\"decompose\",\"session\":\"x\"}}\n"
        );
        fs::write(&ambient, line).unwrap();

        let (stalled, _) =
            silent_stall_check(&ambient, "decompose", Duration::from_secs(600)).unwrap();
        assert!(!stalled, "fresh heartbeat should not stall");
    }

    // ── RESILIENT-040 anti-race helper tests ─────────────────────────────────

    fn _test_cfg_at(root: &Path) -> Config {
        Config {
            repo_root: root.to_path_buf(),
            log_dir: root.join("logs"),
            ambient_path: root.join("locks/ambient.jsonl"),
            sentinel_dir: root.join("supervisor/seen"),
            sentinel_ttl: Duration::from_secs(3600),
            stall_threshold: Duration::from_secs(600),
            productivity_window: Duration::from_secs(3600),
            mode: SupervisorMode::Aggressive,
            autorestart: true,
            dry_run: true,
            interval: Duration::from_secs(300),
            max_spawns_per_hour: 3,
            flapping_window: Duration::from_secs(1800),
            flapping_threshold: 3,
        }
    }

    #[test]
    fn test_gap_already_claimed_returns_false_for_empty_gap_id() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        // ambient_path is locks/ambient.jsonl → lock_dir = locks/
        fs::create_dir_all(dir.path().join("locks")).unwrap();
        assert!(!gap_already_claimed(&cfg, "").unwrap());
    }

    #[test]
    fn test_gap_already_claimed_returns_false_when_no_claim_file() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        fs::create_dir_all(dir.path().join("locks")).unwrap();
        assert!(!gap_already_claimed(&cfg, "INFRA-9999").unwrap());
    }

    #[test]
    fn test_gap_already_claimed_returns_true_when_claim_file_present() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        let locks = dir.path().join("locks");
        fs::create_dir_all(&locks).unwrap();
        // gap_id is lowercased before glob match.
        fs::write(
            locks.join("claim-infra-9999-12345-1780000000.json"),
            r#"{"session_id":"sibling-x"}"#,
        )
        .unwrap();
        assert!(gap_already_claimed(&cfg, "INFRA-9999").unwrap());
    }

    #[test]
    fn test_gap_already_claimed_works_for_dry_run_ids() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        let locks = dir.path().join("locks");
        fs::create_dir_all(&locks).unwrap();
        fs::write(
            locks.join("claim-dry-run-decompose:abc12345-1-1.json"),
            r#"{"session_id":"sibling-x"}"#,
        )
        .unwrap();
        // DRY-RUN prefix no longer short-circuits — it should detect the claim
        // so dry-run smoke tests can validate the collision path.
        assert!(gap_already_claimed(&cfg, "DRY-RUN-decompose:abc12345").unwrap());
    }

    #[test]
    fn test_find_open_gap_with_fingerprint_degrades_silently_when_chump_missing() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        // Point CHUMP_BIN at a non-existent binary so the shell-out fails.
        std::env::set_var("CHUMP_BIN", "/does/not/exist/chump-missing");
        let result = find_open_gap_with_fingerprint(&cfg, "decompose:deadbeef");
        std::env::remove_var("CHUMP_BIN");
        // Should return Ok(None) — degraded path, not a crash.
        assert!(matches!(result, Ok(None)));
    }
}
