//! EFFECTIVE-1136 (EFFECTIVE-178 slice): `chump unwedge <gap>` — on-demand
//! kill + recover of a wedged bot-merge for a single gap.
//!
//! Detection reads the per-gap progress ledger bot-merge.sh writes at
//! `.chump-locks/bot-merge-progress/<gap-slug>.json` (INFRA-2272) and cross-
//! checks for a live `bot-merge.sh --gap <GAP>` process via `pgrep -f`. A gap
//! is considered wedged when either signal is present: a live matching
//! process, or a progress ledger whose `last_progress_ts` is older than the
//! staleness threshold (default 900s, matching CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S
//! in CLAUDE.md).
//!
//! Recovery shells out to `chump claim <GAP> --force-recover` (optionally
//! `--discard-wip`) rather than reimplementing worktree/branch cleanup —
//! that flow is already the tested, canonical recovery path (INFRA-1439 /
//! INFRA-2235).
//!
//! Ambient events emitted: kind=chump_unwedge (single summary event per run).

use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::repo_path;

const DEFAULT_STALE_THRESHOLD_S: i64 = 900;

#[derive(Debug, Default, Clone)]
pub struct UnwedgeOpts {
    pub dry_run: bool,
    pub discard_wip: bool,
    /// force recovery even when no wedge signal was detected
    pub force: bool,
    pub threshold_s: i64,
}

#[derive(Debug, Deserialize)]
struct ProgressLedger {
    step_name: String,
    #[serde(default)]
    started_at: String,
    last_progress_ts: String,
    #[serde(default)]
    pid: i64,
}

fn slugify(gap_id: &str) -> String {
    gap_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect()
}

fn progress_ledger_path(repo_root: &Path, gap_id: &str) -> PathBuf {
    repo_root
        .join(".chump-locks")
        .join("bot-merge-progress")
        .join(format!("{}.json", slugify(gap_id)))
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn parse_rfc3339_unix(ts: &str) -> Option<i64> {
    // Progress ledger writes `date -u +%Y-%m-%dT%H:%M:%SZ`. Parse without
    // pulling in chrono: minimal manual parse of that exact fixed shape.
    let ts = ts.trim();
    if ts.len() != 20 || !ts.ends_with('Z') {
        return None;
    }
    let y: i64 = ts.get(0..4)?.parse().ok()?;
    let mo: i64 = ts.get(5..7)?.parse().ok()?;
    let d: i64 = ts.get(8..10)?.parse().ok()?;
    let h: i64 = ts.get(11..13)?.parse().ok()?;
    let mi: i64 = ts.get(14..16)?.parse().ok()?;
    let s: i64 = ts.get(17..19)?.parse().ok()?;
    // Days since epoch via a simple civil-to-days algorithm (Howard Hinnant).
    let (y, mo) = if mo <= 2 { (y - 1, mo + 12) } else { (y, mo) };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as i64;
    let doy = (153 * (mo - 3) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + h * 3600 + mi * 60 + s)
}

fn read_ledger(path: &Path) -> Option<ProgressLedger> {
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

/// Find live PIDs of processes matching `bot-merge.sh --gap <gap_id>` via pgrep.
fn find_live_bot_merge_pids(gap_id: &str) -> Vec<i64> {
    let pattern = format!("bot-merge.sh.*--gap[= ]{}", regex_escape(gap_id));
    let out = Command::new("pgrep").arg("-f").arg(&pattern).output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter_map(|l| l.trim().parse::<i64>().ok())
            .collect(),
        _ => Vec::new(),
    }
}

fn regex_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if "\\.+*?()|[]{}^$".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

fn pid_alive(pid: i64) -> bool {
    Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn kill_pid(pid: i64, log: &mut Vec<String>) {
    log.push(format!("KILL: sending SIGTERM to pid {pid}"));
    let _ = Command::new("kill")
        .arg("-TERM")
        .arg(pid.to_string())
        .status();
    std::thread::sleep(std::time::Duration::from_secs(2));
    if pid_alive(pid) {
        log.push(format!(
            "KILL: pid {pid} still alive after SIGTERM, sending SIGKILL"
        ));
        let _ = Command::new("kill")
            .arg("-KILL")
            .arg(pid.to_string())
            .status();
    } else {
        log.push(format!("KILL: pid {pid} exited cleanly after SIGTERM"));
    }
}

fn emit_ambient(repo_root: &Path, gap_id: &str, wedge_found: bool, killed: &[i64], recovered: bool, clean: bool) {
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono_now_rfc3339();
    let killed_str = killed
        .iter()
        .map(|p| p.to_string())
        .collect::<Vec<_>>()
        .join(",");
    // scanner-anchor: "kind":"chump_unwedge"
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"chump_unwedge\",\"gap_id\":\"{gap_id}\",\"wedge_found\":{wedge_found},\"killed_pids\":[{killed_str}],\"recovered\":{recovered},\"clean\":{clean}}}\n"
    );
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&ambient) {
        use std::io::Write;
        let _ = f.write_all(line.as_bytes());
    }
}

