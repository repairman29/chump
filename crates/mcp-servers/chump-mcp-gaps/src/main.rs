//! MCP server: Chump gap registry queries via JSON-RPC 2.0 over stdio.
//! Set CHUMP_REPO (or CHUMP_HOME) to point at the repo root.
//!
//! Supported methods:
//!   - list_open_gaps { priority? }   — list open gaps, optional P1/P2/P3 filter
//!   - get_gap { gap_id }             — return full gap entry by ID
//!   - claim_gap { gap_id }           — run scripts/coord/gap-claim.sh for the gap

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

fn gaps_yaml_path() -> Result<PathBuf> {
    Ok(repo_dir()?.join("docs").join("gaps.yaml"))
}

fn load_gaps_yaml() -> Result<Value> {
    let path = gaps_yaml_path()?;
    let content = std::fs::read_to_string(&path)
        .map_err(|e| anyhow!("failed to read {}: {}", path.display(), e))?;
    let parsed: serde_yaml::Value =
        serde_yaml::from_str(&content).map_err(|e| anyhow!("failed to parse gaps.yaml: {}", e))?;
    let json_val = serde_json::to_value(parsed)
        .map_err(|e| anyhow!("failed to convert gaps.yaml to JSON: {}", e))?;
    Ok(json_val)
}

async fn handle_list_open_gaps(params: &Value) -> Result<Value> {
    let priority_filter = params.get("priority").and_then(|v| v.as_str());
    let data = load_gaps_yaml()?;
    let gaps = data
        .get("gaps")
        .and_then(|g| g.as_array())
        .ok_or_else(|| anyhow!("gaps.yaml has no 'gaps' array"))?;

    let open: Vec<&Value> = gaps
        .iter()
        .filter(|g| {
            let status = g.get("status").and_then(|s| s.as_str()).unwrap_or("");
            if status != "open" {
                return false;
            }
            if let Some(pf) = priority_filter {
                let priority = g.get("priority").and_then(|p| p.as_str()).unwrap_or("");
                return priority.eq_ignore_ascii_case(pf);
            }
            true
        })
        .collect();

    let summary: Vec<Value> = open
        .iter()
        .map(|g| {
            json!({
                "id": g.get("id").unwrap_or(&Value::Null),
                "title": g.get("title").unwrap_or(&Value::Null),
                "domain": g.get("domain").unwrap_or(&Value::Null),
                "priority": g.get("priority").unwrap_or(&Value::Null),
                "effort": g.get("effort").unwrap_or(&Value::Null),
            })
        })
        .collect();

    Ok(json!({
        "success": true,
        "count": summary.len(),
        "gaps": summary
    }))
}

async fn handle_get_gap(params: &Value) -> Result<Value> {
    let gap_id = params
        .get("gap_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing gap_id"))?
        .trim()
        .to_uppercase();

    let data = load_gaps_yaml()?;
    let gaps = data
        .get("gaps")
        .and_then(|g| g.as_array())
        .ok_or_else(|| anyhow!("gaps.yaml has no 'gaps' array"))?;

    let found = gaps.iter().find(|g| {
        g.get("id")
            .and_then(|id| id.as_str())
            .map(|id| id.eq_ignore_ascii_case(&gap_id))
            .unwrap_or(false)
    });

    match found {
        Some(gap) => Ok(json!({ "success": true, "gap": gap })),
        None => Ok(json!({ "success": false, "error": format!("gap '{}' not found", gap_id) })),
    }
}

async fn handle_claim_gap(params: &Value) -> Result<Value> {
    let gap_id = params
        .get("gap_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing gap_id"))?
        .trim()
        .to_string();

    if gap_id.is_empty() {
        return Err(anyhow!("gap_id is empty"));
    }

    let dir = repo_dir()?;
    let script = dir.join("scripts").join("gap-claim.sh");
    if !script.exists() {
        return Err(anyhow!("gap-claim.sh not found at {}", script.display()));
    }

    let out = Command::new("bash")
        .arg(&script)
        .arg(&gap_id)
        .current_dir(&dir)
        .output()
        .await
        .map_err(|e| anyhow!("gap-claim.sh failed: {}", e))?;

    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let combined = if stderr.is_empty() {
        stdout
    } else if stdout.is_empty() {
        stderr
    } else {
        format!("{}\n{}", stdout, stderr)
    };

    Ok(json!({ "success": out.status.success(), "output": combined }))
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "list_open_gaps" => handle_list_open_gaps(params).await,
        "get_gap" => handle_get_gap(params).await,
        "claim_gap" => handle_claim_gap(params).await,
        "tools/list" => Ok(json!({
            "tools": [
                {
                    "name": "list_open_gaps",
                    "description": "List open gaps in the Chump gap registry (docs/gaps.yaml). Optional priority filter (P1, P2, P3).",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "priority": {
                                "type": "string",
                                "description": "Optional priority filter: P1, P2, or P3"
                            }
                        }
                    }
                },
                {
                    "name": "get_gap",
                    "description": "Get full details for a specific gap by ID (e.g. COG-001, MEM-007).",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "gap_id": { "type": "string", "description": "Gap ID, e.g. COG-001" }
                        },
                        "required": ["gap_id"]
                    }
                },
                {
                    "name": "claim_gap",
                    "description": "Claim a gap by running scripts/coord/gap-claim.sh. Requires CHUMP_REPO to be set.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "gap_id": { "type": "string", "description": "Gap ID to claim, e.g. COMP-009" }
                        },
                        "required": ["gap_id"]
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
                println!(
                    "{}",
                    serde_json::to_string(&err_resp)
                        .expect("JsonRpcResponse is always serializable")
                );
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
            println!(
                "{}",
                serde_json::to_string(&err_resp).expect("JsonRpcResponse is always serializable")
            );
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
        println!(
            "{}",
            serde_json::to_string(&resp).expect("JsonRpcResponse is always serializable")
        );
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
        assert!(names.contains(&"list_open_gaps"));
        assert!(names.contains(&"get_gap"));
        assert!(names.contains(&"claim_gap"));
    }

    #[tokio::test]
    async fn get_gap_missing_id_errors() {
        let result = handle_method("get_gap", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn list_open_gaps_no_repo_errors() {
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let result = handle_method("list_open_gaps", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn unknown_method_errors() {
        let result = handle_method("does_not_exist", &json!({})).await;
        assert!(result.is_err());
    }
}
