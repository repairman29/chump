//! Activation funnel telemetry (PRODUCT-015).
//!
//! Emits three `kind=activation_*` events into `.chump-locks/ambient.jsonl`:
//!   - `activation_install`    — first `chump init`
//!   - `activation_first_task` — first successfully-completed task
//!   - `activation_return_d2`  — first session launched > 24h after install
//!
//! State markers live under `.chump/activation/` (JSONL-indexed, not SQLite —
//! activation is a boot-path check, we want zero deps). Each marker file exists
//! once emitted; presence is the dedup check.
//!
//! Privacy posture: events are local-only (written to the existing ambient.jsonl
//! stream). No remote endpoint. Fields are session-ID + UTC timestamp only — no
//! prompt content, no file paths, no user identity. `CHUMP_ACTIVATION_DISABLED=1`
//! opts out of all three emissions.
//!
//! Reader: `chump funnel` tallies the three kinds and prints a three-row table.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

// ── public API ────────────────────────────────────────────────────────────────

/// Best-effort: emit `activation_install` if not already emitted. Safe to call
/// from `chump init` on every run — subsequent calls no-op via marker.
pub fn emit_install() {
    if disabled() {
        return;
    }
    let base = activation_dir();
    let marker = base.join("installed_at");
    if marker.exists() {
        return;
    }
    let _ = fs::create_dir_all(&base);
    emit_event("activation_install");
    let _ = fs::write(&marker, iso_now());
}

/// Best-effort: emit `activation_first_task` if no task has been completed
/// before. Called from `task_db::task_complete` on successful transitions to
/// `done`.
pub fn emit_first_task_if_new() {
    if disabled() {
        return;
    }
    let base = activation_dir();
    let marker = base.join("first_task_at");
    if marker.exists() {
        return;
    }
    let _ = fs::create_dir_all(&base);
    emit_event("activation_first_task");
    let _ = fs::write(&marker, iso_now());
}

/// Best-effort: emit `activation_return_d2` if install happened more than 24h
/// ago AND the d2 event hasn't already fired. Called once per process at
/// session start.
pub fn emit_return_d2_if_due() {
    if disabled() {
        return;
    }
    let base = activation_dir();
    let installed_marker = base.join("installed_at");
    let d2_marker = base.join("d2_return_at");

    if d2_marker.exists() {
        return;
    }
    let Ok(installed_at) = fs::read_to_string(&installed_marker) else {
        return;
    };
    let installed_at = installed_at.trim();
    if installed_at.is_empty() {
        return;
    }
    let Ok(installed) = chrono::DateTime::parse_from_rfc3339(installed_at) else {
        return;
    };
    let elapsed = chrono::Utc::now().signed_duration_since(installed.with_timezone(&chrono::Utc));
    if elapsed.num_hours() < 24 {
        return;
    }
    emit_event("activation_return_d2");
    let _ = fs::write(&d2_marker, iso_now());
}

/// Count each activation kind in `ambient.jsonl` and return `(install, first_task, d2_return)`.
pub fn read_funnel(ambient_path: &Path) -> (u64, u64, u64) {
    let Ok(text) = fs::read_to_string(ambient_path) else {
        return (0, 0, 0);
    };
    let mut install = 0u64;
    let mut first_task = 0u64;
    let mut d2 = 0u64;
    for line in text.lines() {
        if line.contains("\"kind\":\"activation_install\"") {
            install += 1;
        } else if line.contains("\"kind\":\"activation_first_task\"") {
            first_task += 1;
        } else if line.contains("\"kind\":\"activation_return_d2\"") {
            d2 += 1;
        }
    }
    (install, first_task, d2)
}

/// Print the three-row funnel to stdout (called by `chump funnel`).
pub fn print_funnel() {
    let ambient = ambient_log_path();
    let (install, first_task, d2) = read_funnel(&ambient);

    let pct = |n: u64, d: u64| -> String {
        if d == 0 {
            "  —  ".into()
        } else {
            format!("{:>5.1}%", (n as f64 / d as f64) * 100.0)
        }
    };

    println!("Activation funnel  ({})", ambient.display());
    println!("─────────────────────────────────────────────");
    println!(
        "{:<28} {:>6}  {}",
        "install",
        install,
        pct(install, install)
    );
    println!(
        "{:<28} {:>6}  {}",
        "first_task",
        first_task,
        pct(first_task, install)
    );
    println!("{:<28} {:>6}  {}", "return_d2", d2, pct(d2, install));
    println!();
    if install == 0 {
        println!("(no activation_install events yet — run `chump init`)");
    }
}

// ── internals ────────────────────────────────────────────────────────────────

fn disabled() -> bool {
    std::env::var("CHUMP_ACTIVATION_DISABLED")
        .map(|v| v.trim() == "1" || v.trim().eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn activation_dir() -> PathBuf {
    crate::repo_path::runtime_base()
        .join(".chump")
        .join("activation")
}

fn ambient_log_path() -> PathBuf {
    if let Ok(custom) = std::env::var("CHUMP_AMBIENT_LOG") {
        return PathBuf::from(custom);
    }
    crate::repo_path::runtime_base()
        .join(".chump-locks")
        .join("ambient.jsonl")
}

fn iso_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn emit_event(kind: &str) {
    let ambient = ambient_log_path();
    if let Some(parent) = ambient.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let session = std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| "unknown".to_string());
    let worktree = crate::repo_path::runtime_base()
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();
    let ts = iso_now();

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"activation\",\"kind\":\"{kind}\"}}"
    );

    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", line);
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use tempfile::tempdir;

    #[test]
    fn read_funnel_counts_each_kind() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("ambient.jsonl");
        let mut f = fs::File::create(&p).unwrap();
        writeln!(f, r#"{{"kind":"activation_install"}}"#).unwrap();
        writeln!(f, r#"{{"kind":"activation_install"}}"#).unwrap();
        writeln!(f, r#"{{"kind":"activation_first_task"}}"#).unwrap();
        writeln!(f, r#"{{"kind":"activation_return_d2"}}"#).unwrap();
        writeln!(f, r#"{{"kind":"session_start"}}"#).unwrap();
        drop(f);

        let (i, ft, d2) = read_funnel(&p);
        assert_eq!(i, 2);
        assert_eq!(ft, 1);
        assert_eq!(d2, 1);
    }

    #[test]
    fn read_funnel_missing_file_returns_zeros() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("nope.jsonl");
        assert_eq!(read_funnel(&p), (0, 0, 0));
    }
}
