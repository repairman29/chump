//! `comprehend_repo` native tool (INFRA-3450) — the fleet's consult into the
//! ChumpOS comprehension organs (almanac-organs). Given any repo path, returns
//! a one-shot comprehension report across every organ (wiring / gates / config
//! + provenance/traces query tools) with honest coverage labels.
//!
//! This is the "run the OS" consult point: before touching an unfamiliar repo,
//! the agent runs `comprehend_repo` to learn what's wired, what gates a change
//! trips, and where config drifts — instead of rediscovering it by trial (the
//! whole "we have X but it's not wired" class this organ set was built to kill).
//!
//! Shells to the `comprehend` binary (built from ~/Projects/almanac). Path via
//! `CHUMP_COMPREHEND_BIN`, else `~/.cargo/bin/comprehend`.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;

/// Resolve the `comprehend` binary: `CHUMP_COMPREHEND_BIN`, else
/// `~/.cargo/bin/comprehend`. Returns `Some(path)` only if it exists.
pub fn comprehend_bin() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("CHUMP_COMPREHEND_BIN") {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }
    let home = std::env::var("HOME").ok()?;
    let default = PathBuf::from(home).join(".cargo/bin/comprehend");
    default.exists().then_some(default)
}

/// Gate: the tool is live only when the `comprehend` binary is present.
pub fn comprehend_available() -> bool {
    if std::env::var("CHUMP_COMPREHEND_ENABLED").as_deref() == Ok("0") {
        return false;
    }
    comprehend_bin().is_some()
}

pub struct ComprehendTool;

#[async_trait]
impl Tool for ComprehendTool {
    fn name(&self) -> String {
        "comprehend_repo".to_string()
    }

    fn description(&self) -> String {
        "Understand a repository BEFORE touching it. Runs the ChumpOS \
         comprehension organs over a repo and returns one report: WIRING (which \
         capabilities are live and what gates them), GATES (which CI/hook gates a \
         change trips + their bypasses), CONFIG (flags + inconsistent-default \
         DRIFT), plus the provenance/traces query tools. Every section carries an \
         honest coverage label (full/partial/none). Call this first on any \
         unfamiliar repo instead of guessing. Param: repo (path; defaults to the \
         current working repo)."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": {
                    "type": "string",
                    "description": "Path to the repo to comprehend (default: current repo root)"
                }
            }
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{e}"));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| crate::repo_path::main_checkout_root().display().to_string());
        let bin = comprehend_bin()
            .ok_or_else(|| anyhow!("comprehend binary not found (set CHUMP_COMPREHEND_BIN)"))?;
        let out = tokio::task::spawn_blocking(move || {
            Command::new(&bin)
                .arg("--repo")
                .arg(&repo)
                .output()
                .map_err(|e| anyhow!("running comprehend: {e}"))
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        })
        .await
        .map_err(|e| anyhow!("comprehend_repo task: {e}"))??;
        let out = out.trim();
        if out.is_empty() {
            Ok("comprehend_repo: empty report (repo path may be invalid).".to_string())
        } else {
            Ok(out.to_string())
        }
    }
}

inventory::submit! {
    crate::tool_inventory::ToolEntry::new(|| Box::new(ComprehendTool), "comprehend_repo")
        .when_enabled(comprehend_available)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bin_resolution_prefers_env_when_set() {
        // A non-existent explicit path must NOT resolve (existence-checked).
        std::env::set_var("CHUMP_COMPREHEND_BIN", "/definitely/not/here/comprehend");
        assert!(comprehend_bin().is_none() || comprehend_bin().unwrap().exists());
        std::env::remove_var("CHUMP_COMPREHEND_BIN");
    }

    #[test]
    fn disabled_flag_forces_unavailable() {
        std::env::set_var("CHUMP_COMPREHEND_ENABLED", "0");
        assert!(!comprehend_available());
        std::env::remove_var("CHUMP_COMPREHEND_ENABLED");
    }

    #[test]
    fn tool_identity() {
        assert_eq!(ComprehendTool.name(), "comprehend_repo");
        assert!(ComprehendTool.description().contains("comprehension"));
        assert!(ComprehendTool.input_schema().get("properties").is_some());
    }
}
