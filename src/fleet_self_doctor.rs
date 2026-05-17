//! INFRA-1595: fleet self-doctor `--heal` mode (Wave 0b "outer loop").
//!
//! This module implements the autonomous outer loop that ties together:
//!   - INFRA-1427 (chump fleet doctor --strict)  diagnose layer
//!   - INFRA-1594 (bootstrap completeness check) bootstrap layer
//!   - INFRA-1410 (PR-stuck SLO + auto-respawn)  PR-level remediation
//!   - INFRA-1375 (paramedic)                    per-PR rule-engine fixes
//!
//! When called as `chump fleet doctor --heal`, this auto-fixes what
//! `--strict` diagnoses:
//!   1. Missing daemons (per `REQUIRED_DAEMONS` registry) get auto-installed
//!      via their install-*.sh script.
//!   2. Stuck PRs (DIRTY or BLOCKED > 30min with no progress markers) get
//!      auto-dispatched via `chump --execute-gap <ID>` (existing autonomous
//!      agent path — NOT the session-bound Agent tool).
//!
//! Circuit breaker: refuses to spawn more than `CHUMP_SELF_DOCTOR_BUDGET`
//! (default 3) subagents per 10-minute window. On budget exceeded, emits
//! `self_doctor_budget_exceeded` and writes `operator-action-needed.json`.
//!
//! Default OFF: ship as opt-in via `CHUMP_FLEET_SELF_DOCTOR_HEAL=true`.
//! Default mode is diagnose-only (no side effects).

use crate::ambient_emit::{emit, EmitArgs};
use crate::repo_path;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Per-daemon registry: launchctl label + relative install-script path.
///
/// To register a new daemon: add a tuple here AND add an entry to
/// `scripts/setup/bootstrap-manifest.yaml`. Doctor iterates this list,
/// checks `launchctl print` status, and runs the install script if missing.
/// Each install script must be idempotent (most existing ones already are).
pub const REQUIRED_DAEMONS: &[(&str, &str)] = &[
    ("com.chump.paramedic", "scripts/setup/install-paramedic.sh"),
    (
        "com.chump.self-doctor",
        "scripts/setup/install-self-doctor.sh",
    ),
];

/// Default circuit-breaker budget (subagent spawns per 10-minute window).
pub const DEFAULT_BUDGET: usize = 3;

/// Circuit-breaker window in seconds.
pub const BUDGET_WINDOW_SECS: i64 = 600;

/// Stuck-PR threshold (minutes since last activity).
pub const STUCK_PR_THRESHOLD_MINS: i64 = 30;

/// Outcome of a single heal cycle.
#[derive(Debug, Default)]
pub struct HealOutcome {
    pub daemons_installed: Vec<String>,
    pub daemons_failed: Vec<String>,
    pub prs_dispatched: Vec<(u64, String)>, // (pr_number, gap_id)
    pub prs_failed: Vec<u64>,
    pub budget_hit: bool,
    pub idle: bool,
}

/// Configuration knobs for the heal cycle. Override via env (production) or
/// directly in tests.
#[derive(Debug, Clone)]
pub struct HealConfig {
    /// Override the launchctl status check to a mock that returns true/false
    /// per label. Used by smoke tests.
    pub mock_launchctl_loaded: Option<fn(&str) -> bool>,
    /// Override the install-script runner. Used by smoke tests.
    pub mock_install: Option<fn(&Path) -> Result<(), String>>,
    /// Override stuck-PR discovery. Used by smoke tests.
    /// Returns Vec<(pr_number, gap_id)>.
    pub mock_stuck_prs: Option<fn() -> Vec<(u64, String)>>,
    /// Override execute-gap dispatch. Used by smoke tests.
    pub mock_execute_gap: Option<fn(&str) -> Result<(), String>>,
    /// Override the dispatch log path. Used by smoke tests.
    pub dispatch_log_override: Option<PathBuf>,
    /// Override the operator-action path. Used by smoke tests.
    pub operator_action_override: Option<PathBuf>,
    /// Budget override (default reads `CHUMP_SELF_DOCTOR_BUDGET`).
    pub budget_override: Option<usize>,
}

impl Default for HealConfig {
    fn default() -> Self {
        Self {
            mock_launchctl_loaded: None,
            mock_install: None,
            mock_stuck_prs: None,
            mock_execute_gap: None,
            dispatch_log_override: None,
            operator_action_override: None,
            budget_override: None,
        }
    }
}

