//! MCP server: GitHub operations via `gh` CLI.
//! JSON-RPC 2.0 over stdio. Each request is one line of JSON on stdin, response on stdout.
//!
//! Supported methods (matching the tool names in the main binary):
//!   - gh_list_issues { repo, label?, state? }
//!   - gh_create_issue { repo, title, body?, labels? }
//!   - gh_list_my_prs { repo?, state? }
//!   - gh_pr_status { repo }
//!   - gh_pr_create { repo, title, body?, base?, head? }
//!   - gh_repo_info { repo }
//!   - gh_get_issue { repo, number }
//!   - gh_create_branch { name }
//!   - gh_pr_checks { pr_number }
//!   - gh_pr_comment { pr_number, body }
//!   - gh_pr_view_comments { pr_number }
//!   - github_clone_or_pull { repo, ref? }

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

#[derive(Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    method: String,
    #[serde(default)]
    params: Value,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    result: Option<Value>,
    error: Option<JsonRpcError>,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
}

fn repo_dir() -> Result<PathBuf> {
    let path = std::env::var("CHUMP_REPO")
        .or_else(|_| std::env::var("CHUMP_HOME"))
        .map_err(|_| anyhow!("CHUMP_REPO or CHUMP_HOME must be set"))?;
    let p = PathBuf::from(path.trim());
    if !p.is_dir() {
        return Err(anyhow!("CHUMP_REPO is not a directory"));
    }
    Ok(p)
}

