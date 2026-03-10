//! CLI/exec tool for Chump: run shell commands with timeout and output cap.
//! For private Chump: always on in Discord; no allowlist by default (any command).
//! Set CHUMP_CLI_ALLOWLIST to restrict; set CHUMP_CLI_BLOCKLIST to forbid.

use crate::chump_log;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::process::Command;

const DEFAULT_TIMEOUT_SECS: u64 = 60;
const MAX_OUTPUT_CHARS: usize = 2500;

pub struct CliTool {
    /// If empty, any command is allowed. Otherwise only these (lowercase) executables.
    allowlist: Vec<String>,
    /// Commands (lowercase) to never run, e.g. dangerous defaults.
    blocklist: Vec<String>,
    timeout_secs: u64,
    max_output: usize,
}

impl CliTool {
    /// Test helper: build with explicit allowlist and blocklist (default timeout and output cap).
    pub fn with_allowlist_blocklist(allowlist: Vec<String>, blocklist: Vec<String>) -> Self {
        Self {
            allowlist,
            blocklist,
            timeout_secs: DEFAULT_TIMEOUT_SECS,
            max_output: MAX_OUTPUT_CHARS,
        }
    }

    /// Build for Discord: always enabled. Unset CHUMP_CLI_ALLOWLIST = any command; set it = allowlist only. Optional blocklist.
    pub fn for_discord() -> Self {
        let allowlist: Vec<String> = std::env::var("CHUMP_CLI_ALLOWLIST")
            .ok()
            .map(|s| s.split(',').map(|x| x.trim().to_lowercase()).filter(|x| !x.is_empty()).collect())
            .unwrap_or_default();
        let blocklist: Vec<String> = std::env::var("CHUMP_CLI_BLOCKLIST")
            .ok()
            .map(|s| s.split(',').map(|x| x.trim().to_lowercase()).filter(|x| !x.is_empty()).collect())
            .unwrap_or_default();
        let timeout_secs = std::env::var("CHUMP_CLI_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_TIMEOUT_SECS);
        Self { allowlist, blocklist, timeout_secs, max_output: MAX_OUTPUT_CHARS }
    }

    fn allowed(&self, base: &str) -> bool {
        let b = base.to_lowercase();
        if self.blocklist.contains(&b) {
            return false;
        }
        self.allowlist.is_empty() || self.allowlist.contains(&b)
    }
}

#[async_trait]
impl Tool for CliTool {
    fn name(&self) -> String {
        "run_cli".to_string()
    }

    fn description(&self) -> String {
        "Run a shell command. Pass 'command' as the full command string (e.g. 'ls -la', 'cat README.md', 'git status'). Run one command per call.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "Full shell command (e.g. ls -la, cat README.md, git status)"
                }
            },
            "required": ["command"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        self.run(input).await
    }
}

impl CliTool {
    /// Shared execution so alias tools (git, cargo) can delegate here.
    pub async fn run(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        // Accept "command", "cmd", or "content" (when it looks like a shell command)
        let cmd = input
            .get("command")
            .or_else(|| input.get("cmd"))
            .and_then(|c| c.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let cmd = cmd.or_else(|| {
            let mut c = input.get("content").and_then(|v| v.as_str()).unwrap_or("").trim();
            if c.starts_with("run ") {
                c = c.strip_prefix("run ").unwrap_or(c).trim();
            }
            if !c.is_empty() && !c.contains("\"action\"") && (c.starts_with("cargo") || c.starts_with("git") || c.starts_with("ls") || c.starts_with("cat") || c.starts_with("pwd") || c.starts_with("sh ") || c.contains(" ")) {
                Some(c.to_string())
            } else {
                None
            }
        })
        .ok_or_else(|| anyhow!("missing command (use command, cmd, or content with a shell command)"))?;
        let cmd = cmd.trim().to_string();
        if cmd.is_empty() {
            return Err(anyhow!("empty command"));
        }
        // First token for allowlist/blocklist (e.g. "ls" from "ls -la")
        let base = cmd.split_ascii_whitespace().next().unwrap_or(&cmd);
        if !self.allowed(base) {
            return Err(anyhow!(
                "command not allowed: {} (blocklisted or not in allowlist)",
                base
            ));
        }

        // Run via shell so PATH is used and compound commands work (e.g. "ls -la", "cat README.md")
        let mut c = Command::new(if cfg!(target_os = "windows") { "cmd" } else { "sh" });
        let shell_arg = if cfg!(target_os = "windows") { "/c" } else { "-c" };
        c.arg(shell_arg).arg(&cmd);
        c.current_dir(std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from(".")));

        let output = tokio::time::timeout(
            Duration::from_secs(self.timeout_secs),
            c.output(),
        ).await.map_err(|_| anyhow!("command timed out after {}s", self.timeout_secs))??;

        let mut out = String::new();
        if !output.stdout.is_empty() {
            out.push_str(&String::from_utf8_lossy(&output.stdout));
        }
        if !output.stderr.is_empty() {
            if !out.is_empty() {
                out.push_str("\nstderr:\n");
            }
            out.push_str(&String::from_utf8_lossy(&output.stderr));
        }
        if out.is_empty() {
            out = format!("exit code {}", output.status.code().unwrap_or(-1));
        }
        if out.len() > self.max_output {
            out = format!("{}…", out.chars().take(self.max_output - 1).collect::<String>());
        }
        let exit_code = output.status.code();
        chump_log::log_cli(&cmd, &[], exit_code, out.len());
        Ok(out)
    }
}

