//! RESILIENT-1614: `chump node pause|resume` — enforce fleet pause as an invariant.
//!
//! The node pause/resume is the ONE verb controlling whether work organs run on a node.
//! Pause writes CHUMP_NODE_MODE=paused into node.env + a .chump/fleet-paused sentinel,
//! disables work organs, and emits kind=node_paused.
//! Resume reverses it with kind=node_resumed.
//!
//! Every work-organ script (node-converge, organ-reconcile, organ-deploy, paramedic,
//! process-organ-heal, self-doctor, worker.sh) checks the mode FIRST and exits 0 with
//! kind=organ_skipped_paused if paused, without installing/enabling/restarting anything.

use chrono::Utc;
use std::env;
use std::path::PathBuf;

/// Parse `chump node pause|resume [--reason REASON]` args and run the appropriate handler.
pub fn run_cli(args: &[String]) -> i32 {
    let subcmd = args.get(1).and_then(|s| {
        if s == "pause" || s == "resume" {
            Some(s.as_str())
        } else {
            None
        }
    });

    match subcmd {
        Some("pause") => pause_cmd(args),
        Some("resume") => resume_cmd(args),
        _ => {
            eprintln!("Usage: chump node pause|resume [--reason REASON]");
            eprintln!();
            eprintln!("pause:  disable work organs and write node.env CHUMP_NODE_MODE=paused");
            eprintln!("resume: re-enable work organs and remove the paused marker");
            1
        }
    }
}

/// Parse --reason flag from args.
fn extract_reason(args: &[String]) -> String {
    args.windows(2)
        .find(|w| w[0] == "--reason")
        .map(|w| w[1].clone())
        .unwrap_or_default()
}

/// `chump node pause --reason "message"` — disable work organs and mark paused.
fn pause_cmd(args: &[String]) -> i32 {
    let reason = extract_reason(args);
    let state_dir = env::var("CHUMP_STATE_DIR").unwrap_or_else(|_| {
        env::var("HOME")
            .map(|h| format!("{}/.chump", h))
            .unwrap_or_else(|_| ".chump".to_string())
    });

    let node_env_path = PathBuf::from(&state_dir).join("node.env");
    let sentinel_path = PathBuf::from(&state_dir).join("fleet-paused");

    // Read the current node.env, preserving all other env vars.
    let node_env_content = std::fs::read_to_string(&node_env_path).unwrap_or_default();
    let mut lines: Vec<String> = node_env_content.lines().map(|s| s.to_string()).collect();

    // Remove/replace the CHUMP_NODE_MODE and CHUMP_NODE_WORK_ENABLED lines if they exist.
    lines.retain(|line| {
        !line.starts_with("export CHUMP_NODE_MODE=")
            && !line.starts_with("CHUMP_NODE_MODE=")
            && !line.starts_with("export CHUMP_NODE_WORK_ENABLED=")
            && !line.starts_with("CHUMP_NODE_WORK_ENABLED=")
    });

    // Add the paused mode.
    lines.push("export CHUMP_NODE_MODE=paused".to_string());
    lines.push("export CHUMP_NODE_WORK_ENABLED=0".to_string());

    let new_content = format!("{}\n", lines.join("\n"));
    if let Err(e) = std::fs::write(&node_env_path, new_content) {
        eprintln!("failed to write {}: {}", node_env_path.display(), e);
        return 1;
    }

    // Write the sentinel file with timestamp, reason, and actor.
    let actor = std::env::var("USER").unwrap_or_else(|_| "unknown".to_string());
    let sentinel_content = format!(
        "paused_at: {}\nreason: {}\nactor: {}\n",
        Utc::now().to_rfc3339(),
        reason,
        actor
    );
    if let Err(e) = std::fs::write(&sentinel_path, sentinel_content) {
        eprintln!(
            "failed to write sentinel {}: {}",
            sentinel_path.display(),
            e
        );
        return 1;
    }

    // Emit the event.
    emit_event("node_paused", &reason);

    println!("Node paused: {}", &state_dir);
    println!("  mode: CHUMP_NODE_MODE=paused");
    println!("  work: CHUMP_NODE_WORK_ENABLED=0");
    println!("  sentinel: {}", sentinel_path.display());
    if !reason.is_empty() {
        println!("  reason: {}", reason);
    }
    0
}

/// `chump node resume` — re-enable work organs and remove paused marker.
fn resume_cmd(_args: &[String]) -> i32 {
    let state_dir = env::var("CHUMP_STATE_DIR").unwrap_or_else(|_| {
        env::var("HOME")
            .map(|h| format!("{}/.chump", h))
            .unwrap_or_else(|_| ".chump".to_string())
    });

    let node_env_path = PathBuf::from(&state_dir).join("node.env");
    let sentinel_path = PathBuf::from(&state_dir).join("fleet-paused");

    // Read the current node.env, preserving all other env vars.
    let node_env_content = std::fs::read_to_string(&node_env_path).unwrap_or_default();
    let mut lines: Vec<String> = node_env_content.lines().map(|s| s.to_string()).collect();

    // Remove the paused-mode lines and re-enable work.
    lines.retain(|line| {
        !line.starts_with("export CHUMP_NODE_MODE=")
            && !line.starts_with("CHUMP_NODE_MODE=")
            && !line.starts_with("export CHUMP_NODE_WORK_ENABLED=")
            && !line.starts_with("CHUMP_NODE_WORK_ENABLED=")
    });

    // Add the work-ready mode.
    lines.push("export CHUMP_NODE_MODE=work-ready".to_string());
    lines.push("export CHUMP_NODE_WORK_ENABLED=1".to_string());

    let new_content = format!("{}\n", lines.join("\n"));
    if let Err(e) = std::fs::write(&node_env_path, new_content) {
        eprintln!("failed to write {}: {}", node_env_path.display(), e);
        return 1;
    }

    // Remove the sentinel file.
    let _ = std::fs::remove_file(&sentinel_path);

    // Emit the event.
    emit_event("node_resumed", "");

    println!("Node resumed: {}", &state_dir);
    println!("  mode: CHUMP_NODE_MODE=work-ready");
    println!("  work: CHUMP_NODE_WORK_ENABLED=1");
    0
}

/// Emit an event to the ambient stream (if available).
fn emit_event(kind: &str, reason: &str) {
    let state_dir = env::var("CHUMP_STATE_DIR").unwrap_or_else(|_| {
        env::var("HOME")
            .map(|h| format!("{}/.chump", h))
            .unwrap_or_else(|_| ".chump".to_string())
    });

    let ambient_path = PathBuf::from(&state_dir)
        .parent()
        .map(|p| p.join(".chump-locks/ambient.jsonl"))
        .unwrap_or_else(|| PathBuf::from(".chump-locks/ambient.jsonl"));

    let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let event = if reason.is_empty() {
        format!(r#"{{"ts":"{}","kind":"{}"}}"#, ts, kind)
    } else {
        format!(
            r#"{{"ts":"{}","kind":"{}","reason":"{}"}}"#,
            ts, kind, reason
        )
    };

    // Try to append to the ambient stream, but don't fail if it doesn't exist.
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(f, "{}", event)
        });
}
