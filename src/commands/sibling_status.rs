//! META-154: `chump sibling-status` — per-active-lease progress matrix.
//!
//! For each `.chump-locks/claim-*.json` file, classify the holder as
//! one of {progressing, in-flight, heartbeat-only, stalled, silent,
//! expired} by cross-referencing the lease metadata against the ambient
//! event stream and the git log of the worktree path (if recoverable).
//!
//! Reads directly from `.chump-locks/ambient.jsonl` (no NATS dep, works
//! offline). Targets < 500ms total over 10k ambient lines via a single
//! reverse-scan that records the most-recent per-session timestamps for
//! the kinds we care about.
//!
//! Output: human-readable table by default; `--json` emits structured
//! array for tooling. `--watch` polls every 30s with a redraw.
//!
//! Acceptance criteria satisfied:
//!   AC1 — CLI exists, table + --json
//!   AC2 — per-lease columns (gap_id, session_id, age, last_*, classification)
//!   AC3 — 6 status classifications
//!   AC4 — SessionStart digest hook will be wired separately
//!   AC5 — --watch mode redraws every 30s
//!   AC6 — emits kind=sibling_status_polled on each non-watch invocation
//!   AC7 — test fixture covers all 6 classifications
//!   AC8 — file-only reads, < 500ms target

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{exit, Command};

const RECENT_WINDOW_SECS: i64 = 30 * 60; // 30 minutes
const HEARTBEAT_WINDOW_SECS: i64 = 60 * 60; // 1 hour
const STALL_LEASE_AGE_SECS: i64 = 2 * 60 * 60; // 2 hours

#[derive(Debug, Clone)]
struct Lease {
    gap_id: String,
    session_id: String,
    taken_at: String,
    expires_at: String,
    paths: Vec<String>,
}

#[derive(Debug, Default, Clone)]
struct SessionActivity {
    last_file_edit_ts: Option<String>,
    last_broadcast_ts: Option<String>,
    last_heartbeat_ts: Option<String>,
}

#[derive(Debug)]
struct StatusRow {
    gap_id: String,
    session_id: String,
    age_secs: i64,
    last_commit_ts: Option<String>,
    last_file_edit_ts: Option<String>,
    last_broadcast_ts: Option<String>,
    last_heartbeat_ts: Option<String>,
    classification: &'static str,
    is_expired: bool,
}

fn repo_root() -> PathBuf {
    let mut p = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        if p.join(".chump-locks").is_dir()
            || p.join("Cargo.toml").is_file() && p.join("scripts").is_dir()
        {
            return p;
        }
        if !p.pop() {
            return std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        }
    }
}

fn parse_ts_secs(ts: &str) -> Option<i64> {
    // RFC3339 minimal: "2026-05-30T05:48:01Z" -> seconds since epoch (approximate).
    // We only need ordering + relative deltas, not calendrical correctness.
    let trimmed = ts.trim_end_matches('Z');
    let parts: Vec<&str> = trimmed
        .split(|c: char| c == 'T' || c == '-' || c == ':')
        .collect();
    if parts.len() < 6 {
        return None;
    }
    let y: i64 = parts[0].parse().ok()?;
    let mo: i64 = parts[1].parse().ok()?;
    let d: i64 = parts[2].parse().ok()?;
    let h: i64 = parts[3].parse().ok()?;
    let mi: i64 = parts[4].parse().ok()?;
    let s: i64 = parts[5].parse().ok()?;
    // Naive day-count (ignore leap years, sufficient for relative comparisons):
    let days = (y - 1970) * 365 + (mo - 1) * 30 + (d - 1);
    Some(days * 86400 + h * 3600 + mi * 60 + s)
}

fn now_secs() -> i64 {
    let s = Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    parse_ts_secs(s.trim()).unwrap_or(0)
}

