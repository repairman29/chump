//! repo_authorize and repo_deauthorize tools: add/remove repos from chump_authorized_repos.
//! Authorized repos are allowed for git_commit, git_push, gh_*, github_clone_or_pull (with env allowlist).
//! Only authorize after notifying and getting human confirmation.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::repo_allowlist;

pub fn repo_allowlist_tools_enabled() -> bool {
    crate::repo_path::repo_root_is_explicit() && crate::db_pool::get().is_ok()
}

pub struct RepoAuthorizeTool;

#[async_trait]
impl Tool for RepoAuthorizeTool {
    fn name(&self) -> String {
        "repo_authorize".to_string()
    }

    fn description(&self) -> String {
        "Add a repo (owner/name) to the authorized list so git and GitHub tools can operate on it. Only call after notify and human confirmation (e.g. Jeff approved). Repo format: owner/name.".to_string()
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
            return Err(anyhow::anyhow!("{}", e));
        }
        if !repo_allowlist_tools_enabled() {
            return Err(anyhow::anyhow!(
                "repo_authorize requires CHUMP_REPO or CHUMP_HOME and chump_memory db"
            ));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("missing repo"))?
            .trim();
        if repo.is_empty() {
            return Err(anyhow::anyhow!("repo is empty"));
        }
        if !repo.contains('/') || repo.matches('/').count() != 1 {
            return Err(anyhow::anyhow!("repo must be owner/name"));
        }
        repo_allowlist::add_authorized_repo(repo)?;
        Ok(format!(
            "Authorized repo {}. Git and GitHub tools can now use it.",
            repo
        ))
    }
}

pub struct RepoDeauthorizeTool;

#[async_trait]
impl Tool for RepoDeauthorizeTool {
    fn name(&self) -> String {
        "repo_deauthorize".to_string()
    }

    fn description(&self) -> String {
        "Remove a repo from the authorized list. Git and GitHub tools will no longer accept it (unless in CHUMP_GITHUB_REPOS env).".to_string()
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
            return Err(anyhow::anyhow!("{}", e));
        }
        if !repo_allowlist_tools_enabled() {
            return Err(anyhow::anyhow!(
                "repo_deauthorize requires CHUMP_REPO or CHUMP_HOME and chump_memory db"
            ));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("missing repo"))?
            .trim();
        repo_allowlist::remove_authorized_repo(repo)?;
        Ok(format!("Deauthorized repo {}.", repo))
    }
}