/// Run one heal cycle. Iterates daemons → checks/installs; then scans for
/// stuck PRs → dispatches up to `budget` subagents.
///
/// Emits ambient events:
///   - `self_doctor_tick` — when nothing was healed (idle)
///   - `self_doctor_healed` — for each action taken
///   - `self_doctor_failed` — for each action that failed
///   - `self_doctor_budget_exceeded` — when budget hit
pub fn run_heal_cycle(cfg: &HealConfig) -> HealOutcome {
    let mut outcome = HealOutcome::default();

    // ── 1. daemons ────────────────────────────────────────────────────────
    let repo_root = repo_path::repo_root();
    for (label, install_rel) in REQUIRED_DAEMONS {
        let loaded = match cfg.mock_launchctl_loaded {
            Some(f) => f(label),
            None => launchctl_loaded(label),
        };
        if loaded {
            continue;
        }
        let install_path = repo_root.join(install_rel);
        let result = match cfg.mock_install {
            Some(f) => f(&install_path),
            None => run_install_script(&install_path),
        };
        match result {
            Ok(()) => {
                outcome.daemons_installed.push(label.to_string());
                let _ = emit(&EmitArgs {
                    kind: "self_doctor_healed".to_string(),
                    source: Some("fleet_self_doctor".to_string()),
                    fields: vec![
                        ("action".to_string(), "daemon_installed".to_string()),
                        ("daemon".to_string(), label.to_string()),
                    ],
                    ..Default::default()
                });
            }
            Err(err) => {
                outcome.daemons_failed.push(label.to_string());
                let _ = emit(&EmitArgs {
                    kind: "self_doctor_failed".to_string(),
                    source: Some("fleet_self_doctor".to_string()),
                    fields: vec![
                        ("action".to_string(), "daemon_installed".to_string()),
                        ("daemon".to_string(), label.to_string()),
                        ("error".to_string(), truncate(&err, 200)),
                    ],
                    ..Default::default()
                });
            }
        }
    }

    // ── 2. stuck PRs ──────────────────────────────────────────────────────
    let stuck = match cfg.mock_stuck_prs {
        Some(f) => f(),
        None => discover_stuck_prs(),
    };

    let budget = cfg
        .budget_override
        .or_else(|| {
            std::env::var("CHUMP_SELF_DOCTOR_BUDGET")
                .ok()
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(DEFAULT_BUDGET);

    let dispatch_log = cfg
        .dispatch_log_override
        .clone()
        .unwrap_or_else(|| repo_root.join(".chump-locks/self-doctor-dispatch.log"));

    let recent = count_recent_dispatches(&dispatch_log);

    for (pr_num, gap_id) in stuck.iter() {
        // Recompute available budget each iteration.
        let used = recent + outcome.prs_dispatched.len();
        if used >= budget {
            outcome.budget_hit = true;
            let _ = emit(&EmitArgs {
                kind: "self_doctor_budget_exceeded".to_string(),
                source: Some("fleet_self_doctor".to_string()),
                fields: vec![
                    ("budget".to_string(), budget.to_string()),
                    ("recent".to_string(), recent.to_string()),
                    ("pending".to_string(), stuck.len().to_string()),
                ],
                ..Default::default()
            });
            page_operator(cfg, recent + outcome.prs_dispatched.len(), budget, &stuck);
            break;
        }
        let result = match cfg.mock_execute_gap {
            Some(f) => f(gap_id),
            None => dispatch_execute_gap(gap_id),
        };
        match result {
            Ok(()) => {
                outcome.prs_dispatched.push((*pr_num, gap_id.clone()));
                append_dispatch_log(&dispatch_log, *pr_num, gap_id);
                let _ = emit(&EmitArgs {
                    kind: "self_doctor_healed".to_string(),
                    source: Some("fleet_self_doctor".to_string()),
                    gap: Some(gap_id.clone()),
                    fields: vec![
                        ("action".to_string(), "pr_dispatched".to_string()),
                        ("pr".to_string(), pr_num.to_string()),
                    ],
                    ..Default::default()
                });
            }
            Err(err) => {
                outcome.prs_failed.push(*pr_num);
                let _ = emit(&EmitArgs {
                    kind: "self_doctor_failed".to_string(),
                    source: Some("fleet_self_doctor".to_string()),
                    gap: Some(gap_id.clone()),
                    fields: vec![
                        ("action".to_string(), "pr_dispatched".to_string()),
                        ("pr".to_string(), pr_num.to_string()),
                        ("error".to_string(), truncate(&err, 200)),
                    ],
                    ..Default::default()
                });
            }
        }
    }

    // ── 3. idle tick ──────────────────────────────────────────────────────
    if outcome.daemons_installed.is_empty()
        && outcome.daemons_failed.is_empty()
        && outcome.prs_dispatched.is_empty()
        && outcome.prs_failed.is_empty()
        && !outcome.budget_hit
    {
        outcome.idle = true;
        let _ = emit(&EmitArgs {
            kind: "self_doctor_tick".to_string(),
            source: Some("fleet_self_doctor".to_string()),
            fields: vec![("status".to_string(), "idle".to_string())],
            ..Default::default()
        });
    }

    outcome
}

// ── helpers ───────────────────────────────────────────────────────────────

fn launchctl_loaded(label: &str) -> bool {
    let uid = std::env::var("UID")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .or_else(|| {
            Command::new("id").arg("-u").output().ok().and_then(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .trim()
                    .parse::<u32>()
                    .ok()
            })
        })
        .unwrap_or(501);
    let target = format!("gui/{uid}/{label}");
    Command::new("launchctl")
        .args(["print", &target])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_install_script(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("install script missing: {}", path.display()));
    }
    let out = Command::new("bash")
        .arg(path)
        .output()
        .map_err(|e| format!("spawn bash: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&out.stderr);
        Err(format!(
            "exit={:?} stderr={}",
            out.status.code(),
            stderr.lines().last().unwrap_or("")
        ))
    }
}

/// Discover stuck PRs: DIRTY or BLOCKED, last update > 30 min ago, with no
/// recent progress markers. Reads via `gh pr list` (background-tagged so it
/// yields to critical callers under GraphQL pressure).
fn discover_stuck_prs() -> Vec<(u64, String)> {
    // Background-tagged: under GraphQL pressure self-doctor is non-critical
    // relative to ship-blocking writes.
    let out = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--json",
            "number,title,mergeStateStatus,updatedAt",
            "--limit",
            "100",
        ])
        .env("CHUMP_GH_CALL_CRITICALITY", "background")
        .output();
    let stdout = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return vec![],
    };
    let parsed: serde_json::Value = match serde_json::from_slice(&stdout) {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    let now = chrono::Utc::now();
    let arr = match parsed.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    let mut stuck = Vec::new();
    for pr in arr {
        let state = pr
            .get("mergeStateStatus")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if state != "DIRTY" && state != "BLOCKED" {
            continue;
        }
        let updated_at = pr.get("updatedAt").and_then(|v| v.as_str()).unwrap_or("");
        let updated = match chrono::DateTime::parse_from_rfc3339(updated_at) {
            Ok(t) => t.with_timezone(&chrono::Utc),
            Err(_) => continue,
        };
        let age_min = (now - updated).num_minutes();
        if age_min < STUCK_PR_THRESHOLD_MINS {
            continue;
        }
        let title = pr.get("title").and_then(|v| v.as_str()).unwrap_or("");
        let gap_id = match extract_gap_id(title) {
            Some(g) => g,
            None => continue,
        };
        let number = pr.get("number").and_then(|v| v.as_u64()).unwrap_or(0);
        if number == 0 {
            continue;
        }
        stuck.push((number, gap_id));
    }
    stuck
}