fn allowed_repos() -> Vec<String> {
    std::env::var("CHUMP_GITHUB_REPOS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn check_repo(repo: &str) -> Result<()> {
    let allowed = allowed_repos();
    if allowed.is_empty() {
        return Ok(()); // No allowlist = all repos allowed
    }
    if allowed.iter().any(|r| r == repo) {
        Ok(())
    } else {
        Err(anyhow!("repo '{}' not in CHUMP_GITHUB_REPOS allowlist", repo))
    }
}

async fn run_gh(args: &[&str]) -> Result<(bool, String)> {
    let dir = repo_dir()?;
    let out = Command::new("gh")
        .args(args)
        .current_dir(&dir)
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

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "gh_list_issues" => {
            let repo = params["repo"].as_str().ok_or_else(|| anyhow!("missing repo"))?;
            check_repo(repo)?;
            let label = params["label"].as_str().unwrap_or("");
            let state = params["state"].as_str().unwrap_or("open");
            let mut args = vec!["issue", "list", "-R", repo, "--state", state, "--limit", "20"];
            if !label.is_empty() {
                args.push("--label");
                args.push(label);
            }
            let (ok, out) = run_gh(&args).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_create_issue" => {
            let repo = params["repo"].as_str().ok_or_else(|| anyhow!("missing repo"))?;
            check_repo(repo)?;
            let title = params["title"].as_str().ok_or_else(|| anyhow!("missing title"))?;
            let body = params["body"].as_str().unwrap_or("");
            let labels = params["labels"].as_str().unwrap_or("");
            let mut args = vec!["issue", "create", "-R", repo, "--title", title];
            if !body.is_empty() {
                args.push("--body");
                args.push(body);
            }
            if !labels.is_empty() {
                args.push("--label");
                args.push(labels);
            }
            let (ok, out) = run_gh(&args).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_list_my_prs" => {
            let repo = params["repo"].as_str().unwrap_or("");
            let state = params["state"].as_str().unwrap_or("open");
            let mut args = vec!["pr", "list", "--author", "@me", "--state", state, "--limit", "20"];
            if !repo.is_empty() {
                check_repo(repo)?;
                args.insert(2, "-R");
                args.insert(3, repo);
            }
            let (ok, out) = run_gh(&args).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_pr_status" => {
            let repo = params["repo"].as_str().ok_or_else(|| anyhow!("missing repo"))?;
            check_repo(repo)?;
            let (ok, out) = run_gh(&["pr", "status", "-R", repo]).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_pr_create" => {
            let repo = params["repo"].as_str().ok_or_else(|| anyhow!("missing repo"))?;
            check_repo(repo)?;
            let title = params["title"].as_str().ok_or_else(|| anyhow!("missing title"))?;
            let body = params["body"].as_str().unwrap_or("");
            let base = params["base"].as_str().unwrap_or("main");
            let mut args = vec!["pr", "create", "-R", repo, "--title", title, "--base", base];
            if !body.is_empty() {
                args.push("--body");
                args.push(body);
            }
            if let Some(head) = params["head"].as_str() {
                args.push("--head");
                args.push(head);
            }
            let (ok, out) = run_gh(&args).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_repo_info" => {
            let repo = params["repo"].as_str().ok_or_else(|| anyhow!("missing repo"))?;
            check_repo(repo)?;
            let (ok, out) = run_gh(&["repo", "view", repo, "--json", "name,description,defaultBranchRef,stargazerCount,forkCount"]).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_get_issue" => {
            let repo = params["repo"].as_str().ok_or_else(|| anyhow!("missing repo"))?;
            check_repo(repo)?;
            let number = params["number"]
                .as_u64()
                .or_else(|| params["number"].as_str().and_then(|s| s.parse().ok()))
                .ok_or_else(|| anyhow!("missing number"))?;
            let num_str = number.to_string();
            let (ok, out) = run_gh(&["issue", "view", &num_str, "-R", repo, "--json", "title,body,comments"]).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_create_branch" => {
            let name = params["name"].as_str().ok_or_else(|| anyhow!("missing name"))?;
            let dir = repo_dir()?;
            let out = Command::new("git")
                .args(["checkout", "-b", name])
                .current_dir(&dir)
                .output()
                .await
                .map_err(|e| anyhow!("git checkout -b failed: {}", e))?;
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            let combined = if stderr.is_empty() { stdout } else if stdout.is_empty() { stderr } else { format!("{}\n{}", stdout, stderr) };
            Ok(json!({ "success": out.status.success(), "output": combined }))
        }
        "gh_pr_checks" => {
            let pr_number = params["pr_number"]
                .as_u64()
                .or_else(|| params["pr_number"].as_str().and_then(|s| s.parse().ok()))
                .ok_or_else(|| anyhow!("missing pr_number"))?;
            let num_str = pr_number.to_string();
            let (ok, out) = run_gh(&["pr", "checks", &num_str]).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_pr_comment" => {
            let pr_number = params["pr_number"]
                .as_u64()
                .or_else(|| params["pr_number"].as_str().and_then(|s| s.parse().ok()))
                .ok_or_else(|| anyhow!("missing pr_number"))?;
            let body = params["body"].as_str().ok_or_else(|| anyhow!("missing body"))?;
            let num_str = pr_number.to_string();
            let (ok, out) = run_gh(&["pr", "comment", &num_str, "--body", body]).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "gh_pr_view_comments" => {
            let pr_number = params["pr_number"]
                .as_u64()
                .or_else(|| params["pr_number"].as_str().and_then(|s| s.parse().ok()))
                .ok_or_else(|| anyhow!("missing pr_number"))?;
            let num_str = pr_number.to_string();
            let (ok, out) = run_gh(&["pr", "view", &num_str, "--comments"]).await?;
            Ok(json!({ "success": ok, "output": out }))
        }
        "github_clone_or_pull" => {
            let repo = params["repo"].as_str().ok_or_else(|| anyhow!("missing repo"))?;
            check_repo(repo)?;
            let git_ref = params["ref"].as_str().unwrap_or("main");
            let token = std::env::var("GITHUB_TOKEN")
                .map_err(|_| anyhow!("GITHUB_TOKEN must be set for clone/pull"))?;
            let clone_url = format!("https://x-access-token:{}@github.com/{}.git", token, repo);

            // Determine target directory: CHUMP_HOME/repos/{owner}_{name}
            let chump_home = std::env::var("CHUMP_HOME")
                .map_err(|_| anyhow!("CHUMP_HOME must be set"))?;
            let safe_name = repo.replace('/', "_");
            let target = PathBuf::from(&chump_home).join("repos").join(&safe_name);

            if target.join(".git").is_dir() {
                // Pull
                let out = Command::new("git")
                    .args(["pull", "origin", git_ref])
                    .current_dir(&target)
                    .output()
                    .await
                    .map_err(|e| anyhow!("git pull failed: {}", e))?;
                let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
                let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
                let combined = if stderr.is_empty() { stdout } else if stdout.is_empty() { stderr } else { format!("{}\n{}", stdout, stderr) };
                Ok(json!({ "success": out.status.success(), "output": combined, "path": target.to_string_lossy() }))
            } else {
                // Clone
                std::fs::create_dir_all(&target)
                    .map_err(|e| anyhow!("failed to create target dir: {}", e))?;
                let out = Command::new("git")
                    .args(["clone", "--branch", git_ref, &clone_url, target.to_str().unwrap()])
                    .output()
                    .await
                    .map_err(|e| anyhow!("git clone failed: {}", e))?;
                let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
                let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
                let combined = if stderr.is_empty() { stdout } else if stdout.is_empty() { stderr } else { format!("{}\n{}", stdout, stderr) };
                Ok(json!({ "success": out.status.success(), "output": combined, "path": target.to_string_lossy() }))
            }
        }
        // MCP protocol: tool listing
        "tools/list" => {
            Ok(json!({
                "tools": [
                    { "name": "gh_list_issues", "description": "List GitHub issues", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" }, "label": { "type": "string" }, "state": { "type": "string" } }, "required": ["repo"] } },
                    { "name": "gh_create_issue", "description": "Create a GitHub issue", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" }, "title": { "type": "string" }, "body": { "type": "string" }, "labels": { "type": "string" } }, "required": ["repo", "title"] } },
                    { "name": "gh_list_my_prs", "description": "List my open PRs", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" }, "state": { "type": "string" } } } },
                    { "name": "gh_pr_status", "description": "PR status for a repo", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" } }, "required": ["repo"] } },
                    { "name": "gh_pr_create", "description": "Create a PR", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" }, "title": { "type": "string" }, "body": { "type": "string" }, "base": { "type": "string" }, "head": { "type": "string" } }, "required": ["repo", "title"] } },
                    { "name": "gh_repo_info", "description": "Get repo info", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" } }, "required": ["repo"] } },
                    { "name": "gh_get_issue", "description": "Get full issue body and comments", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" }, "number": { "type": "integer" } }, "required": ["repo", "number"] } },
                    { "name": "gh_create_branch", "description": "Create and checkout a new branch", "inputSchema": { "type": "object", "properties": { "name": { "type": "string" } }, "required": ["name"] } },
                    { "name": "gh_pr_checks", "description": "Get CI/check status for a PR", "inputSchema": { "type": "object", "properties": { "pr_number": { "type": "integer" } }, "required": ["pr_number"] } },
                    { "name": "gh_pr_comment", "description": "Add a comment to a PR", "inputSchema": { "type": "object", "properties": { "pr_number": { "type": "integer" }, "body": { "type": "string" } }, "required": ["pr_number", "body"] } },
                    { "name": "gh_pr_view_comments", "description": "View PR comments", "inputSchema": { "type": "object", "properties": { "pr_number": { "type": "integer" } }, "required": ["pr_number"] } },
                    { "name": "github_clone_or_pull", "description": "Clone a repo or pull if it already exists locally", "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" }, "ref": { "type": "string", "default": "main" } }, "required": ["repo"] } },
                ]
            }))
        }
        _ => Err(anyhow!("unknown method: {}", method)),
    }
}

#[tokio::main]
async fn main() {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let req: JsonRpcRequest = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32700,
                        message: format!("Parse error: {}", e),
                    }),
                    id: Value::Null,
                };
                println!("{}", serde_json::to_string(&err_resp).unwrap());
                continue;
            }
        };

        if req.jsonrpc != "2.0" {
            let err_resp = JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32600,
                    message: "Invalid Request: jsonrpc must be \"2.0\"".to_string(),
                }),
                id: req.id,
            };
            println!("{}", serde_json::to_string(&err_resp).unwrap());
            continue;
        }

        let resp = match handle_method(&req.method, &req.params).await {
            Ok(result) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: Some(result),
                error: None,
                id: req.id,
            },
            Err(e) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32603,
                    message: e.to_string(),
                }),
                id: req.id,
            },
        };
        println!("{}", serde_json::to_string(&resp).unwrap());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_request() {
        let json = r#"{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}"#;
        let req: JsonRpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.method, "tools/list");
        assert_eq!(req.id, json!(1));
    }

    #[test]
    fn check_repo_empty_allowlist() {
        // With no CHUMP_GITHUB_REPOS set, all repos should be allowed
        std::env::remove_var("CHUMP_GITHUB_REPOS");
        assert!(check_repo("any/repo").is_ok());
    }
}
