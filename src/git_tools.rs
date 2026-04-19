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
        .map(|h| {
            std::path::PathBuf::from(h)
                .join("logs")
                .join("debug-fef776.log")
        })
        .unwrap_or_else(|| std::path::PathBuf::from("logs/debug-fef776.log"))
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

/// Run `gh` (GitHub CLI) with the given args, capturing stdout. Mirrors
/// `run_git`'s convention: returns (exit_ok, combined output) so callers
/// can decide how to surface the failure.
async fn run_gh(args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new("gh")
        .args(args)
        .output()
        .await
        .map_err(|e| anyhow!("gh exec failed: {}", e))?;
    let mut combined = String::new();
    combined.push_str(&String::from_utf8_lossy(&out.stdout));
    if !out.stderr.is_empty() {
        if !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str(&String::from_utf8_lossy(&out.stderr));
    }
    Ok((out.status.success(), combined))
}

async fn run_git(repo_dir: &PathBuf, args: &[&str]) -> Result<(bool, String)> {
    // Inject a stable Chump identity so commits are never attributed to the
    // host machine's default `Your Name <you@example.com>` git config.
    // Override via CHUMP_GIT_AUTHOR_NAME / CHUMP_GIT_AUTHOR_EMAIL in .env.
    let author_name =
        std::env::var("CHUMP_GIT_AUTHOR_NAME").unwrap_or_else(|_| "Chump".to_string());
    let author_email =
        std::env::var("CHUMP_GIT_AUTHOR_EMAIL").unwrap_or_else(|_| "chump@chump.local".to_string());
    let out = Command::new("git")
        .args(args)
        .current_dir(repo_dir)
        .env("GIT_AUTHOR_NAME", &author_name)
        .env("GIT_AUTHOR_EMAIL", &author_email)
        .env("GIT_COMMITTER_NAME", &author_name)
        .env("GIT_COMMITTER_EMAIL", &author_email)
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
            return Err(anyhow!(
                "repo {} is not in allowlist (CHUMP_GITHUB_REPOS or authorized)",
                repo
            ));
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
        "Push from CHUMP_REPO to remote. Params: repo (owner/name, must be in CHUMP_GITHUB_REPOS), optional branch (defaults to current HEAD branch). Pushing to main/master requires CHUMP_AUTO_PUBLISH=1.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" },
                "branch": { "type": "string", "description": "Branch to push (defaults to current HEAD branch, not main)" }
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
            return Err(anyhow!(
                "repo {} is not in allowlist (CHUMP_GITHUB_REPOS or authorized)",
                repo
            ));
        }
        let repo_dir = git_repo_dir();
        // Resolve branch: caller-supplied > current HEAD > error (never silently push to main).
        let explicit_branch = input
            .get("branch")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty());
        let branch: String = if let Some(b) = explicit_branch {
            b.to_string()
        } else {
            let (ok, head) = run_git(&repo_dir, &["rev-parse", "--abbrev-ref", "HEAD"]).await?;
            if !ok || head.trim() == "HEAD" {
                return Err(anyhow!(
                    "detached HEAD — specify a branch explicitly to avoid pushing to main by mistake"
                ));
            }
            head.trim().to_string()
        };
        let branch = branch.as_str();
        // Guard: pushing to main/master requires explicit opt-in via CHUMP_AUTO_PUBLISH=1.
        let is_trunk = branch == "main" || branch == "master";
        let auto_publish = std::env::var("CHUMP_AUTO_PUBLISH").unwrap_or_default() == "1";
        if is_trunk && !auto_publish {
            return Err(anyhow!(
                "pushing to '{}' requires CHUMP_AUTO_PUBLISH=1 — use a feature branch or set that env var intentionally",
                branch
            ));
        }
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
            let url = format!(
                "https://x-access-token:{}@github.com/{}.git",
                t.trim(),
                repo
            );
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
                chump_log::set_pending_notify_unfiltered(dm);
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
        let (_, stat_out) = run_git(
            &repo_dir,
            &["diff", "--stat", &format!("{}^..{}", target, target)],
        )
        .await?;
        Ok(format!(
            "Merged {} into {}. Diff stat:\n{}",
            source,
            target,
            stat_out.trim()
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
        let force = input
            .get("force")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let repo_dir = git_repo_dir();

        let branches: Vec<String> =
            if let Some(arr) = input.get("branches").and_then(|v| v.as_array()) {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.trim().to_string()))
                    .filter(|s| !s.is_empty())
                    .collect()
            } else if let Some(pat) = input
                .get("pattern")
                .and_then(|v| v.as_str())
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
            {
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

/// Read GitHub PR comments back so the agent can respond to reviewer feedback.
/// Closes DOGFOOD_RELIABILITY_GAPS Gap 3.3 (carried over from CLOSING_THE_GAPS):
/// Chump could `gh pr comment` to post but couldn't read comments back. Without
/// this, the "respond to reviewer feedback" workflow required the user to copy
/// comments into the prompt manually.
///
/// Merges two sources because GitHub stores them separately:
///   - issue-style top-level PR comments via `gh api repos/{repo}/issues/{n}/comments`
///   - inline review comments via `gh api repos/{repo}/pulls/{n}/comments`
///
/// Output is plain-text formatted (author, timestamp, type, file:line for
/// inline ones, body excerpt) so a small local model can parse it without
/// JSON wrangling. Truncates each comment body at 800 chars to keep total
/// output bounded; full bodies are still in the GitHub UI.
pub struct GhPrListCommentsTool;

#[async_trait]
impl Tool for GhPrListCommentsTool {
    fn name(&self) -> String {
        "gh_pr_list_comments".to_string()
    }

    fn description(&self) -> String {
        "List comments on a GitHub pull request (issue-level + inline review comments). \
         Use this to read reviewer feedback before responding. Params: repo (owner/name, must be in CHUMP_GITHUB_REPOS), pr_number. \
         Optional: since_iso (ISO-8601 timestamp; only return comments updated after this) and limit (max comments per source, default 30, max 100)."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name (must be in allowlist)" },
                "pr_number": { "type": "integer", "description": "Pull request number" },
                "since_iso": { "type": "string", "description": "Optional ISO-8601 timestamp; filter to comments updated since" },
                "limit": { "type": "integer", "description": "Max comments per source (default 30, max 100)" }
            },
            "required": ["repo", "pr_number"]
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
            return Err(anyhow!(
                "repo {} is not in allowlist (CHUMP_GITHUB_REPOS or authorized)",
                repo
            ));
        }
        let pr_number = input
            .get("pr_number")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("missing or non-integer pr_number"))?;
        let limit: u64 = input
            .get("limit")
            .and_then(|v| v.as_u64())
            .unwrap_or(30)
            .clamp(1, 100);
        let since = input
            .get("since_iso")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());

        // Fetch issue-level + inline comments in parallel. Bind args slices to
        // let bindings so they outlive the join's await suspend points.
        let issue_path = format!(
            "repos/{}/issues/{}/comments?per_page={}",
            repo, pr_number, limit
        );
        let pulls_path = format!(
            "repos/{}/pulls/{}/comments?per_page={}",
            repo, pr_number, limit
        );
        let issue_args: [&str; 2] = ["api", &issue_path];
        let pulls_args: [&str; 2] = ["api", &pulls_path];
        let (issue_res, pulls_res) = tokio::join!(run_gh(&issue_args), run_gh(&pulls_args));

        let mut formatted = String::new();
        let mut total_count = 0usize;

        match issue_res {
            Ok((true, body)) => {
                let n = format_pr_comments(&body, "issue", since.as_deref(), &mut formatted)?;
                total_count += n;
            }
            Ok((false, body)) => {
                formatted.push_str(&format!(
                    "[issue comments fetch failed]\n{}\n\n",
                    body.lines().take(5).collect::<Vec<_>>().join("\n")
                ));
            }
            Err(e) => {
                formatted.push_str(&format!("[issue comments fetch error: {}]\n\n", e));
            }
        }

        match pulls_res {
            Ok((true, body)) => {
                let n = format_pr_comments(&body, "inline", since.as_deref(), &mut formatted)?;
                total_count += n;
            }
            Ok((false, body)) => {
                formatted.push_str(&format!(
                    "[inline comments fetch failed]\n{}\n\n",
                    body.lines().take(5).collect::<Vec<_>>().join("\n")
                ));
            }
            Err(e) => {
                formatted.push_str(&format!("[inline comments fetch error: {}]\n\n", e));
            }
        }

        if total_count == 0 && formatted.trim().is_empty() {
            formatted.push_str(&format!(
                "PR #{} on {} has no comments matching the filter.",
                pr_number, repo
            ));
        } else if total_count == 0 {
            formatted.push_str(&format!(
                "(no comments matched after filtering; {} fetch noted above)",
                if since.is_some() {
                    "since-filter"
                } else {
                    "scan"
                }
            ));
        } else {
            formatted = format!(
                "PR #{} on {} — {} comment(s) returned\n\n{}",
                pr_number, repo, total_count, formatted
            );
        }

        Ok(formatted)
    }
}

