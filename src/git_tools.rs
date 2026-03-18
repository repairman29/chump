//! Git commit and push tools for allowlisted repos (Phase 4). Run in CHUMP_REPO; audit in chump.log.
//! Phase 3b: git_commit requires diff_review first (or already done this session); blocks on high-severity findings.
//! git_push sets origin to a token-in-URL when GITHUB_TOKEN is set; see docs/OPERATIONS.md § GitHub credentials and git push.

use crate::chump_log;
use crate::diff_review_tool;
use crate::repo_allowlist;
use crate::repo_path;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::process::Command;

fn debug_log_path() -> std::path::PathBuf {
    std::env::var("CHUMP_HOME")
        .ok()
        .map(|h| std::path::PathBuf::from(h).join("logs").join("debug-fef776.log"))
        .unwrap_or_else(|| std::path::PathBuf::from("/Users/jeffadkins/Projects/Maclawd/.cursor/debug-fef776.log"))
}

/// GitHub token for HTTPS push (same precedence as github_tools). Do not log.
fn github_token() -> Option<String> {
    std::env::var("GITHUB_TOKEN")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

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

/// Repo directory for git commands: respects set_working_repo override (e.g. spawn_worker).
fn git_repo_dir() -> PathBuf {
    repo_path::repo_root()
}

pub fn git_tools_enabled() -> bool {
    chump_repo_path().is_ok() && repo_allowlist::allowlist_non_empty()
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
        if !repo_allowlist::allowlist_contains(repo) {
            // #region agent log
            let _ = std::fs::OpenOptions::new().create(true).append(true).open(debug_log_path()).and_then(|mut f| {
                use std::io::Write;
                f.write_all(format!("{}\n", serde_json::json!({
                    "sessionId": "fef776",
                    "location": "git_tools.rs:allowlist",
                    "message": "repo not in allowlist",
                    "data": { "repo": repo, "allowlist_non_empty": repo_allowlist::allowlist_non_empty() },
                    "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
                    "hypothesisId": "C"
                })).as_bytes())
            });
            // #endregion
            return Err(anyhow!("repo {} is not in allowlist (CHUMP_GITHUB_REPOS or authorized)", repo));
        }
        let message = input
            .get("message")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing message"))?
            .trim();
        if message.is_empty() {
            return Err(anyhow!("message is empty"));
        }
        let repo_dir = git_repo_dir();
        if !diff_review_tool::diff_reviewed() {
            let review = diff_review_tool::run_diff_review_staged(&repo_dir).await?;
            if diff_review_tool::has_high_severity_findings(&review) {
                return Err(anyhow!(
                    "diff_review found high-severity issues; fix before committing. Review: {}",
                    review.lines().take(15).collect::<Vec<_>>().join("\n")
                ));
            }
            diff_review_tool::set_diff_reviewed();
        }
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
        if !repo_allowlist::allowlist_contains(repo) {
            // #region agent log
            let _ = std::fs::OpenOptions::new().create(true).append(true).open(debug_log_path()).and_then(|mut f| {
                use std::io::Write;
                f.write_all(format!("{}\n", serde_json::json!({
                    "sessionId": "fef776",
                    "location": "git_tools.rs:git_push_allowlist",
                    "message": "repo not in allowlist",
                    "data": { "repo": repo, "allowlist_non_empty": repo_allowlist::allowlist_non_empty() },
                    "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
                    "hypothesisId": "C"
                })).as_bytes())
            });
            // #endregion
            return Err(anyhow!("repo {} is not in allowlist (CHUMP_GITHUB_REPOS or authorized)", repo));
        }
        let branch = input
            .get("branch")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("main");
        let repo_dir = git_repo_dir();
        let token = github_token();
        // #region agent log
        let _ = std::fs::OpenOptions::new().create(true).append(true).open(debug_log_path()).and_then(|mut f| {
            use std::io::Write;
            f.write_all(format!("{}\n", serde_json::json!({
                "sessionId": "fef776",
                "location": "git_tools.rs:git_push",
                "message": "git_push token and repo",
                "data": { "token_set": token.is_some(), "token_len": token.as_ref().map(|t| t.len()).unwrap_or(0), "repo": repo },
                "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
                "hypothesisId": "A"
            })).as_bytes())
        });
        // #endregion
        if let Some(ref t) = token {
            let url = format!("https://x-access-token:{}@github.com/{}.git", t.trim(), repo);
            let (set_ok, set_out) =
                run_git(&repo_dir, &["remote", "set-url", "origin", &url]).await?;
            if !set_ok {
                return Err(anyhow!("git remote set-url failed: {}", set_out));
            }
        }
        let (ok, out) = run_git(&repo_dir, &["push", "origin", branch]).await?;
        if !ok {
            // #region agent log
            let out_lower = out.to_lowercase();
            let auth_failure = token.is_none()
                || out_lower.contains("403")
                || out.contains("Permission denied")
                || out_lower.contains("denied")
                || out_lower.contains("authentication")
                || out_lower.contains("need valid token")
                || out_lower.contains("valid token");
            let _ = std::fs::OpenOptions::new().create(true).append(true).open(debug_log_path()).and_then(|mut f| {
                use std::io::Write;
                f.write_all(format!("{}\n", serde_json::json!({
                    "sessionId": "fef776",
                    "location": "git_tools.rs:git_push_failed",
                    "message": "git push failed",
                    "data": { "auth_failure": auth_failure, "stderr_snippet": out.chars().take(250).collect::<String>() },
                    "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
                    "hypothesisId": "B"
                })).as_bytes())
            });
            // #endregion
            chump_log::log_git_push_failed(repo, branch, &out);
            let mut msg = format!("git push failed: {}", out);
            if token.is_none() {
                msg.push_str(" Set GITHUB_TOKEN in .env for HTTPS push.");
            } else if auth_failure {
                msg.push_str(" Update .env with a PAT that has repo scope (and SSO authorized for org repos if applicable), then restart the Discord bot. See docs/OPERATIONS.md § GitHub credentials and git push.");
                // DM: one-time fix so this stops happening.
                let dm = format!(
                    "Push to {} failed (auth). This will keep happening until you fix it once: (1) GitHub → Settings → Developer settings → Personal access tokens → create token with repo scope (and SSO for org if needed). (2) Put it in Chump .env as GITHUB_TOKEN=... (3) Restart the Discord bot. The bot cannot push without a valid token in .env.",
                    repo
                );
                chump_log::set_pending_notify(dm);
            }
            return Err(anyhow!("{}", msg));
        }
        chump_log::log_git_push(repo, branch);
        Ok(out.trim().to_string())
    }
}

