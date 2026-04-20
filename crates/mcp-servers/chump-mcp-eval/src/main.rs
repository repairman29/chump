//! MCP server: Chump eval harness runner via JSON-RPC 2.0 over stdio.
//! Set CHUMP_REPO (or CHUMP_HOME) to point at the repo root.
//!
//! Supported methods:
//!   - list_fixtures {}                          — list fixture files in scripts/ab-harness/fixtures/
//!   - run_ab_sweep { fixture_path, model, n_per_cell? }  — run scripts/ab-harness/run-cloud-v2.py
//!   - get_sweep_results { tag }                — read logs/ab-harness/<tag>/summary.json

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
        return Err(anyhow!("CHUMP_REPO is not a directory: {}", p.display()));
    }
    Ok(p)
}

async fn handle_list_fixtures(_params: &Value) -> Result<Value> {
    let dir = repo_dir()?
        .join("scripts")
        .join("ab-harness")
        .join("fixtures");
    if !dir.is_dir() {
        return Err(anyhow!("fixtures directory not found: {}", dir.display()));
    }

    let mut entries: Vec<String> = Vec::new();
    let mut read_dir = tokio::fs::read_dir(&dir)
        .await
        .map_err(|e| anyhow!("failed to read fixtures dir: {}", e))?;

    while let Some(entry) = read_dir
        .next_entry()
        .await
        .map_err(|e| anyhow!("read dir error: {}", e))?
    {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.ends_with(".json") {
            entries.push(name);
        }
    }
    entries.sort();

    Ok(json!({
        "success": true,
        "fixtures_dir": dir.to_string_lossy(),
        "fixtures": entries
    }))
}

async fn handle_run_ab_sweep(params: &Value) -> Result<Value> {
    let fixture_path = params
        .get("fixture_path")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing fixture_path"))?
        .trim()
        .to_string();
    let model = params
        .get("model")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing model"))?
        .trim()
        .to_string();
    let n_per_cell = params
        .get("n_per_cell")
        .and_then(|v| v.as_u64())
        .map(|n| n.clamp(1, 50) as u32)
        .unwrap_or(5);

    if fixture_path.is_empty() {
        return Err(anyhow!("fixture_path is empty"));
    }
    if model.is_empty() {
        return Err(anyhow!("model is empty"));
    }

    let dir = repo_dir()?;
    let script = dir
        .join("scripts")
        .join("ab-harness")
        .join("run-cloud-v2.py");
    if !script.exists() {
        return Err(anyhow!("run-cloud-v2.py not found at {}", script.display()));
    }

    let out = Command::new("python3")
        .arg(&script)
        .arg("--fixture")
        .arg(&fixture_path)
        .arg("--model")
        .arg(&model)
        .arg("--n-per-cell")
        .arg(n_per_cell.to_string())
        .current_dir(&dir)
        .output()
        .await
        .map_err(|e| anyhow!("run-cloud-v2.py failed: {}", e))?;

    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let combined = if stderr.is_empty() {
        stdout
    } else if stdout.is_empty() {
        stderr
    } else {
        format!("{}\n{}", stdout, stderr)
    };

    // Trim output to a reasonable size for the MCP transport
    let trimmed = if combined.len() > 4000 {
        format!(
            "{}...(truncated, {} bytes total)",
            &combined[..4000],
            combined.len()
        )
    } else {
        combined
    };

    Ok(json!({ "success": out.status.success(), "output": trimmed }))
}

async fn handle_get_sweep_results(params: &Value) -> Result<Value> {
    let tag = params
        .get("tag")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing tag"))?
        .trim()
        .to_string();

    if tag.is_empty() {
        return Err(anyhow!("tag is empty"));
    }
    // Guard against path traversal
    if tag.contains('/') || tag.contains("..") {
        return Err(anyhow!("tag must not contain path separators"));
    }

    let dir = repo_dir()?;
    let summary_path = dir
        .join("logs")
        .join("ab-harness")
        .join(&tag)
        .join("summary.json");

    if !summary_path.exists() {
        return Ok(json!({
            "success": false,
            "error": format!("summary.json not found for tag '{}' at {}", tag, summary_path.display())
        }));
    }

    let content = tokio::fs::read_to_string(&summary_path)
        .await
        .map_err(|e| anyhow!("failed to read summary.json: {}", e))?;

    let parsed: Value =
        serde_json::from_str(&content).unwrap_or_else(|_| json!({ "raw": content }));

    Ok(json!({ "success": true, "tag": tag, "summary": parsed }))
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "list_fixtures" => handle_list_fixtures(params).await,
        "run_ab_sweep" => handle_run_ab_sweep(params).await,
        "get_sweep_results" => handle_get_sweep_results(params).await,
        "tools/list" => Ok(json!({
            "tools": [
                {
                    "name": "list_fixtures",
                    "description": "List available eval fixture files in scripts/ab-harness/fixtures/. Requires CHUMP_REPO.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {}
                    }
                },
                {
                    "name": "run_ab_sweep",
                    "description": "Run an A/B eval sweep via scripts/ab-harness/run-cloud-v2.py. Requires CHUMP_REPO and a Python environment with the harness deps installed.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "fixture_path": { "type": "string", "description": "Path to fixture JSON (relative to repo root or absolute)" },
                            "model": { "type": "string", "description": "Model identifier to evaluate against" },
                            "n_per_cell": { "type": "integer", "description": "Number of trials per cell (default 5, max 50)" }
                        },
                        "required": ["fixture_path", "model"]
                    }
                },
                {
                    "name": "get_sweep_results",
                    "description": "Read summary.json for a completed sweep identified by its tag. Results live in logs/ab-harness/<tag>/summary.json.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "tag": { "type": "string", "description": "Sweep tag/run identifier" }
                        },
                        "required": ["tag"]
                    }
                }
            ]
        })),
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

    #[tokio::test]
    async fn tools_list_has_three_tools() {
        let result = handle_method("tools/list", &json!({})).await.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 3);
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"list_fixtures"));
        assert!(names.contains(&"run_ab_sweep"));
        assert!(names.contains(&"get_sweep_results"));
    }

    #[tokio::test]
    async fn run_ab_sweep_missing_params_errors() {
        let result = handle_method("run_ab_sweep", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn get_sweep_results_missing_tag_errors() {
        let result = handle_method("get_sweep_results", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn get_sweep_results_path_traversal_blocked() {
        std::env::set_var("CHUMP_REPO", "/tmp");
        let result = handle_method("get_sweep_results", &json!({ "tag": "../../../etc" })).await;
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("path separators"));
    }

    #[tokio::test]
    async fn unknown_method_errors() {
        let result = handle_method("does_not_exist", &json!({})).await;
        assert!(result.is_err());
    }
}