/// Parse the JSON response from `gh api .../comments` and append a
/// human-readable summary to `out`. Returns the count of comments emitted
/// (after `since_iso` filter).
fn format_pr_comments(
    json_body: &str,
    kind: &str,
    since_iso: Option<&str>,
    out: &mut String,
) -> Result<usize> {
    let value: Value = serde_json::from_str(json_body.trim())
        .map_err(|e| anyhow!("malformed gh api response ({}): {}", kind, e))?;
    let arr = value
        .as_array()
        .ok_or_else(|| anyhow!("expected array from gh api {} comments", kind))?;
    let mut count = 0;
    for c in arr {
        let updated_at = c.get("updated_at").and_then(|v| v.as_str()).unwrap_or("");
        if let Some(since) = since_iso {
            // Lexicographic comparison works for ISO-8601 UTC strings.
            if updated_at < since {
                continue;
            }
        }
        let author = c
            .get("user")
            .and_then(|u| u.get("login"))
            .and_then(|v| v.as_str())
            .unwrap_or("?");
        let body_full = c.get("body").and_then(|v| v.as_str()).unwrap_or("");
        let body = if body_full.chars().count() > 800 {
            let truncated: String = body_full.chars().take(800).collect();
            format!("{}…", truncated)
        } else {
            body_full.to_string()
        };
        // Inline comments include path + line for diff context.
        let location = if kind == "inline" {
            let path = c.get("path").and_then(|v| v.as_str()).unwrap_or("");
            let line = c
                .get("line")
                .or_else(|| c.get("original_line"))
                .and_then(|v| v.as_u64());
            match line {
                Some(l) if !path.is_empty() => format!(" {}:{}", path, l),
                _ if !path.is_empty() => format!(" {}", path),
                _ => String::new(),
            }
        } else {
            String::new()
        };
        out.push_str(&format!(
            "[{} {} @ {}{}]\n{}\n\n",
            kind, author, updated_at, location, body
        ));
        count += 1;
    }
    Ok(count)
}

