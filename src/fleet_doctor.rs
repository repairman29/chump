//! INFRA-603: `chump fleet doctor` — fleet health audit.
//!
//! Five invariants checked:
//! 1. claude PID count == 2 × fleet_worker_count (each worker: shell + claude)
//! 2. No `.gap-<ID>.lock` exists for a gap whose status is `done`
//! 3. No `claude` process with PPID=1 alive > 60 s (orphan detection)
//! 4. waste-tally (last 30 min) has no `fleet_wedge` or unrecognized kind
//! 5. No `event=ALERT` entries in ambient.jsonl in the last 5 min
//!
//! Without `--fix`: prints a report and emits `kind=fleet_doctor_report` to ambient.
//! With `--fix`:    additionally pkills orphans and removes stale gap-locks.

use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};

// ── public result type ────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckStatus {
    Pass,
    Warn,
    Fail,
}

#[derive(Debug, Clone)]
pub struct CheckResult {
    pub name: &'static str,
    pub status: CheckStatus,
    pub message: String,
    pub fix_applied: Option<String>,
}

pub struct DoctorReport {
    pub checks: Vec<CheckResult>,
}

impl DoctorReport {
    pub fn overall_ok(&self) -> bool {
        self.checks.iter().all(|c| c.status != CheckStatus::Fail)
    }
}

// ── entry point ───────────────────────────────────────────────────────────────

/// Run all 5 fleet-health checks. If `fix` is true, apply remediations where
/// available (kill orphans, remove stale locks).
pub fn run(repo_root: &Path, fix: bool) -> DoctorReport {
    let lock_dir = resolve_lock_dir(repo_root);
    let checks = vec![
        check_pid_ratio(&lock_dir, repo_root),
        check_stale_gap_locks(&lock_dir, repo_root, fix),
        check_orphan_claudes(fix),
        check_waste_tally(repo_root),
        check_ambient_alerts(&lock_dir),
    ];
    let report = DoctorReport { checks };
    emit_ambient_report(repo_root, &lock_dir, &report);
    report
}

/// Print a human-readable report. Returns exit code (0 = all ok).
pub fn print_report(report: &DoctorReport) -> i32 {
    let mut any_fail = false;
    for c in &report.checks {
        let badge = match c.status {
            CheckStatus::Pass => "PASS",
            CheckStatus::Warn => "WARN",
            CheckStatus::Fail => {
                any_fail = true;
                "FAIL"
            }
        };
        println!("[fleet doctor] {badge}  {}  — {}", c.name, c.message);
        if let Some(fix) = &c.fix_applied {
            println!("               fix: {fix}");
        }
    }
    if any_fail {
        1
    } else {
        0
    }
}

/// Print machine-readable JSON report. Returns exit code.
pub fn print_json_report(report: &DoctorReport) -> i32 {
    let mut any_fail = false;
    let items: Vec<String> = report
        .checks
        .iter()
        .map(|c| {
            if c.status == CheckStatus::Fail {
                any_fail = true;
            }
            let status = match c.status {
                CheckStatus::Pass => "pass",
                CheckStatus::Warn => "warn",
                CheckStatus::Fail => "fail",
            };
            let fix = c
                .fix_applied
                .as_deref()
                .map(|s| format!(",\"fix_applied\":\"{}\"", json_esc(s)))
                .unwrap_or_default();
            format!(
                "{{\"name\":\"{}\",\"status\":\"{status}\",\"message\":\"{}\"{}}}",
                c.name,
                json_esc(&c.message),
                fix,
            )
        })
        .collect();
    println!("[{}]", items.join(","));
    if any_fail {
        1
    } else {
        0
    }
}

// ── check 1: PID ratio ────────────────────────────────────────────────────────

fn check_pid_ratio(lock_dir: &Path, repo_root: &Path) -> CheckResult {
    let fleet_size = read_fleet_size(lock_dir, repo_root);
    let claude_pids = count_claude_pids();
    let expected = fleet_size * 2;

    if fleet_size == 0 {
        return CheckResult {
            name: "pid_ratio",
            status: CheckStatus::Warn,
            message: "fleet_worker_count=0 (no fleet-desired-size file); skipping PID ratio check"
                .into(),
            fix_applied: None,
        };
    }

    if claude_pids == expected {
        CheckResult {
            name: "pid_ratio",
            status: CheckStatus::Pass,
            message: format!("claude_pids={claude_pids} == 2×fleet_workers={fleet_size}"),
            fix_applied: None,
        }
    } else {
        CheckResult {
            name: "pid_ratio",
            status: CheckStatus::Warn,
            message: format!(
                "claude_pids={claude_pids} != 2×fleet_workers={fleet_size} (expected {expected})"
            ),
            fix_applied: None,
        }
    }
}