pub struct GitStashTool;

#[async_trait]
impl Tool for GitStashTool {
    fn name(&self) -> String {
        "git_stash".to_string()
    }

    fn description(&self) -> String {
        "Stash or restore uncommitted changes in CHUMP_REPO. Params: action (save|pop|list|drop). Use save to stash changes, pop to restore, list to see stashes, drop to remove last stash.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "description": "save | pop | list | drop" }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing action"))?
            .trim()
            .to_lowercase();
        let repo_dir = git_repo_dir();
        let args: Vec<&str> = match action.as_str() {
            "save" => vec!["stash", "push", "-m", "chump stash"],
            "pop" => vec!["stash", "pop"],
            "list" => vec!["stash", "list"],
            "drop" => vec!["stash", "drop"],
            _ => return Err(anyhow!("action must be save, pop, list, or drop")),
        };
        let (ok, out) = run_git(&repo_dir, &args).await?;
        if !ok {
            return Err(anyhow!("git stash {} failed: {}", action, out));
        }
        Ok(out.trim().to_string())
    }
}

pub struct GitRevertTool;

#[async_trait]
impl Tool for GitRevertTool {
    fn name(&self) -> String {
        "git_revert".to_string()
    }

    fn description(&self) -> String {
        "Revert a commit in CHUMP_REPO. Params: optional commit_hash (default HEAD). Creates a new commit that undoes the specified commit.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "commit_hash": { "type": "string", "description": "Commit to revert (default HEAD)" }
            },
            "required": []
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let repo_dir = git_repo_dir();
        let commit = input
            .get("commit_hash")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("HEAD");
        let (ok, out) = run_git(&repo_dir, &["revert", "--no-edit", commit]).await?;
        if !ok {
            return Err(anyhow!("git revert failed: {}", out));
        }
        Ok(out.trim().to_string())
    }
}