/// Alias so when the model calls "git" or "cargo" we still run the command via run_cli logic.
pub struct CliToolAlias {
    pub name: String,
    pub inner: CliTool,
}

#[async_trait]
impl Tool for CliToolAlias {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn description(&self) -> String {
        format!("Run a {} command (same as run_cli). Pass 'command' or 'content' with the full shell command.", self.name)
    }
    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }
    async fn execute(&self, input: Value) -> Result<String> {
        // When model sends git/cargo with wrong shape (e.g. {"command": "main"}), fix up so we run "git main" or "cargo main"
        let input = normalize_alias_input(&self.name, input);
        self.inner.run(input).await
    }
}

fn normalize_alias_input(tool_name: &str, input: Value) -> Value {
    let cmd_str = input.get("command").or_else(|| input.get("cmd")).and_then(|c| c.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    let content_str = input.get("content").and_then(|c| c.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    // If content is already a full command (git/cargo ...), use as-is
    if let Some(ref c) = content_str {
        if c.starts_with("git ") || c.starts_with("cargo ") || c.starts_with("run ") {
            return serde_json::json!({ "command": c.clone() });
        }
    }
    // If we have a command that's just one word (e.g. "main", "status"), treat as subcommand: "git main" / "cargo build"
    if let Some(ref c) = cmd_str {
        if !c.contains(' ') && c.len() < 80 {
            return serde_json::json!({ "command": format!("{} {}", tool_name, c) });
        }
        if !c.starts_with("git ") && !c.starts_with("cargo ") {
            return serde_json::json!({ "command": format!("{} {}", tool_name, c) });
        }
        return serde_json::json!({ "command": c.clone() });
    }
    // No command/cmd; build from first string param
    if let Some(obj) = input.as_object() {
        for (k, v) in obj {
            if k == "action" || k == "parameters" {
                continue;
            }
            if let Some(s) = v.as_str() {
                let s = s.trim();
                if !s.is_empty() && s.len() < 200 {
                    return serde_json::json!({ "command": format!("{} {}", tool_name, s) });
                }
            }
        }
    }
    input
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn run_blocked_command_returns_error() {
        let tool = CliTool::with_allowlist_blocklist(vec![], vec!["rm".into()]);
        let out = tool.run(json!({ "command": "rm -rf /nonexistent" })).await;
        assert!(out.is_err());
        let err = out.unwrap_err().to_string();
        assert!(err.contains("not allowed") || err.contains("blocklist"));
    }

    #[tokio::test]
    async fn run_empty_allowlist_allows_safe_command() {
        let tool = CliTool::with_allowlist_blocklist(vec![], vec![]);
        let out = tool.run(json!({ "command": "echo ok" })).await;
        assert!(out.is_ok());
        assert!(out.unwrap().contains("ok"));
    }

    #[tokio::test]
    async fn run_allowlist_only_listed() {
        let tool = CliTool::with_allowlist_blocklist(vec!["echo".into()], vec![]);
        let out = tool.run(json!({ "command": "echo allowed" })).await;
        assert!(out.is_ok());
        assert!(out.unwrap().contains("allowed"));
        let out = tool.run(json!({ "command": "cat /dev/null" })).await;
        assert!(out.is_err());
    }
}