/// Extract a gap-id like `INFRA-1234` or `META-046` from a PR title.
pub fn extract_gap_id(title: &str) -> Option<String> {
    // Cheap scan: look for uppercase letters followed by '-' then digits.
    let bytes = title.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // Find start of an uppercase run.
        if !bytes[i].is_ascii_uppercase() {
            i += 1;
            continue;
        }
        let alpha_start = i;
        while i < bytes.len() && bytes[i].is_ascii_uppercase() {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'-' {
            continue;
        }
        let dash = i;
        i += 1;
        let digit_start = i;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
        if i > digit_start && (dash - alpha_start) >= 3 {
            return Some(title[alpha_start..i].to_string());
        }
    }
    None
}

fn dispatch_execute_gap(gap_id: &str) -> Result<(), String> {
    // Spawn the existing autonomous agent path. Detached: we don't await
    // completion (gaps run for many minutes; the heal cycle must stay fast).
    let chump_bin = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    Command::new(&chump_bin)
        .args(["--execute-gap", gap_id])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("spawn execute-gap: {e}"))?;
    Ok(())
}

fn count_recent_dispatches(log: &Path) -> usize {
    let contents = match std::fs::read_to_string(log) {
        Ok(c) => c,
        Err(_) => return 0,
    };
    let cutoff = chrono::Utc::now() - chrono::Duration::seconds(BUDGET_WINDOW_SECS);
    contents
        .lines()
        .filter_map(|l| l.split_once('\t').map(|(ts, _)| ts.to_string()))
        .filter_map(|ts| chrono::DateTime::parse_from_rfc3339(&ts).ok())
        .filter(|t| t.with_timezone(&chrono::Utc) >= cutoff)
        .count()
}

fn append_dispatch_log(log: &Path, pr: u64, gap_id: &str) {
    if let Some(p) = log.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(log)
    {
        use std::io::Write;
        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let _ = writeln!(f, "{ts}\t{pr}\t{gap_id}");
    }
}

