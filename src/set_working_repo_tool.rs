//! set_working_repo tool: set process-scoped repo root for file/git tools (multi-repo mode).
//! Gate: CHUMP_MULTI_REPO_ENABLED=1. Cleared on close_session().

use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;

use crate::repo_path;

fn multi_repo_enabled() -> bool {
    std::env::var("CHUMP_MULTI_REPO_ENABLED")
        .map(|s| s.trim() == "1" || s.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

pub fn set_working_repo_enabled() -> bool {
    multi_repo_enabled() && repo_path::repo_root_is_explicit()
}

pub struct SetWorkingRepoTool;

#[async_trait]
impl Tool for SetWorkingRepoTool {
    fn name(&self) -> String {
        "set_working_repo".to_string()
    }

    fn description(&self) -> String {
        "Set the working repo for this session (file/git tools will use this path). Path can be absolute or relative to CHUMP_HOME/repos/. Must be a git repo (.git present). Call this after github_clone_or_pull to work in the cloned repo. Cleared when the session ends.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Repo path: absolute or relative to CHUMP_HOME/repos/" }
            },
            "required": ["path"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow::anyhow!("{}", e));
        }
        if !set_working_repo_enabled() {
            return Err(anyhow::anyhow!(
                "set_working_repo requires CHUMP_MULTI_REPO_ENABLED=1 and CHUMP_REPO or CHUMP_HOME"
            ));
        }
        let path_str = input
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("missing path"))?
            .trim();
        if path_str.is_empty() {
            return Err(anyhow::anyhow!("path is empty"));
        }

        let path = PathBuf::from(path_str);
        let resolved = if path.is_absolute() {
            path
        } else {
            let base = repo_path::runtime_base().join("repos");
            base.join(path_str.trim_start_matches('/'))
        };

        repo_path::set_working_repo(resolved).map_err(|e| anyhow::anyhow!("{}", e))?;
        let root = repo_path::repo_root();
        Ok(format!(
            "Working repo set to {}. File and git tools will use this path until session end.",
            root.display()
        ))
    }
}
