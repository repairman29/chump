//! Git commit and push tools for allowlisted repos (Phase 4). Run in CHUMP_REPO; audit in chump.log.

use crate::chump_log;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::process::Command;

fn chump_repo_path() -> Result<PathBuf, String> {
    let path = std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .map_err(|_| "CHUMP_REPO or CHUMP_HOME must be set for git_commit/git_push".to_string())?;
    let path = PathBuf::from(path.trim());
    if !path.is_dir() {
        return Err("CHUMP_REPO is not a directory".to_string());
    }
    Ok(path)
}

fn github_repos_allowlist() -> Vec<String> {
    std::env::var("CHUMP_GITHUB_REPOS")
        .ok()
        .map(|s| {
            s.split(',')
                .map(|x| x.trim().to_string())
                .filter(|x| !x.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn allowlist_contains(repo: &str) -> bool {
    let repo = repo.trim();
    if repo.is_empty() {
        return false;
    }
    github_repos_allowlist().iter().any(|r| r == repo)
}

pub fn git_tools_enabled() -> bool {
    chump_repo_path().is_ok() && !github_repos_allowlist().is_empty()
}

async fn run_git(repo_dir: &PathBuf, args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new("git")
        .args(args)
        .current_dir(repo_dir)
        .output()
        .await
        .map_err(|e| anyhow!("git failed: {}", e))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let combined = if stderr.is_empty() {
        stdout
    } else if stdout.is_empty() {
        stderr
    } else {
        format!("{}\n{}", stdout, stderr)
    };
    Ok((out.status.success(), combined))
}

pub struct GitCommitTool;

#[async_trait]
impl Tool for GitCommitTool {
    fn name(&self) -> String {
        "git_commit".to_string()
    }

    fn description(&self) -> String {
        "Commit changes in CHUMP_REPO. Params: repo (owner/name, must be in CHUMP_GITHUB_REPOS), message (commit message). Runs git add -A && git commit -m message.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name (must be in allowlist)" },
                "message": { "type": "string", "description": "Commit message" }
            },
            "required": ["repo", "message"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing repo"))?
            .trim();
        if !allowlist_contains(repo) {
            return Err(anyhow!("repo {} is not in CHUMP_GITHUB_REPOS", repo));
        }
        let message = input
            .get("message")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing message"))?
            .trim();
        if message.is_empty() {
            return Err(anyhow!("message is empty"));
        }
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let (ok, out) = run_git(&repo_dir, &["add", "-A"]).await?;
        if !ok {
            return Err(anyhow!("git add failed: {}", out));
        }
        let (ok, out) = run_git(&repo_dir, &["commit", "-m", message]).await?;
        chump_log::log_git_commit(repo, message);
        if !ok {
            return Err(anyhow!("git commit failed: {}", out));
        }
        Ok(out.trim().to_string())
    }
}

pub struct GitPushTool;

#[async_trait]
impl Tool for GitPushTool {
    fn name(&self) -> String {
        "git_push".to_string()
    }

    fn description(&self) -> String {
        "Push from CHUMP_REPO to remote. Params: repo (owner/name, must be in CHUMP_GITHUB_REPOS), optional branch (default main).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" },
                "branch": { "type": "string", "description": "Branch to push (default main)" }
            },
            "required": ["repo"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing repo"))?
            .trim();
        if !allowlist_contains(repo) {
            return Err(anyhow!("repo {} is not in CHUMP_GITHUB_REPOS", repo));
        }
        let branch = input
            .get("branch")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("main");
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let (ok, out) = run_git(&repo_dir, &["push", "origin", branch]).await?;
        chump_log::log_git_push(repo, branch);
        if !ok {
            return Err(anyhow!("git push failed: {}", out));
        }
        Ok(out.trim().to_string())
    }
}