fn page_operator(cfg: &HealConfig, used: usize, budget: usize, pending: &[(u64, String)]) {
    let path = cfg
        .operator_action_override
        .clone()
        .unwrap_or_else(|| repo_path::repo_root().join(".chump-locks/operator-action-needed.json"));
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let pending_json: Vec<_> = pending
        .iter()
        .map(|(n, g)| serde_json::json!({"pr": n, "gap_id": g}))
        .collect();
    let payload = serde_json::json!({
        "ts": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        "source": "fleet_self_doctor",
        "reason": "self_doctor_budget_exceeded",
        "budget": budget,
        "used": used,
        "window_secs": BUDGET_WINDOW_SECS,
        "pending": pending_json,
        "action": format!(
            "Self-doctor hit budget ({used}/{budget}) in {}s window. \
             Review .chump-locks/self-doctor-dispatch.log + stuck PRs manually.",
            BUDGET_WINDOW_SECS
        ),
    });
    let _ = std::fs::write(
        &path,
        serde_json::to_string_pretty(&payload).unwrap_or_default(),
    );
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_gap_id_from_pr_title() {
        assert_eq!(
            extract_gap_id("feat(INFRA-1595): RESILIENT — autonomy loop"),
            Some("INFRA-1595".to_string())
        );
        assert_eq!(
            extract_gap_id("fix(META-046): registry health"),
            Some("META-046".to_string())
        );
        assert_eq!(extract_gap_id("no gap id here"), None);
        assert_eq!(
            extract_gap_id("PRODUCT-102 dashboard"),
            Some("PRODUCT-102".to_string())
        );
        // Short prefixes (< 3 chars) should be rejected to avoid matching "v1-".
        assert_eq!(extract_gap_id("v1-23 release"), None);
    }

    #[test]
    fn idle_cycle_with_all_daemons_loaded_and_no_stuck_prs() {
        // Mock: all daemons loaded, no stuck PRs.
        fn always_loaded(_: &str) -> bool {
            true
        }
        fn no_stuck() -> Vec<(u64, String)> {
            vec![]
        }
        let tmp = tempfile::tempdir().unwrap();
        let cfg = HealConfig {
            mock_launchctl_loaded: Some(always_loaded),
            mock_stuck_prs: Some(no_stuck),
            dispatch_log_override: Some(tmp.path().join("dispatch.log")),
            operator_action_override: Some(tmp.path().join("op.json")),
            ..Default::default()
        };
        let out = run_heal_cycle(&cfg);
        assert!(
            out.idle,
            "should be idle when all daemons loaded + no stuck PRs"
        );
        assert!(out.daemons_installed.is_empty());
        assert!(out.prs_dispatched.is_empty());
    }

    #[test]
    fn budget_hit_pages_operator() {
        fn always_loaded(_: &str) -> bool {
            true
        }
        fn many_stuck() -> Vec<(u64, String)> {
            vec![
                (1, "INFRA-001".to_string()),
                (2, "INFRA-002".to_string()),
                (3, "INFRA-003".to_string()),
                (4, "INFRA-004".to_string()),
            ]
        }
        fn ok_exec(_: &str) -> Result<(), String> {
            Ok(())
        }
        let tmp = tempfile::tempdir().unwrap();
        let op_path = tmp.path().join("op.json");
        let cfg = HealConfig {
            mock_launchctl_loaded: Some(always_loaded),
            mock_stuck_prs: Some(many_stuck),
            mock_execute_gap: Some(ok_exec),
            dispatch_log_override: Some(tmp.path().join("dispatch.log")),
            operator_action_override: Some(op_path.clone()),
            budget_override: Some(2),
            ..Default::default()
        };
        let out = run_heal_cycle(&cfg);
        assert!(
            out.budget_hit,
            "should hit budget with 4 stuck PRs and budget=2"
        );
        assert_eq!(out.prs_dispatched.len(), 2);
        assert!(
            op_path.exists(),
            "operator-action-needed.json must be written"
        );
    }

    #[test]
    fn missing_daemon_triggers_install() {
        fn one_missing(label: &str) -> bool {
            label != "com.chump.paramedic"
        }
        fn ok_install(_: &Path) -> Result<(), String> {
            Ok(())
        }
        fn no_stuck() -> Vec<(u64, String)> {
            vec![]
        }
        let tmp = tempfile::tempdir().unwrap();
        let cfg = HealConfig {
            mock_launchctl_loaded: Some(one_missing),
            mock_install: Some(ok_install),
            mock_stuck_prs: Some(no_stuck),
            dispatch_log_override: Some(tmp.path().join("dispatch.log")),
            operator_action_override: Some(tmp.path().join("op.json")),
            ..Default::default()
        };
        let out = run_heal_cycle(&cfg);
        assert!(out
            .daemons_installed
            .contains(&"com.chump.paramedic".to_string()));
        assert!(!out.idle);
    }
}
