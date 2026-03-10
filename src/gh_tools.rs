//! GitHub workflow tools via `gh` CLI. Structured wrappers so the model doesn't free-form shell.
//! Requires `gh` installed and authed; repo must be in CHUMP_GITHUB_REPOS. Run from CHUMP_REPO.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::process::Command;

fn chump_repo_path() -> Result<PathBuf, String> {
    let path = std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .map_err(|_| "CHUMP_REPO or CHUMP_HOME must be set for gh tools".to_string())?;
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

pub fn gh_tools_enabled() -> bool {
    chump_repo_path().is_ok() && !github_repos_allowlist().is_empty()
}

async fn run_gh(repo_dir: &PathBuf, args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new("gh")
        .args(args)
        .current_dir(repo_dir)
        .output()
        .await
        .map_err(|e| anyhow!("gh failed: {}", e))?;
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

/// List open issues (optionally by label). Repo must be in CHUMP_GITHUB_REPOS.
pub struct GhListIssuesTool;

#[async_trait]
impl Tool for GhListIssuesTool {
    fn name(&self) -> String {
        "gh_list_issues".to_string()
    }

    fn description(&self) -> String {
        "List GitHub issues. Params: repo (owner/name), optional label (e.g. good-first-issue or chump), optional state (open|closed|all, default open). Repo must be in CHUMP_GITHUB_REPOS.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" },
                "label": { "type": "string", "description": "Filter by label (e.g. chump, good-first-issue)" },
                "state": { "type": "string", "description": "open (default), closed, or all" }
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
        let state = input
            .get("state")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("open");
        let label = input.get("label").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());

        let mut args = vec!["issue", "list", "--repo", repo, "--state", state, "--json", "number,title,labels,url"];
        if let Some(l) = label {
            args.push("--label");
            args.push(l);
        }
        let (ok, out) = run_gh(&chump_repo_path().map_err(|e| anyhow!("{}", e))?, &args).await?;
        if !ok {
            return Err(anyhow!("gh issue list failed: {}", out));
        }
        let arr: Vec<Value> = serde_json::from_str(&out).unwrap_or_else(|_| vec![]);
        let lines: Vec<String> = arr
            .into_iter()
            .map(|o| {
                let num = o.get("number").and_then(|n| n.as_u64()).unwrap_or(0);
                let title = o.get("title").and_then(|t| t.as_str()).unwrap_or("?");
                let url = o.get("url").and_then(|u| u.as_str()).unwrap_or("");
                format!("#{} {} | {}", num, title, url)
            })
            .collect();
        Ok(if lines.is_empty() {
            "No issues found.".to_string()
        } else {
            lines.join("\n")
        })
    }
}

/// Create a branch in CHUMP_REPO (git checkout -b name).
pub struct GhCreateBranchTool;

#[async_trait]
impl Tool for GhCreateBranchTool {
    fn name(&self) -> String {
        "gh_create_branch".to_string()
    }

    fn description(&self) -> String {
        "Create and checkout a new branch in CHUMP_REPO. Params: name (e.g. fix/issue-47 or chump/foo).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "name": { "type": "string", "description": "Branch name (e.g. fix/issue-47)" }
            },
            "required": ["name"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let name = input
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing name"))?
            .trim();
        if name.is_empty() {
            return Err(anyhow!("branch name is empty"));
        }
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let out = Command::new("git")
            .args(["checkout", "-b", name])
            .current_dir(&repo_dir)
            .output()
            .await
            .map_err(|e| anyhow!("git failed: {}", e))?;
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        if !out.status.success() {
            return Err(anyhow!("git checkout -b failed: {}", stderr.trim()));
        }
        Ok(format!("Branch '{}' created and checked out.", name))
    }
}

/// Create a PR from current branch. Run from CHUMP_REPO.
pub struct GhCreatePrTool;

#[async_trait]
impl Tool for GhCreatePrTool {
    fn name(&self) -> String {
        "gh_create_pr".to_string()
    }

    fn description(&self) -> String {
        "Create a GitHub PR from the current branch. Params: title, body (description), optional base (default main). Run after git push.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "title": { "type": "string", "description": "PR title" },
                "body": { "type": "string", "description": "PR body/description" },
                "base": { "type": "string", "description": "Base branch (default main)" }
            },
            "required": ["title", "body"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let title = input.get("title").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("missing title"))?.trim();
        let body = input.get("body").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("missing body"))?;
        let base = input
            .get("base")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("main");
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let (ok, out) = run_gh(
            &repo_dir,
            &["pr", "create", "--title", title, "--body", body, "--base", base],
        )
        .await?;
        if !ok {
            return Err(anyhow!("gh pr create failed: {}", out));
        }
        Ok(out.trim().to_string())
    }
}

