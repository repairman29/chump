//! diff_review: run git diff in repo and get a code-review style self-audit (via worker). For PR body.

use crate::delegate_tool;
use crate::repo_path;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::process::Command;

pub struct DiffReviewTool;

#[async_trait]
impl Tool for DiffReviewTool {
    fn name(&self) -> String {
        "diff_review".to_string()
    }

    fn description(&self) -> String {
        "Review your own uncommitted diff before committing. Runs 'git diff' in the repo and sends it to a code-review worker. Returns a short self-audit (unintended changes? simpler approach? bugs?) suitable for a PR description. Use before git_commit. Requires CHUMP_REPO or CHUMP_HOME.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "staged_only": { "type": "boolean", "description": "If true, review only staged changes (git diff --staged). Default false = working tree diff." }
            }
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !repo_path::repo_root_is_explicit() {
            return Err(anyhow!(
                "diff_review requires CHUMP_REPO or CHUMP_HOME to be set"
            ));
        }
        let root = repo_path::repo_root();
        let staged_only = input
            .get("staged_only")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let output = if staged_only {
            Command::new("git")
                .args(["diff", "--staged"])
                .current_dir(&root)
                .output()
        } else {
            Command::new("git")
                .args(["diff", "HEAD"])
                .current_dir(&root)
                .output()
        };
        let out = output.map_err(|e| anyhow!("git diff failed: {}", e))?;
        let diff = String::from_utf8_lossy(&out.stdout).to_string();
        if diff.trim().is_empty() {
            return Ok("No diff to review (working tree clean or nothing staged).".to_string());
        }
        delegate_tool::run_worker_review(&diff).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use serial_test::serial;
    use std::fs;
    use std::path::PathBuf;

    fn test_dir(name: &str) -> PathBuf {
        let d = PathBuf::from("target").join(name);
        let _ = fs::create_dir_all(&d);
        d.canonicalize().unwrap_or(d)
    }

    fn restore_env(name: &str, prev: Option<String>) {
        if let Some(p) = prev {
            std::env::set_var(name, p);
        } else {
            std::env::remove_var(name);
        }
    }

    #[tokio::test]
    async fn diff_review_requires_repo_root() {
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let tool = DiffReviewTool;
        let out = tool.execute(json!({})).await;
        restore_env("CHUMP_REPO", prev_repo);
        restore_env("CHUMP_HOME", prev_home);
        assert!(out.is_err());
        assert!(out.unwrap_err().to_string().contains("CHUMP_REPO"));
    }

    #[tokio::test]
    #[serial]
    async fn diff_review_empty_diff_returns_message() {
        let dir = test_dir("chump_diff_review_test");
        if !dir.join(".git").exists() {
            let _ = std::process::Command::new("git")
                .args(["init"])
                .current_dir(&dir)
                .output();
        }
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::remove_var("CHUMP_HOME");
        let tool = DiffReviewTool;
        let out = tool.execute(json!({})).await.unwrap();
        restore_env("CHUMP_REPO", prev_repo);
        assert!(out.contains("No diff to review"));
        let out_staged = tool.execute(json!({ "staged_only": true })).await.unwrap();
        assert!(out_staged.contains("No diff to review"));
        let _ = fs::remove_dir_all("target/chump_diff_review_test");
    }

    #[tokio::test]
    async fn diff_review_schema_has_staged_only() {
        let tool = DiffReviewTool;
        let schema = tool.input_schema();
        assert!(schema
            .get("properties")
            .and_then(|p| p.get("staged_only"))
            .is_some());
        assert_eq!(tool.name(), "diff_review");
    }
}
