//! Report which CLI tools are installed (runs scripts/verify-toolkit.sh --json).
//! Lets Chump reason about missing tools and suggest bootstrap or discovery.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::json;
use std::path::PathBuf;
use tokio::process::Command;

use crate::repo_path;

pub struct ToolkitStatusTool;

#[async_trait]
impl Tool for ToolkitStatusTool {
    fn name(&self) -> String {
        "toolkit_status".to_string()
    }

    fn description(&self) -> String {
        "Report which CLI tools are installed on this machine (by category: search, quality, data, system, network, git, docs, automation, ai, core). Returns JSON: total, installed, missing, and a list of tools with name, bin, category, installed. Use to decide what to install or document.".to_string()
    }

    fn input_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {},
            "required": []
        })
    }

    async fn execute(&self, _input: serde_json::Value) -> Result<String> {
        let root: PathBuf = repo_path::repo_root();
        let script = root.join("scripts").join("verify-toolkit.sh");
        if !script.is_file() {
            return Ok("scripts/verify-toolkit.sh not found; run from Chump repo root.".to_string());
        }
        let out = Command::new("bash")
            .arg(script.as_os_str())
            .arg("--json")
            .current_dir(&root)
            .output()
            .await?;
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Ok(format!("verify-toolkit.sh failed: {}", stderr.trim()));
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        Ok(stdout.trim().to_string())
    }
}