fn iso_now() -> String {
    Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn read_leases(lock_dir: &Path) -> Vec<Lease> {
    let mut out = Vec::new();
    let entries = match fs::read_dir(lock_dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for entry in entries.flatten() {
        let p = entry.path();
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if !(name.starts_with("claim-") && name.ends_with(".json")) {
            continue;
        }
        let raw = match fs::read_to_string(&p) {
            Ok(s) => s,
            Err(_) => continue,
        };
        let gap_id = field(&raw, "gap_id");
        let session_id = field(&raw, "session_id");
        let taken_at = field(&raw, "taken_at");
        let expires_at = field(&raw, "expires_at");
        let paths_str = field(&raw, "paths");
        let paths: Vec<String> = paths_str
            .split(',')
            .filter_map(|s| {
                let t = s
                    .trim()
                    .trim_matches(|c: char| c == '[' || c == ']' || c == '"');
                if t.is_empty() {
                    None
                } else {
                    Some(t.to_string())
                }
            })
            .collect();
        if !gap_id.is_empty() && !session_id.is_empty() {
            out.push(Lease {
                gap_id,
                session_id,
                taken_at,
                expires_at,
                paths,
            });
        }
    }
    out
}

/// Naive JSON string-field extractor: looks for "<key>":"<value>" pattern.
/// Sufficient for the well-formed claim-*.json files we control.
fn field(raw: &str, key: &str) -> String {
    let pat = format!("\"{}\":", key);
    let i = match raw.find(&pat) {
        Some(x) => x + pat.len(),
        None => return String::new(),
    };
    let rest = &raw[i..].trim_start();
    if let Some(stripped) = rest.strip_prefix('"') {
        if let Some(end) = stripped.find('"') {
            return stripped[..end].to_string();
        }
    } else if let Some(stripped) = rest.strip_prefix('[') {
        if let Some(end) = stripped.find(']') {
            return stripped[..end].to_string();
        }
    }
    String::new()
}

fn scan_ambient(ambient_path: &Path, sessions: &[&str]) -> HashMap<String, SessionActivity> {
    let mut out: HashMap<String, SessionActivity> = sessions
        .iter()
        .map(|s| (s.to_string(), SessionActivity::default()))
        .collect();
    let raw = match fs::read_to_string(ambient_path) {
        Ok(s) => s,
        Err(_) => return out,
    };
    // Reverse-iterate lines so the first hit per (session, kind) is the most recent.
    for line in raw.lines().rev() {
        let session = field(line, "session");
        if session.is_empty() || !out.contains_key(&session) {
            continue;
        }
        let kind = field(line, "kind");
        let ts = field(line, "ts");
        if ts.is_empty() {
            continue;
        }
        let act = out.get_mut(&session).unwrap();
        if kind == "file_edit" && act.last_file_edit_ts.is_none() {
            act.last_file_edit_ts = Some(ts.clone());
        } else if kind.ends_with("_heartbeat") && act.last_heartbeat_ts.is_none() {
            act.last_heartbeat_ts = Some(ts.clone());
        } else if (kind == "broadcast_emit"
            || matches!(
                kind.as_str(),
                "INTENT" | "HANDOFF" | "STUCK" | "DONE" | "WARN" | "ALERT" | "FEEDBACK"
            ))
            && act.last_broadcast_ts.is_none()
        {
            act.last_broadcast_ts = Some(ts.clone());
        }
        // Early exit when this session is fully populated:
        if act.last_file_edit_ts.is_some()
            && act.last_broadcast_ts.is_some()
            && act.last_heartbeat_ts.is_some()
            && out.values().all(|a| {
                a.last_file_edit_ts.is_some()
                    && a.last_broadcast_ts.is_some()
                    && a.last_heartbeat_ts.is_some()
            })
        {
            break;
        }
    }
    out
}

fn last_commit_for_paths(repo: &Path, paths: &[String]) -> Option<String> {
    if paths.is_empty() {
        return None;
    }
    let mut args = vec![
        "-C".to_string(),
        repo.to_string_lossy().to_string(),
        "log".to_string(),
        "-1".to_string(),
        "--format=%cI".to_string(),
        "--all".to_string(),
        "--".to_string(),
    ];
    for p in paths {
        args.push(p.clone());
    }
    let out = Command::new("git").args(&args).output().ok()?;
    let s = String::from_utf8(out.stdout).ok()?;
    let s = s.trim();
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

fn classify(
    now: i64,
    lease: &Lease,
    act: &SessionActivity,
    last_commit_ts: &Option<String>,
) -> (&'static str, bool) {
    let expires = parse_ts_secs(&lease.expires_at).unwrap_or(0);
    if expires > 0 && now > expires {
        return ("expired", true);
    }
    let taken = parse_ts_secs(&lease.taken_at).unwrap_or(now);
    let age = now - taken;

    let recent = |o: &Option<String>, window: i64| -> bool {
        o.as_ref()
            .and_then(|t| parse_ts_secs(t))
            .is_some_and(|ts| now - ts <= window)
    };

    let commit_recent = recent(last_commit_ts, RECENT_WINDOW_SECS);
    let edit_recent = recent(&act.last_file_edit_ts, RECENT_WINDOW_SECS);
    let broadcast_recent = recent(&act.last_broadcast_ts, RECENT_WINDOW_SECS);
    let heartbeat_recent_short = recent(&act.last_heartbeat_ts, RECENT_WINDOW_SECS);
    let heartbeat_recent_long = recent(&act.last_heartbeat_ts, HEARTBEAT_WINDOW_SECS);

    if commit_recent {
        return ("progressing", false);
    }
    if edit_recent {
        return ("in-flight", false);
    }
    if heartbeat_recent_short && !edit_recent && !broadcast_recent {
        return ("heartbeat-only", false);
    }
    if age > STALL_LEASE_AGE_SECS && !heartbeat_recent_short && !edit_recent && !broadcast_recent {
        return ("stalled", false);
    }
    if !heartbeat_recent_long {
        return ("silent", false);
    }
    ("heartbeat-only", false)
}

fn fmt_age(secs: i64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else {
        format!("{}h{:02}m", secs / 3600, (secs % 3600) / 60)
    }
}

fn short_ts(opt: &Option<String>) -> String {
    opt.as_ref()
        .map(|t| {
            t.split('T')
                .nth(1)
                .unwrap_or(t)
                .trim_end_matches('Z')
                .to_string()
        })
        .unwrap_or_else(|| "-".to_string())
}

fn render_table(rows: &[StatusRow]) {
    println!(
        "{:<14} {:<48} {:>8} {:<10} {:<10} {:<10} {:<10} STATUS",
        "GAP", "SESSION", "AGE", "COMMIT", "EDIT", "BROADCAST", "BEAT"
    );
    for r in rows {
        let status_marker = if r.is_expired {
            format!("{} (lease past TTL)", r.classification)
        } else {
            r.classification.to_string()
        };
        println!(
            "{:<14} {:<48} {:>8} {:<10} {:<10} {:<10} {:<10} {}",
            r.gap_id,
            if r.session_id.len() > 48 {
                format!("{}…", &r.session_id[..47])
            } else {
                r.session_id.clone()
            },
            fmt_age(r.age_secs),
            short_ts(&r.last_commit_ts),
            short_ts(&r.last_file_edit_ts),
            short_ts(&r.last_broadcast_ts),
            short_ts(&r.last_heartbeat_ts),
            status_marker
        );
    }
    if rows.is_empty() {
        println!("(no active sibling leases)");
    }
}

fn render_json(rows: &[StatusRow]) {
    let parts: Vec<String> = rows.iter().map(|r| format!(
        "{{\"gap_id\":\"{}\",\"session_id\":\"{}\",\"age_secs\":{},\"last_commit_ts\":{},\"last_file_edit_ts\":{},\"last_broadcast_ts\":{},\"last_heartbeat_ts\":{},\"classification\":\"{}\",\"expired\":{}}}",
        r.gap_id, r.session_id, r.age_secs,
        opt_quote(&r.last_commit_ts),
        opt_quote(&r.last_file_edit_ts),
        opt_quote(&r.last_broadcast_ts),
        opt_quote(&r.last_heartbeat_ts),
        r.classification, r.is_expired)).collect();
    println!("[{}]", parts.join(","));
}

fn opt_quote(o: &Option<String>) -> String {
    o.as_ref()
        .map(|s| format!("\"{}\"", s))
        .unwrap_or_else(|| "null".to_string())
}

fn emit_poll_event(lock_dir: &Path, rows: &[StatusRow]) {
    let mut counts: HashMap<&str, u32> = HashMap::new();
    let mut expired = 0u32;
    for r in rows {
        *counts.entry(r.classification).or_insert(0) += 1;
        if r.is_expired {
            expired += 1;
        }
    }
    let count = |k: &str| counts.get(k).copied().unwrap_or(0);
    let json = format!(
        "{{\"ts\":\"{}\",\"kind\":\"sibling_status_polled\",\"progressing\":{},\"in_flight\":{},\"heartbeat_only\":{},\"stalled\":{},\"silent\":{},\"expired\":{}}}",
        iso_now(), count("progressing"), count("in-flight"), count("heartbeat-only"), count("stalled"), count("silent"), expired);
    let path = lock_dir.join("ambient.jsonl");
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{}", json);
    }
}

fn one_pass(repo: &Path, lock_dir: &Path, ambient_path: &Path) -> Vec<StatusRow> {
    let now = now_secs();
    let leases = read_leases(lock_dir);
    let sessions: Vec<&str> = leases.iter().map(|l| l.session_id.as_str()).collect();
    let activity = scan_ambient(ambient_path, &sessions);
    let mut rows = Vec::new();
    for l in &leases {
        let act = activity.get(&l.session_id).cloned().unwrap_or_default();
        let last_commit_ts = last_commit_for_paths(repo, &l.paths);
        let (cls, expired) = classify(now, l, &act, &last_commit_ts);
        let age_secs = now - parse_ts_secs(&l.taken_at).unwrap_or(now);
        rows.push(StatusRow {
            gap_id: l.gap_id.clone(),
            session_id: l.session_id.clone(),
            age_secs,
            last_commit_ts,
            last_file_edit_ts: act.last_file_edit_ts.clone(),
            last_broadcast_ts: act.last_broadcast_ts.clone(),
            last_heartbeat_ts: act.last_heartbeat_ts.clone(),
            classification: cls,
            is_expired: expired,
        });
    }
    rows
}

pub fn run(args: &[String]) -> i32 {
    let json = args.iter().any(|a| a == "--json");
    let watch = args.iter().any(|a| a == "--watch");
    let repo = repo_root();
    let lock_dir = repo.join(".chump-locks");
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    if watch {
        loop {
            let rows = one_pass(&repo, &lock_dir, &ambient_path);
            print!("\x1b[2J\x1b[H");
            println!("chump sibling-status — {}  (Ctrl-C to exit)", iso_now());
            if json {
                render_json(&rows);
            } else {
                render_table(&rows);
            }
            std::thread::sleep(std::time::Duration::from_secs(30));
        }
    }

    let rows = one_pass(&repo, &lock_dir, &ambient_path);
    if json {
        render_json(&rows);
    } else {
        render_table(&rows);
    }
    emit_poll_event(&lock_dir, &rows);
    exit(0);
}
