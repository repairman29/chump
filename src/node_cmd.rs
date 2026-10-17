//! RESILIENT-1614: `chump node pause|resume` — make node pause an invariant.
//!
//! The pause/resume commands manage node-wide work state via two mechanisms:
//! (1) CHUMP_NODE_MODE in node.env (read by installers and self-heal organs)
//! (2) .chump/fleet-paused sentinel (marker + reason for the pause)
//!
//! When paused, every work organ (node-converge, organ-reconcile, organ-deploy,
//! paramedic, process-organ-heal, self-doctor, worker loop) checks the mode
//! first and exits 0 with kind=organ_skipped_paused instead of installing,
//! enabling, or restarting anything. Agents do not get sudo systemctl access.
//!
//! Keep-list while paused: gap-closure-reconcile, almanac-liveness,
//! fleet-health-sentinel, node-deploy-lag-watchdog, digest, gap-store-single-source-check.

use anyhow::Result;
use chrono::Utc;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PauseCommand {
    Pause { reason: String },
    Resume,
}

pub struct PauseResult {
    pub action: String,
    pub mode: String,
    pub sentinel_path: String,
}

pub fn run(repo_root: &Path, cmd: PauseCommand) -> Result<PauseResult> {
    let state_dir = repo_root.join(".chump");
    fs::create_dir_all(&state_dir)?;

    let node_env = find_node_env(repo_root)?;

    match cmd {
        PauseCommand::Pause { reason } => pause_node(repo_root, &state_dir, &node_env, &reason),
        PauseCommand::Resume => resume_node(repo_root, &state_dir, &node_env),
    }
}

fn find_node_env(repo_root: &Path) -> Result<std::path::PathBuf> {
    // Try standard locations in order of precedence
    let candidates = vec![
        repo_root.join(".chump").join("node.env"),
        repo_root.join("node.env"),
        std::path::PathBuf::from(format!(
            "{}/.chump/node.env",
            std::env::var("HOME").unwrap_or_default()
        )),
    ];

    for path in candidates {
        if path.exists() {
            return Ok(path);
        }
    }

    // If no existing node.env found, use .chump/node.env as default location
    Ok(repo_root.join(".chump").join("node.env"))
}

fn pause_node(
    repo_root: &Path,
    state_dir: &Path,
    node_env: &Path,
    reason: &str,
) -> Result<PauseResult> {
    // Read existing node.env, update CHUMP_NODE_MODE to paused
    let mut env_lines = if node_env.exists() {
        fs::read_to_string(node_env)?
            .lines()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
    } else {
        vec![]
    };

    // Remove any existing CHUMP_NODE_MODE line and add paused
    env_lines.retain(|line| !line.starts_with("export CHUMP_NODE_MODE="));
    env_lines.push("export CHUMP_NODE_MODE=paused".to_string());

    // Write updated node.env
    let env_content = env_lines.join("\n") + "\n";
    fs::write(node_env, env_content)?;

    // Create sentinel with reason and timestamp
    let sentinel_path = state_dir.join("fleet-paused");
    let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let actor = std::env::var("USER").unwrap_or_else(|_| "unknown".to_string());
    let sentinel_content = format!("paused_at: {}\nactor: {}\nreason: {}\n", ts, actor, reason);
    fs::write(&sentinel_path, sentinel_content)?;

    // Emit event
    emit_event(
        repo_root,
        "node_paused",
        &serde_json::json!({
            "mode": "paused",
            "reason": reason,
            "actor": actor,
        }),
    )?;

    Ok(PauseResult {
        action: "paused".to_string(),
        mode: "paused".to_string(),
        sentinel_path: sentinel_path.display().to_string(),
    })
}

fn resume_node(repo_root: &Path, state_dir: &Path, node_env: &Path) -> Result<PauseResult> {
    // Read existing node.env, update CHUMP_NODE_MODE to work-ready
    let mut env_lines = if node_env.exists() {
        fs::read_to_string(node_env)?
            .lines()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
    } else {
        vec![]
    };

    // Remove any existing CHUMP_NODE_MODE line and add work-ready
    env_lines.retain(|line| !line.starts_with("export CHUMP_NODE_MODE="));
    env_lines.push("export CHUMP_NODE_MODE=work-ready".to_string());

    // Write updated node.env
    let env_content = env_lines.join("\n") + "\n";
    fs::write(node_env, env_content)?;

    // Remove sentinel if present
    let sentinel_path = state_dir.join("fleet-paused");
    if sentinel_path.exists() {
        fs::remove_file(&sentinel_path)?;
    }

    // Emit event
    let actor = std::env::var("USER").unwrap_or_else(|_| "unknown".to_string());
    emit_event(
        repo_root,
        "node_resumed",
        &serde_json::json!({
            "mode": "work-ready",
            "actor": actor,
        }),
    )?;

    Ok(PauseResult {
        action: "resumed".to_string(),
        mode: "work-ready".to_string(),
        sentinel_path: sentinel_path.display().to_string(),
    })
}

fn emit_event(repo_root: &Path, kind: &str, data: &serde_json::Value) -> Result<()> {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let mut event = serde_json::json!({
        "ts": ts,
        "kind": kind,
    });

    // Merge in the data fields
    if let Some(obj) = event.as_object_mut() {
        if let Some(data_obj) = data.as_object() {
            for (k, v) in data_obj {
                obj.insert(k.clone(), v.clone());
            }
        }
    }

    let line = format!("{}\n", event);

    if let Some(parent) = amb.parent() {
        let _ = fs::create_dir_all(parent);
    }

    use std::io::Write;
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)?;
    f.write_all(line.as_bytes())?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn pause_creates_sentinel_and_mode() {
        let dir = tempdir().unwrap();
        let state_dir = dir.path().join(".chump");
        fs::create_dir_all(&state_dir).unwrap();

        let node_env = state_dir.join("node.env");
        fs::write(&node_env, "export CHUMP_OTHER=1\n").unwrap();

        let result = pause_node(dir.path(), &state_dir, &node_env, "test pause").unwrap();
        assert_eq!(result.mode, "paused");
        assert!(node_env.exists());
        let content = fs::read_to_string(&node_env).unwrap();
        assert!(content.contains("CHUMP_NODE_MODE=paused"));

        let sentinel = state_dir.join("fleet-paused");
        assert!(sentinel.exists());
        let sentinel_content = fs::read_to_string(&sentinel).unwrap();
        assert!(sentinel_content.contains("test pause"));
    }

    #[test]
    fn resume_removes_sentinel_and_restores_mode() {
        let dir = tempdir().unwrap();
        let state_dir = dir.path().join(".chump");
        fs::create_dir_all(&state_dir).unwrap();

        let node_env = state_dir.join("node.env");
        fs::write(&node_env, "export CHUMP_NODE_MODE=paused\n").unwrap();

        let sentinel = state_dir.join("fleet-paused");
        fs::write(&sentinel, "test sentinel").unwrap();

        let result = resume_node(dir.path(), &state_dir, &node_env).unwrap();
        assert_eq!(result.mode, "work-ready");
        assert!(!sentinel.exists());

        let content = fs::read_to_string(&node_env).unwrap();
        assert!(content.contains("CHUMP_NODE_MODE=work-ready"));
    }
}