fn read_fleet_size(lock_dir: &Path, repo_root: &Path) -> u32 {
    // Try .chump/fleet-desired-size in main repo root (not worktree).
    let candidates = [
        repo_root.join(".chump/fleet-desired-size"),
        lock_dir
            .parent()
            .unwrap_or(repo_root)
            .join(".chump/fleet-desired-size"),
    ];
    for p in &candidates {
        if let Ok(s) = std::fs::read_to_string(p) {
            if let Ok(n) = s.trim().parse::<u32>() {
                return n;
            }
        }
    }
    // Fall back: count tmux fleet-worker-N windows.
    std::process::Command::new("tmux")
        .args(["list-windows", "-t", "chump-fleet", "-F", "#W"])
        .output()
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| l.starts_with("fleet-worker-"))
                .count() as u32
        })
        .unwrap_or(0)
}

fn count_claude_pids() -> u32 {
    // pgrep -x claude counts exact-name matches; -f would include substrings.
    std::process::Command::new("pgrep")
        .args(["-x", "claude"])
        .output()
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.trim().is_empty())
                .count() as u32
        })
        .unwrap_or(0)
}

// ── check 2: stale gap-locks ──────────────────────────────────────────────────

fn check_stale_gap_locks(lock_dir: &Path, repo_root: &Path, fix: bool) -> CheckResult {
    let entries = match std::fs::read_dir(lock_dir) {
        Ok(e) => e,
        Err(_) => {
            return CheckResult {
                name: "stale_gap_locks",
                status: CheckStatus::Pass,
                message: "lock dir absent — no stale locks possible".into(),
                fix_applied: None,
            };
        }
    };

    let db_path = repo_root.join(".chump/state.db");
    let conn = rusqlite::Connection::open_with_flags(
        &db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok();

    let mut stale: Vec<PathBuf> = Vec::new();
    for entry in entries.flatten() {
        let fname = entry.file_name();
        let name = fname.to_string_lossy();
        // Pattern: .gap-<ID>.lock
        if !name.starts_with(".gap-") || !name.ends_with(".lock") {
            continue;
        }
        let gap_id = &name[5..name.len() - 5]; // strip ".gap-" and ".lock"
        if gap_is_done(&conn, gap_id) {
            stale.push(entry.path());
        }
    }

    if stale.is_empty() {
        return CheckResult {
            name: "stale_gap_locks",
            status: CheckStatus::Pass,
            message: "no stale .gap-*.lock files for done gaps".into(),
            fix_applied: None,
        };
    }

    let names: Vec<String> = stale
        .iter()
        .map(|p| {
            p.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()
        })
        .collect();

    if fix {
        let mut removed = Vec::new();
        for p in &stale {
            if std::fs::remove_file(p).is_ok() {
                removed.push(
                    p.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
        return CheckResult {
            name: "stale_gap_locks",
            status: CheckStatus::Pass,
            message: format!("removed {} stale lock(s)", removed.len()),
            fix_applied: Some(format!("rm {}", removed.join(", "))),
        };
    }

    CheckResult {
        name: "stale_gap_locks",
        status: CheckStatus::Fail,
        message: format!("stale locks for done gaps: {}", names.join(", ")),
        fix_applied: None,
    }
}

fn gap_is_done(conn: &Option<rusqlite::Connection>, gap_id: &str) -> bool {
    let conn = match conn {
        Some(c) => c,
        None => return false,
    };
    conn.query_row(
        "SELECT status FROM gaps WHERE id=?1",
        rusqlite::params![gap_id],
        |row| row.get::<_, String>(0),
    )
    .ok()
    .map(|s| s == "done" || s == "closed" || s == "shipped")
    .unwrap_or(false)
}

// ── check 3: orphan claudes (PPID=1, alive >60s) ─────────────────────────────

fn check_orphan_claudes(fix: bool) -> CheckResult {
    let orphans = find_orphan_claudes();

    if orphans.is_empty() {
        return CheckResult {
            name: "orphan_claudes",
            status: CheckStatus::Pass,
            message: "no claude processes with PPID=1 alive >60s".into(),
            fix_applied: None,
        };
    }

    let pids: Vec<String> = orphans.iter().map(|p| p.to_string()).collect();

    if fix {
        let mut killed = Vec::new();
        for &pid in &orphans {
            let ok = std::process::Command::new("kill")
                .args(["-TERM", &pid.to_string()])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                killed.push(pid.to_string());
            }
        }
        return CheckResult {
            name: "orphan_claudes",
            status: CheckStatus::Pass,
            message: format!("killed {} orphan(s)", killed.len()),
            fix_applied: Some(format!("kill -TERM {}", killed.join(" "))),
        };
    }

    CheckResult {
        name: "orphan_claudes",
        status: CheckStatus::Fail,
        message: format!("orphan claude PIDs (PPID=1, >60s): {}", pids.join(", ")),
        fix_applied: None,
    }
}

/// Returns PIDs of `claude` processes whose PPID is 1 and etime > 60s.
fn find_orphan_claudes() -> Vec<u32> {
    // macOS `ps` output: PPID PID ETIME COMM
    // etime format: [[dd-]hh:]mm:ss
    let output = match std::process::Command::new("ps")
        .args(["-eo", "ppid,pid,etime,comm"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return vec![],
    };
    let text = String::from_utf8_lossy(&output.stdout);
    let mut orphans = Vec::new();
    for line in text.lines().skip(1) {
        // Normalize whitespace
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 4 {
            continue;
        }
        let ppid: u32 = match cols[0].parse() {
            Ok(n) => n,
            Err(_) => continue,
        };
        let pid: u32 = match cols[1].parse() {
            Ok(n) => n,
            Err(_) => continue,
        };
        let etime = cols[2];
        let comm = cols[3];
        if ppid != 1 {
            continue;
        }
        if !comm.contains("claude") {
            continue;
        }
        if etime_to_secs(etime) > 60 {
            orphans.push(pid);
        }
    }
    orphans
}

/// Parse ps etime format `[[dd-]hh:]mm:ss` into total seconds.
fn etime_to_secs(etime: &str) -> u64 {
    // Split off optional day part first.
    let (days, rest) = if let Some(pos) = etime.find('-') {
        let d: u64 = etime[..pos].parse().unwrap_or(0);
        (d, &etime[pos + 1..])
    } else {
        (0, etime)
    };
    let parts: Vec<&str> = rest.split(':').collect();
    
    match parts.len() {
        3 => {
            let h: u64 = parts[0].parse().unwrap_or(0);
            let m: u64 = parts[1].parse().unwrap_or(0);
            let s: u64 = parts[2].parse().unwrap_or(0);
            days * 86400 + h * 3600 + m * 60 + s
        }
        2 => {
            let m: u64 = parts[0].parse().unwrap_or(0);
            let s: u64 = parts[1].parse().unwrap_or(0);
            days * 86400 + m * 60 + s
        }
        1 => {
            let s: u64 = parts[0].parse().unwrap_or(0);
            days * 86400 + s
        }
        _ => 0,
    }
}

// ── check 4: waste-tally last 30 min ─────────────────────────────────────────

fn check_waste_tally(repo_root: &Path) -> CheckResult {
    let thirty_min = 30 * 60;
    let report = crate::waste_tally::build_report(repo_root, thirty_min);

    let wedge_count: u64 = report
        .entries
        .iter()
        .find(|e| e.kind == "fleet_wedge")
        .map(|e| e.incidents)
        .unwrap_or(0);

    // Unrecognized kinds: read raw ambient for kinds not in WASTE_KINDS and
    // not in an allow-list of routine event kinds.
    let unrecognized = unrecognized_kinds_in_window(repo_root, thirty_min);

    if wedge_count == 0 && unrecognized.is_empty() {
        return CheckResult {
            name: "waste_tally_30m",
            status: CheckStatus::Pass,
            message: format!(
                "no fleet_wedge events; {} total incidents in last 30m",
                report.total_incidents
            ),
            fix_applied: None,
        };
    }

    let mut parts = Vec::new();
    if wedge_count > 0 {
        parts.push(format!("fleet_wedge incidents={wedge_count}"));
    }
    if !unrecognized.is_empty() {
        parts.push(format!("unrecognized kinds: {}", unrecognized.join(",")));
    }

    CheckResult {
        name: "waste_tally_30m",
        status: CheckStatus::Warn,
        message: parts.join("; "),
        fix_applied: None,
    }
}

/// Return event kinds appearing in ambient.jsonl in the last `since_secs`
/// that are not in WASTE_KINDS and not in the routine-events allow-list.
fn unrecognized_kinds_in_window(repo_root: &Path, since_secs: u64) -> Vec<String> {
    let ambient = resolve_lock_dir(repo_root).join("ambient.jsonl");
    let text = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = current_unix();
    let cutoff = now.saturating_sub(since_secs);

    // Kinds that are normal fleet traffic — not waste, not alerts.
    const ROUTINE: &[&str] = &[
        "session_start",
        "session_end",
        "gap_claimed",
        "gap_shipped",
        "fleet_scale_request",
        "fleet_scale_change",
        "fleet_doctor_report",
        "gap_reserved",
        "gap_released",
        "worker_start",
        "worker_exit",
        "heartbeat",
        "lesson_injected",
        "escalation",
        "gap_preflight",
        "git_push",
        "pr_opened",
        "pr_merged",
        "pr_closed",
        "ci_pass",
        "ci_fail",
        "merge_queue_enter",
        "merge_queue_exit",
        "ambient_rotated",
        "lease_renewed",
        "lease_released",
        "queue_config_drift",
        "subagent_budget_exceeded",
        "lessons_injection_active",
        "pr_stuck", // classified as waste — already in WASTE_KINDS
    ];

    let known: std::collections::HashSet<&str> = crate::waste_tally::WASTE_KINDS
        .iter()
        .copied()
        .chain(ROUTINE.iter().copied())
        .collect();

    let mut unknown = std::collections::BTreeSet::new();
    for line in text.lines() {
        if let Some(ts_str) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts_str) {
                if unix < cutoff {
                    continue;
                }
            }
        }
        if let Some(kind) = extract_field(line, "kind") {
            if !known.contains(kind.as_str()) && !kind.is_empty() {
                unknown.insert(kind);
            }
        }
    }
    unknown.into_iter().collect()
}

// ── check 5: ambient ALERTs in last 5 min ────────────────────────────────────

fn check_ambient_alerts(lock_dir: &Path) -> CheckResult {
    let ambient = lock_dir.join("ambient.jsonl");
    let text = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = current_unix();
    let cutoff = now.saturating_sub(5 * 60);

    let mut alerts: Vec<String> = Vec::new();
    for line in text.lines() {
        if !line.contains(r#""event":"ALERT""#) && !line.contains(r#""ALERT""#) {
            continue;
        }
        if let Some(ts_str) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts_str) {
                if unix < cutoff {
                    continue;
                }
            }
        }
        let kind = extract_field(line, "kind").unwrap_or_else(|| "(unknown)".into());
        let note = extract_field(line, "note").unwrap_or_default();
        alerts.push(if note.is_empty() {
            kind
        } else {
            format!("{kind}: {note}")
        });
    }

    if alerts.is_empty() {
        return CheckResult {
            name: "ambient_alerts_5m",
            status: CheckStatus::Pass,
            message: "no ALERT events in ambient.jsonl in last 5 min".into(),
            fix_applied: None,
        };
    }

    CheckResult {
        name: "ambient_alerts_5m",
        status: CheckStatus::Warn,
        message: format!("{} ALERT(s): {}", alerts.len(), alerts.join("; ")),
        fix_applied: None,
    }
}

