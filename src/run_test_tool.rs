//! run_test tool: run tests (cargo test, pnpm test, npm test) and return structured pass/fail summary.
//! Registered when CHUMP_REPO is set. Enables "run tests, then fix failing tests" loops.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;

use crate::repo_path;

fn repo_cwd(cwd: Option<&str>) -> Result<PathBuf> {
    let root = repo_path::repo_root();
    if let Some(p) = cwd.filter(|s| !s.trim().is_empty()) {
        let rel = p.trim().trim_start_matches('/');
        if rel.is_empty() {
            Ok(root)
        } else {
            repo_path::resolve_under_root(rel).map_err(|e| anyhow!("{}", e))
        }
    } else {
        Ok(root)
    }
}

/// Parse cargo test output for pass/fail/skip counts and failing test names. Used by test_aware.
pub(crate) fn parse_cargo_test(stdout: &str, stderr: &str) -> (u32, u32, u32, Vec<String>) {
    let combined = format!("{}\n{}", stdout, stderr);
    let mut passed = 0u32;
    let mut failed = 0u32;
    let mut ignored = 0u32;
    let mut failing_tests: Vec<String> = Vec::new();

    for line in combined.lines() {
        let line = line.trim();
        if line.starts_with("test ") && line.ends_with(" ... ok") {
            passed += 1;
        } else if line.starts_with("test ") && (line.ends_with(" ... FAILED") || line.contains("FAILED")) {
            failed += 1;
            let name = line
                .strip_prefix("test ")
                .and_then(|s| s.split(" ...").next())
                .unwrap_or(line)
                .trim()
                .to_string();
            if !name.is_empty() && !failing_tests.contains(&name) {
                failing_tests.push(name);
            }
        } else if line.starts_with("test ") && line.ends_with(" ... ignored") {
            ignored += 1;
        }
    }
    if passed == 0 && failed == 0 && ignored == 0 {
        if let Some(line) = combined.lines().find(|l| l.contains("test result:") || l.contains("passed;")) {
            if let Some(rest) = line.split("ok.").nth(1).or_else(|| line.split("FAILED").next()) {
                for part in rest.split(';') {
                    let part = part.trim();
                    if let Some(n) = part.strip_prefix("passed").and_then(|s| s.trim().strip_prefix(' ')).and_then(|s| s.split_whitespace().next()).and_then(|s| s.parse::<u32>().ok()) {
                        passed += n;
                    }
                    if let Some(n) = part.strip_prefix("failed").and_then(|s| s.trim().strip_prefix(' ')).and_then(|s| s.split_whitespace().next()).and_then(|s| s.parse::<u32>().ok()) {
                        failed += n;
                    }
                    if let Some(n) = part.strip_prefix("ignored").and_then(|s| s.trim().strip_prefix(' ')).and_then(|s| s.split_whitespace().next()).and_then(|s| s.parse::<u32>().ok()) {
                        ignored += n;
                    }
                }
            }
        }
    }
    (passed, failed, ignored, failing_tests)
}

pub struct RunTestTool;

#[async_trait]
impl Tool for RunTestTool {
    fn name(&self) -> String {
        "run_test".to_string()
    }

    fn description(&self) -> String {
        "Run tests and get a structured pass/fail summary. Params: cwd (optional, relative to repo root), filter (optional, test name substring), runner (optional: 'cargo', 'pnpm', 'npm'; default cargo). Use for 'run tests then fix failing tests' loops.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "cwd": { "type": "string", "description": "Working directory relative to repo root (default repo root)" },
                "filter": { "type": "string", "description": "Test name substring to filter (e.g. test_foo)" },
                "runner": { "type": "string", "description": "cargo (default), pnpm, or npm" }
            },
            "required": []
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let cwd = input.get("cwd").and_then(|v| v.as_str());
        let cwd = repo_cwd(cwd)?;
        let filter = input
            .get("filter")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let runner = input
            .get("runner")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_lowercase())
            .unwrap_or_else(|| "cargo".to_string());

        let (passed, failed, ignored, failing_tests) = match runner.as_str() {
            "cargo" => {
                let mut args = vec!["test".to_string()];
                if let Some(ref f) = filter {
                    args.push(f.clone());
                }
                let out = Command::new("cargo")
                    .args(&args)
                    .current_dir(&cwd)
                    .output()?;
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                parse_cargo_test(&stdout, &stderr)
            }
            "pnpm" | "npm" => {
                let cmd = if runner == "pnpm" { "pnpm" } else { "npm" };
                let out = Command::new(cmd)
                    .arg("test")
                    .current_dir(&cwd)
                    .output()?;
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                let code = out.status.code().unwrap_or(-1);
                if code == 0 {
                    (1, 0, 0, vec![])
                } else {
                    let snippet: String = format!("{}\n{}", stdout, stderr).lines().rev().take(15).collect::<Vec<_>>().join("\n");
                    (0, 1, 0, vec![format!("{} test run failed (exit {}). Last lines:\n{}", cmd, code, snippet)])
                }
            }
            _ => return Err(anyhow!("runner must be cargo, pnpm, or npm")),
        };

        let summary = format!(
            "passed={} failed={} ignored={}. Failing: [{}]",
            passed,
            failed,
            ignored,
            failing_tests.join(", ")
        );
        Ok(summary)
    }
}