/// Get CI status for a PR (gh pr checks).
pub struct GhPrChecksTool;

#[async_trait]
impl Tool for GhPrChecksTool {
    fn name(&self) -> String {
        "gh_pr_checks".to_string()
    }

    fn description(&self) -> String {
        "Get CI/check status for a PR. Params: pr_number (e.g. 89). Run from CHUMP_REPO.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "pr_number": { "type": "number", "description": "PR number" }
            },
            "required": ["pr_number"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let num = input
            .get("pr_number")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("missing pr_number"))?;
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let (ok, out) = run_gh(&repo_dir, &["pr", "checks", &num.to_string()]).await?;
        if !ok {
            return Err(anyhow!("gh pr checks failed: {}", out));
        }
        Ok(out.trim().to_string())
    }
}

/// Get full issue body and comments (gh issue view).
pub struct GhGetIssueTool;

#[async_trait]
impl Tool for GhGetIssueTool {
    fn name(&self) -> String {
        "gh_get_issue".to_string()
    }

    fn description(&self) -> String {
        "Get full issue body and comments. Params: repo (owner/name), number (issue number). Repo must be in CHUMP_GITHUB_REPOS.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" },
                "number": { "type": "number", "description": "Issue number" }
            },
            "required": ["repo", "number"]
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
        let num = input
            .get("number")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("missing number"))?;
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let (ok, out) = run_gh(
            &repo_dir,
            &["issue", "view", &num.to_string(), "--repo", repo, "--json", "title,body,comments"],
        )
        .await?;
        if !ok {
            return Err(anyhow!("gh issue view failed: {}", out));
        }
        let obj: Value = serde_json::from_str(&out).unwrap_or(json!({}));
        let title = obj.get("title").and_then(|t| t.as_str()).unwrap_or("?");
        let body = obj.get("body").and_then(|b| b.as_str()).unwrap_or("");
        let comments: &[Value] = obj
            .get("comments")
            .and_then(|c| c.as_array())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);
        let mut s = format!("Title: {}\n\nBody:\n{}\n", title, body);
        if !comments.is_empty() {
            s.push_str("\nComments:\n");
            for c in comments {
                let auth = c.get("author").and_then(|a| a.get("login")).and_then(|l| l.as_str()).unwrap_or("?");
                let cmt = c.get("body").and_then(|b| b.as_str()).unwrap_or("");
                s.push_str(&format!("- {}: {}\n", auth, cmt.replace('\n', " ")));
            }
        }
        Ok(s.trim().to_string())
    }
}

/// List open PRs (Chump's or all). gh pr list --repo repo.
pub struct GhListMyPrsTool;

#[async_trait]
impl Tool for GhListMyPrsTool {
    fn name(&self) -> String {
        "gh_list_my_prs".to_string()
    }

    fn description(&self) -> String {
        "List open PRs in a repo. Params: repo (owner/name). Returns number, title, url. Repo must be in CHUMP_GITHUB_REPOS.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" }
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
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let (ok, out) = run_gh(
            &repo_dir,
            &["pr", "list", "--repo", repo, "--state", "open", "--json", "number,title,url"],
        )
        .await?;
        if !ok {
            return Err(anyhow!("gh pr list failed: {}", out));
        }
        let arr: Vec<Value> = serde_json::from_str(&out).unwrap_or_default();
        let lines: Vec<String> = arr
            .into_iter()
            .map(|o| {
                let num = o.get("number").and_then(|n| n.as_u64()).unwrap_or(0);
                let title = o.get("title").and_then(|t| t.as_str()).unwrap_or("?");
                let url = o.get("url").and_then(|u| u.as_str()).unwrap_or("");
                format!("#{} {} | {}", num, title, url)
            })
            .collect();
        Ok(if lines.is_empty() {
            "No open PRs.".to_string()
        } else {
            lines.join("\n")
        })
    }
}

/// Comment on a PR (gh pr comment).
pub struct GhPrCommentTool;

#[async_trait]
impl Tool for GhPrCommentTool {
    fn name(&self) -> String {
        "gh_pr_comment".to_string()
    }

    fn description(&self) -> String {
        "Add a comment to a PR. Params: pr_number, body.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "pr_number": { "type": "number", "description": "PR number" },
                "body": { "type": "string", "description": "Comment body" }
            },
            "required": ["pr_number", "body"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let num = input
            .get("pr_number")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("missing pr_number"))?;
        let body = input
            .get("body")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing body"))?;
        let repo_dir = chump_repo_path().map_err(|e| anyhow!("{}", e))?;
        let (ok, out) = run_gh(&repo_dir, &["pr", "comment", &num.to_string(), "--body", body]).await?;
        if !ok {
            return Err(anyhow!("gh pr comment failed: {}", out));
        }
        Ok("Comment posted.".to_string())
    }
}