//! run_battle_qa: run a smoke (or full) battle QA from inside Chump and return structured result.
//! Lets Chump run tests, read failures, fix code, and re-run in a self-heal loop.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;
use tokio::process::Command;
use tokio::time::timeout;

fn repo_root() -> Result<PathBuf> {
    let root = crate::repo_path::repo_root();
    if !root.is_dir() {
        return Err(anyhow!("repo root is not a directory: {}", root.display()));
    }
    Ok(root)
}

/// Parse "Run iter-1: 25 passed, 5 failed" or "[...] passed=25 failed=5" from log text.
fn parse_run_result(log_tail: &str) -> (Option<u32>, Option<u32>) {
    let mut passed = None;
    let mut failed = None;
    for line in log_tail.lines().rev().take(20) {
        if let Some(p) = line.find(" passed, ") {
            if line.find(" failed").is_some() {
                if let Ok(pn) = line[..p]
                    .split_whitespace()
                    .last()
                    .unwrap_or("0")
                    .parse::<u32>()
                {
                    passed = Some(pn);
                }
                let after = &line[p + 9..];
                if let Ok(fn_) = after[..after.find(' ').unwrap_or(after.len())]
                    .trim()
                    .parse::<u32>()
                {
                    failed = Some(fn_);
                }
                break;
            }
        }
        if line.contains("passed=") && line.contains("failed=") {
            for part in line.split_whitespace() {
                if let Some(v) = part.strip_prefix("passed=") {
                    if let Ok(n) = v.trim_end_matches(',').parse::<u32>() {
                        passed = Some(n);
                    }
                }
                if let Some(v) = part.strip_prefix("failed=") {
                    if let Ok(n) = v.parse::<u32>() {
                        failed = Some(n);
                    }
                }
            }
            break;
        }
    }
    (passed, failed)
}

pub struct BattleQaTool;

#[async_trait]
impl Tool for BattleQaTool {
    fn name(&self) -> String {
        "run_battle_qa".to_string()
    }

    fn description(&self) -> String {
        "Run battle QA (smoke or full). Returns pass/fail counts and path to failures file so you can read_file and fix. Use for self-heal: run, read failures, fix code/scripts, re-run. Optional max_queries (default 20 for smoke), timeout_secs per query (default 60).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "max_queries": { "type": "number", "description": "Max queries to run (default 20 for smoke; use 500 for full)" },
                "timeout_secs": { "type": "number", "description": "Per-query timeout in seconds (default 60)" }
            }
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let root = repo_root()?;
        let script = root.join("scripts/battle-qa.sh");
        if !script.is_file() {
            return Err(anyhow!("battle-qa script not found: {}", script.display()));
        }

        let max_queries: u32 = input
            .get("max_queries")
            .and_then(|v| v.as_u64())
            .unwrap_or(20) as u32;
        let timeout_secs: u64 = input
            .get("timeout_secs")
            .and_then(|v| v.as_u64())
            .unwrap_or(60)
            .min(300);

        let total_timeout_secs = (max_queries as u64) * (timeout_secs + 10) + 120;
        let total_timeout = Duration::from_secs(total_timeout_secs);

        let cmd = format!(
            "BATTLE_QA_MAX={} BATTLE_QA_TIMEOUT={} ./scripts/battle-qa.sh",
            max_queries, timeout_secs
        );

        let mut cmd_b = Command::new("bash");
        cmd_b
            .arg("-c")
            .arg(&cmd)
            .current_dir(&root)
            .env("BATTLE_QA_MAX", max_queries.to_string())
            .env("BATTLE_QA_TIMEOUT", timeout_secs.to_string())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        let outcome = timeout(total_timeout, cmd_b.output()).await;
        let output = match outcome {
            Ok(Ok(o)) => o,
            Ok(Err(e)) => return Err(anyhow!("battle-qa spawn/run: {}", e)),
            Err(_) => {
                return Err(anyhow!(
                    "battle-qa timed out after {}s (run {} queries at {}s each)",
                    total_timeout_secs,
                    max_queries,
                    timeout_secs
                ));
            }
        };
        let exit_status = output.status;
        let script_stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let script_stderr = String::from_utf8_lossy(&output.stderr).to_string();
        fn cap(s: &str, max: usize) -> String {
            if s.len() <= max {
                s.to_string()
            } else {
                format!("...{}", &s[s.len().saturating_sub(max)..])
            }
        }
        let stdout_tail = cap(&script_stdout, 4000);
        let stderr_tail = cap(&script_stderr, 4000);

        let log_path = root.join("logs/battle-qa.log");
        let failures_path = root.join("logs/battle-qa-failures.txt");
        let log_tail = if log_path.is_file() {
            let content = tokio::fs::read_to_string(&log_path)
                .await
                .unwrap_or_default();
            let len = content.len();
            let start = len.saturating_sub(2500);
            content[start..].to_string()
        } else {
            String::new()
        };

        let (passed, failed) = parse_run_result(&log_tail);
        let failed_count = if failures_path.is_file() {
            let content = tokio::fs::read_to_string(&failures_path)
                .await
                .unwrap_or_default();
            content.lines().filter(|l| l.starts_with("FAIL ")).count() as u32
        } else {
            failed.unwrap_or(0)
        };
        let passed_count = passed.unwrap_or_else(|| {
            if failed_count > 0 && max_queries >= failed_count {
                max_queries - failed_count
            } else {
                0
            }
        });

        let ok = exit_status.success() && failed_count == 0;
        let failures_path_str = "logs/battle-qa-failures.txt".to_string();

        let out = json!({
            "ok": ok,
            "passed": passed_count,
            "failed": failed_count,
            "total": max_queries,
            "failures_path": failures_path_str,
            "log_path": "logs/battle-qa.log",
            "log_tail": log_tail,
            "script_stdout_tail": stdout_tail,
            "script_stderr_tail": stderr_tail,
            "exit_code": exit_status.code().unwrap_or(-1)
        });
        Ok(out.to_string())
    }
}