/// Merge a subtask branch into target (orchestrator use after diff_review).
pub struct MergeSubtaskTool;

#[async_trait]
impl Tool for MergeSubtaskTool {
    fn name(&self) -> String {
        "merge_subtask".to_string()
    }

    fn description(&self) -> String {
        "Merge source_branch into target_branch in the repo. Params: source_branch, target_branch. On conflict returns error with details; on success returns summary. Use after worker branches are reviewed.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "source_branch": { "type": "string", "description": "Branch to merge (e.g. chump/task-1-subtask-1)" },
                "target_branch": { "type": "string", "description": "Branch to merge into (e.g. chump/integration or main)" }
            },
            "required": ["source_branch", "target_branch"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let source = input
            .get("source_branch")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing source_branch"))?
            .trim();
        let target = input
            .get("target_branch")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing target_branch"))?
            .trim();
        let repo_dir = git_repo_dir();

        let (ok_co, out_co) = run_git(&repo_dir, &["checkout", target]).await?;
        if !ok_co {
            return Err(anyhow!("git checkout {} failed: {}", target, out_co));
        }
        let (ok_merge, _out_merge) = run_git(&repo_dir, &["merge", source, "--no-edit"]).await?;
        if !ok_merge {
            let (_, status_out) = run_git(&repo_dir, &["status", "--short"]).await?;
            return Err(anyhow!(
                "merge conflict: {} into {}. git status:\n{}",
                source,
                target,
                status_out
            ));
        }
        let (_, stat_out) = run_git(&repo_dir, &["diff", "--stat", &format!("{}^..{}", target, target)]).await?;
        Ok(format!(
            "Merged {} into {}. Diff stat:\n{}",
            source, target, stat_out.trim()
        ))
    }
}

/// Delete local branches (e.g. chump/task-*-subtask-*) after PR is merged.
pub struct CleanupBranchesTool;

#[async_trait]
impl Tool for CleanupBranchesTool {
    fn name(&self) -> String {
        "cleanup_branches".to_string()
    }

    fn description(&self) -> String {
        "Delete local branches. Params: branches (array of branch names) or pattern (e.g. chump/task-*-subtask-*). Uses -d for merged, -D for force. Use after PR is merged.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "branches": { "type": "array", "items": { "type": "string" }, "description": "Branch names to delete" },
                "pattern": { "type": "string", "description": "Shell glob pattern (e.g. chump/task-*-subtask-*); list matching then delete" },
                "force": { "type": "boolean", "description": "Use -D (force delete) instead of -d" }
            }
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let force = input.get("force").and_then(|v| v.as_bool()).unwrap_or(false);
        let repo_dir = git_repo_dir();

        let branches: Vec<String> = if let Some(arr) = input.get("branches").and_then(|v| v.as_array()) {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.trim().to_string()))
                .filter(|s| !s.is_empty())
                .collect()
        } else if let Some(pat) = input.get("pattern").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty()) {
            let (ok, out) = run_git(&repo_dir, &["branch", "--list", pat]).await?;
            if !ok {
                return Err(anyhow!("git branch --list failed: {}", out));
            }
            out.lines()
                .map(str::trim)
                .map(|s| s.trim_start_matches('*').trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        } else {
            return Err(anyhow!("provide branches array or pattern"));
        };

        if branches.is_empty() {
            return Ok("No branches to delete.".to_string());
        }
        let flag = if force { "-D" } else { "-d" };
        let mut deleted = Vec::new();
        let mut failed: Vec<(String, String)> = Vec::new();
        for b in &branches {
            let (ok, out) = run_git(&repo_dir, &["branch", flag, b]).await?;
            if ok {
                deleted.push(b.clone());
            } else {
                failed.push((b.clone(), out.trim().to_string()));
            }
        }
        let mut msg = format!("Deleted: {}.", deleted.join(", "));
        if !failed.is_empty() {
            msg.push_str(&format!(
                " Failed: {}",
                failed
                    .iter()
                    .map(|(b, o)| format!("{} ({})", b, o))
                    .collect::<Vec<_>>()
                    .join("; ")
            ));
        }
        Ok(msg)
    }
}