#[cfg(test)]
mod gh_pr_comments_tests {
    //! Coverage for `format_pr_comments` — the JSON parser doesn't need a real
    //! `gh` binary, so we exercise the formatter against canned API responses.

    use super::format_pr_comments;

    /// Sample issue-style PR comment JSON (top-level conversation comment).
    const ISSUE_SAMPLE: &str = r#"[
        {
            "user": {"login": "alice"},
            "body": "Looks good, ship it!",
            "updated_at": "2026-04-15T12:00:00Z"
        },
        {
            "user": {"login": "bob"},
            "body": "Nit: typo on line 3",
            "updated_at": "2026-04-16T08:30:00Z"
        }
    ]"#;

    /// Sample inline review comment JSON (with file + line).
    const INLINE_SAMPLE: &str = r#"[
        {
            "user": {"login": "carol"},
            "body": "Why allocate here? Could use Vec::with_capacity",
            "updated_at": "2026-04-15T15:00:00Z",
            "path": "src/agent_loop/types.rs",
            "line": 42
        }
    ]"#;

    #[test]
    fn formats_issue_comments_with_author_and_timestamp() {
        let mut out = String::new();
        let count = format_pr_comments(ISSUE_SAMPLE, "issue", None, &mut out).unwrap();
        assert_eq!(count, 2);
        assert!(out.contains("[issue alice @ 2026-04-15T12:00:00Z]"));
        assert!(out.contains("Looks good, ship it!"));
        assert!(out.contains("[issue bob @ 2026-04-16T08:30:00Z]"));
        assert!(out.contains("Nit: typo on line 3"));
    }

    #[test]
    fn formats_inline_comments_with_path_and_line() {
        let mut out = String::new();
        let count = format_pr_comments(INLINE_SAMPLE, "inline", None, &mut out).unwrap();
        assert_eq!(count, 1);
        assert!(out.contains("[inline carol @ 2026-04-15T15:00:00Z src/agent_loop/types.rs:42]"));
        assert!(out.contains("Why allocate here?"));
    }

    #[test]
    fn since_filter_excludes_older_comments() {
        let mut out = String::new();
        // Filter to comments updated after Apr 16 noon → only bob's 08:30 doesn't
        // qualify (UTC noon is later), and alice's 12:00 the day before is
        // excluded too. Wait — bob is 08:30 on the 16th, alice is 12:00 on the
        // 15th. Filter "2026-04-16T00:00:00Z" should include only bob.
        let count = format_pr_comments(
            ISSUE_SAMPLE,
            "issue",
            Some("2026-04-16T00:00:00Z"),
            &mut out,
        )
        .unwrap();
        assert_eq!(count, 1);
        assert!(out.contains("bob"));
        assert!(!out.contains("alice"));
    }

    #[test]
    fn truncates_overly_long_comment_bodies() {
        let huge = "x".repeat(2000);
        let payload = format!(
            r#"[{{"user":{{"login":"dave"}},"body":"{}","updated_at":"2026-04-16T00:00:00Z"}}]"#,
            huge
        );
        let mut out = String::new();
        format_pr_comments(&payload, "issue", None, &mut out).unwrap();
        // 800 chars + ellipsis truncation marker '…'.
        assert!(
            out.contains("…"),
            "expected truncation marker; out: {}",
            &out[..200.min(out.len())]
        );
    }

    #[test]
    fn empty_array_emits_no_comments() {
        let mut out = String::new();
        let count = format_pr_comments("[]", "issue", None, &mut out).unwrap();
        assert_eq!(count, 0);
        assert!(out.is_empty());
    }

    #[test]
    fn malformed_json_returns_err() {
        let mut out = String::new();
        let err = format_pr_comments("not json", "issue", None, &mut out).unwrap_err();
        assert!(err.to_string().contains("malformed gh api response"));
    }

    #[test]
    fn non_array_response_returns_err() {
        let mut out = String::new();
        let err =
            format_pr_comments(r#"{"message": "Not Found"}"#, "issue", None, &mut out).unwrap_err();
        assert!(err.to_string().contains("expected array"));
    }
}
