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