// ── ambient emit ──────────────────────────────────────────────────────────────

fn emit_ambient_report(repo_root: &Path, lock_dir: &Path, report: &DoctorReport) {
    let ambient = lock_dir.join("ambient.jsonl");
    let _ = std::fs::create_dir_all(lock_dir);
    let overall = if report.overall_ok() {
        "ok"
    } else {
        "degraded"
    };
    let fail_count = report
        .checks
        .iter()
        .filter(|c| c.status == CheckStatus::Fail)
        .count();
    let warn_count = report
        .checks
        .iter()
        .filter(|c| c.status == CheckStatus::Warn)
        .count();
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let session = read_session_id(repo_root);
    let json = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"fleet_doctor_report\",\"overall\":\"{overall}\",\
         \"fail\":{fail_count},\"warn\":{warn_count},\"session\":\"{session}\"}}",
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{json}");
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn resolve_lock_dir(repo_root: &Path) -> PathBuf {
    std::env::var("CHUMP_AMBIENT_LOG")
        .ok()
        .map(PathBuf::from)
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| repo_root.join(".chump-locks"))
}

fn read_session_id(repo_root: &Path) -> String {
    std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("SESSION_ID"))
        .unwrap_or_else(|_| {
            std::fs::read_to_string(repo_root.join(".chump/session_id"))
                .unwrap_or_default()
                .trim()
                .to_string()
        })
}

fn current_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    // Fast path: "2026-05-06T19:03:42Z" — avoid pulling chrono parse.
    // Handles the subset that ambient.jsonl actually emits.
    let s = s.trim_end_matches('Z');
    let s = s.replace('T', " ");
    let parts: Vec<&str> = s.split(' ').collect();
    if parts.len() != 2 {
        return None;
    }
    let date: Vec<u32> = parts[0]
        .split('-')
        .map(|x| x.parse().unwrap_or(0))
        .collect();
    let time: Vec<u32> = parts[1]
        .split(':')
        .map(|x| x.parse().unwrap_or(0))
        .collect();
    if date.len() != 3 || time.len() != 3 {
        return None;
    }
    // Delegate to chrono for correctness.
    use chrono::{TimeZone, Utc};
    Utc.with_ymd_and_hms(date[0] as i32, date[1], date[2], time[0], time[1], time[2])
        .single()
        .map(|dt| dt.timestamp() as u64)
}

/// Extract a JSON string-field value from a flat JSON line (no nested objects).
fn extract_field(line: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":\"", key);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn json_esc(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}