fn chrono_now_rfc3339() -> String {
    let out = Command::new("date")
        .arg("-u")
        .arg("+%Y-%m-%dT%H:%M:%SZ")
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::from("1970-01-01T00:00:00Z"),
    }
}

/// Run `git status --porcelain` in `dir` and report whether it's clean.
fn worktree_is_clean(dir: &Path) -> Option<bool> {
    if !dir.is_dir() {
        return None;
    }
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .arg("status")
        .arg("--porcelain")
        .output()
        .ok()?;
    Some(out.status.success() && out.stdout.is_empty())
}

pub fn run(gap_id: &str, opts: UnwedgeOpts) -> Result<()> {
    let threshold_s = if opts.threshold_s > 0 {
        opts.threshold_s
    } else {
        DEFAULT_STALE_THRESHOLD_S
    };
    let repo_root = repo_path::repo_root();
    let mut log: Vec<String> = Vec::new();

    log.push(format!("START: chump unwedge {gap_id} (repo={})", repo_root.display()));

    // ── Detect ──────────────────────────────────────────────────────────
    let ledger_path = progress_ledger_path(&repo_root, gap_id);
    let ledger = read_ledger(&ledger_path);
    let live_pids = find_live_bot_merge_pids(gap_id);

    let mut stale_ledger = false;
    if let Some(ref l) = ledger {
        let age_s = match parse_rfc3339_unix(&l.last_progress_ts) {
            Some(ts) => now_unix() - ts,
            None => i64::MAX,
        };
        log.push(format!(
            "DETECT: progress ledger found at {} (step={}, started_at={}, last_progress_ts={}, age={}s, pid={})",
            ledger_path.display(),
            l.step_name,
            l.started_at,
            l.last_progress_ts,
            age_s,
            l.pid
        ));
        stale_ledger = age_s >= threshold_s;
        if stale_ledger {
            log.push(format!(
                "DETECT: ledger is stale (age {age_s}s >= threshold {threshold_s}s) — wedge signal"
            ));
        }
    } else {
        log.push(format!(
            "DETECT: no progress ledger at {}",
            ledger_path.display()
        ));
    }

    if live_pids.is_empty() {
        log.push(format!(
            "DETECT: no live bot-merge.sh process found for gap {gap_id}"
        ));
    } else {
        log.push(format!(
            "DETECT: live bot-merge.sh process(es) found for gap {gap_id}: {:?}",
            live_pids
        ));
    }

    let wedge_found = stale_ledger || !live_pids.is_empty();

    if !wedge_found && !opts.force {
        log.push(format!(
            "DETECT: no wedge detected for {gap_id} — nothing to kill or recover (pass --force to run recovery anyway)"
        ));
        for l in &log {
            println!("{l}");
        }
        if !opts.dry_run {
            emit_ambient(&repo_root, gap_id, false, &[], false, true);
        }
        return Ok(());
    }

    if !wedge_found && opts.force {
        log.push("DETECT: no wedge signal, but --force passed — proceeding to recovery".to_string());
    }

    // ── Kill ────────────────────────────────────────────────────────────
    let mut killed_pids: Vec<i64> = Vec::new();
    let mut candidate_pids = live_pids.clone();
    if let Some(ref l) = ledger {
        if l.pid > 0 && pid_alive(l.pid) && !candidate_pids.contains(&l.pid) {
            candidate_pids.push(l.pid);
        }
    }

    if candidate_pids.is_empty() {
        log.push("KILL: no live pid to terminate (process already exited)".to_string());
    } else if opts.dry_run {
        log.push(format!("KILL: DRY-RUN would terminate pid(s) {:?}", candidate_pids));
    } else {
        for pid in &candidate_pids {
            kill_pid(*pid, &mut log);
            killed_pids.push(*pid);
        }
    }

    // Stale progress ledger is no longer meaningful once we've intervened.
    if ledger_path.exists() && !opts.dry_run {
        match std::fs::remove_file(&ledger_path) {
            Ok(()) => log.push(format!("KILL: removed stale progress ledger {}", ledger_path.display())),
            Err(e) => log.push(format!(
                "KILL: WARNING failed to remove progress ledger {}: {e}",
                ledger_path.display()
            )),
        }
    }

    // ── Recover ─────────────────────────────────────────────────────────
    let mut recovered = false;
    if opts.dry_run {
        log.push(format!(
            "RECOVER: DRY-RUN would run `chump claim {gap_id} --force-recover{}`",
            if opts.discard_wip { " --discard-wip" } else { "" }
        ));
    } else {
        let exe = std::env::current_exe().context("resolving current chump executable path")?;
        let mut cmd = Command::new(&exe);
        cmd.arg("claim").arg(gap_id).arg("--force-recover");
        if opts.discard_wip {
            cmd.arg("--discard-wip");
        }
        cmd.current_dir(&repo_root);
        log.push(format!(
            "RECOVER: invoking `chump claim {gap_id} --force-recover{}`",
            if opts.discard_wip { " --discard-wip" } else { "" }
        ));
        match cmd.output() {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                for l in stdout.lines() {
                    log.push(format!("RECOVER:   {l}"));
                }
                for l in stderr.lines() {
                    log.push(format!("RECOVER:   {l}"));
                }
                recovered = out.status.success();
                log.push(format!(
                    "RECOVER: claim --force-recover exited {}",
                    out.status
                ));
            }
            Err(e) => {
                log.push(format!("RECOVER: failed to spawn claim --force-recover: {e}"));
            }
        }
    }

    // ── Verify clean state ──────────────────────────────────────────────
    // Recovered worktree naming follows `chump claim`'s convention; verify
    // the repo root itself (main checkout) is clean since --force-recover
    // operates on shared worktree/branch bookkeeping there.
    let clean = if opts.dry_run {
        log.push("VERIFY: DRY-RUN skipping clean-state check".to_string());
        true
    } else {
        match worktree_is_clean(&repo_root) {
            Some(true) => {
                log.push("VERIFY: repository is clean".to_string());
                true
            }
            Some(false) => {
                log.push(
                    "VERIFY: repository has uncommitted changes — review before re-claiming".to_string(),
                );
                false
            }
            None => {
                log.push(format!("VERIFY: could not stat {}", repo_root.display()));
                false
            }
        }
    };

    log.push(format!(
        "DONE: unwedge {gap_id} complete (wedge_found={wedge_found}, killed={:?}, recovered={recovered}, clean={clean})",
        killed_pids
    ));

    for l in &log {
        println!("{l}");
    }

    if !opts.dry_run {
        emit_ambient(&repo_root, gap_id, wedge_found, &killed_pids, recovered, clean);
    }

    Ok(())
}
