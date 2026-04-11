//! Run one shell command in a detached git worktree, then remove the worktree.
//! Opt-in: `CHUMP_SANDBOX_ENABLED=1`. Uses [`crate::repo_path::repo_root`] (must contain `.git`).
//! Reuses [`crate::cli_tool::heuristic_risk`]: high-risk commands are rejected.

use crate::cli_tool::{heuristic_risk, CliRiskLevel};
use crate::limits;
use crate::repo_path;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command as SyncCommand;
use std::time::Duration;
use tokio::process::Command;

/// True when `CHUMP_SANDBOX_ENABLED=1` or `true`.
pub fn sandbox_enabled() -> bool {
    std::env::var("CHUMP_SANDBOX_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn default_timeout() -> u64 {
    std::env::var("CHUMP_SANDBOX_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1..=600).contains(&n))
        .unwrap_or(120)
}

struct WorktreeDrop {
    repo_root: PathBuf,
    path: PathBuf,
}

impl Drop for WorktreeDrop {
    fn drop(&mut self) {
        let _ = SyncCommand::new("git")
            .current_dir(&self.repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(&self.path)
            .output();
    }
}

pub struct SandboxTool;

impl SandboxTool {
    fn repo_with_git() -> Result<PathBuf> {
        let root = repo_path::repo_root();
        if !root.join(".git").exists() {
            return Err(anyhow!(
                "sandbox_run needs a git repo (no .git under {}); set CHUMP_REPO or working repo",
                root.display()
            ));
        }
        Ok(root)
    }
}

#[async_trait]
impl Tool for SandboxTool {
    fn name(&self) -> String {
        "sandbox_run".to_string()
    }

    fn description(&self) -> String {
        "Ephemeral sandbox: create a detached git worktree of the current repo, run one shell command in it, then delete the worktree. \
         Enable with CHUMP_SANDBOX_ENABLED=1. High-risk commands (same heuristics as run_cli) are blocked. \
         Params: command (required). Optional: timeout_secs (default from CHUMP_SANDBOX_TIMEOUT_SECS or 120, max 600)."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "command": { "type": "string", "description": "Single shell command to run inside the worktree (sh -c)" },
                "timeout_secs": { "type": "integer", "description": "Timeout in seconds (max 600)" }
            },
            "required": ["command"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if !sandbox_enabled() {
            return Err(anyhow!(
                "sandbox_run is disabled; set CHUMP_SANDBOX_ENABLED=1"
            ));
        }
        limits::check_tool_input_len(&input).map_err(|e| anyhow!("{}", e))?;

        let cmd = input
            .get("command")
            .and_then(|c| c.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow!("command is required"))?;

        let (level, reason) = heuristic_risk(cmd);
        if level == CliRiskLevel::High {
            return Err(anyhow!("command blocked (high risk): {}", reason));
        }

        let timeout = input
            .get("timeout_secs")
            .and_then(|v| v.as_u64())
            .unwrap_or_else(default_timeout)
            .min(600);

        let repo = Self::repo_with_git()?;
        let worktree_path =
            std::env::temp_dir().join(format!("chump-sandbox-{}", uuid::Uuid::new_v4()));
        if worktree_path.exists() {
            let _ = std::fs::remove_dir_all(&worktree_path);
        }

        let add = SyncCommand::new("git")
            .current_dir(&repo)
            .args(["worktree", "add", "--detach"])
            .arg(&worktree_path)
            .arg("HEAD")
            .output()
            .map_err(|e| anyhow!("git worktree add: {}", e))?;

        if !add.status.success() {
            let stderr = String::from_utf8_lossy(&add.stderr);
            return Err(anyhow!("git worktree add failed: {}", stderr.trim()));
        }

        let _guard = WorktreeDrop {
            repo_root: repo.clone(),
            path: worktree_path.clone(),
        };

        let child = Command::new("sh")
            .current_dir(&worktree_path)
            .args(["-c", cmd])
            .output();

        let output = tokio::time::timeout(Duration::from_secs(timeout), child)
            .await
            .map_err(|_| anyhow!("sandbox command timed out after {}s", timeout))?
            .map_err(|e| anyhow!("failed to run command: {}", e))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout_clip: String = stdout.chars().take(8000).collect();
        let stderr_clip: String = stderr.chars().take(8000).collect();

        Ok(format!(
            "exit={}\n--- stdout ---\n{}\n--- stderr ---\n{}",
            output.status.code().unwrap_or(-1),
            stdout_clip,
            stderr_clip
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use serial_test::serial;
    use std::fs;
    use std::process::Command as SysCmd;

    #[test]
    fn sandbox_enabled_env() {
        std::env::remove_var("CHUMP_SANDBOX_ENABLED");
        assert!(!sandbox_enabled());
        std::env::set_var("CHUMP_SANDBOX_ENABLED", "1");
        assert!(sandbox_enabled());
        std::env::set_var("CHUMP_SANDBOX_ENABLED", "true");
        assert!(sandbox_enabled());
        std::env::remove_var("CHUMP_SANDBOX_ENABLED");
    }

    #[tokio::test]
    #[serial]
    async fn sandbox_run_executes_in_worktree() {
        let tmp = std::env::temp_dir().join(format!(
            "chump_sandbox_git_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", tmp.to_str().unwrap());
        std::env::set_var("CHUMP_SANDBOX_ENABLED", "1");

        SysCmd::new("git")
            .arg("init")
            .current_dir(&tmp)
            .output()
            .expect("git init (install git for this test)");
        fs::write(tmp.join("f.txt"), "x").unwrap();
        SysCmd::new("git")
            .args(["config", "user.email", "sandbox@test"])
            .current_dir(&tmp)
            .output()
            .unwrap();
        SysCmd::new("git")
            .args(["config", "user.name", "sandbox"])
            .current_dir(&tmp)
            .output()
            .unwrap();
        SysCmd::new("git")
            .args(["add", "f.txt"])
            .current_dir(&tmp)
            .output()
            .unwrap();
        SysCmd::new("git")
            .args(["commit", "-m", "init"])
            .current_dir(&tmp)
            .output()
            .unwrap();

        let tool = SandboxTool;
        let out = tool
            .execute(json!({"command": "echo chump_sandbox_ok"}))
            .await
            .expect("sandbox_run");
        assert!(
            out.contains("chump_sandbox_ok"),
            "unexpected output: {}",
            out
        );

        if let Some(p) = prev_repo {
            std::env::set_var("CHUMP_REPO", p);
        } else {
            std::env::remove_var("CHUMP_REPO");
        }
        std::env::remove_var("CHUMP_SANDBOX_ENABLED");
        let _ = fs::remove_dir_all(&tmp);
    }
}
