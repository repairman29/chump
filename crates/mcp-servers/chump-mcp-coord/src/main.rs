//! MCP server: Chump fleet coordination (gap preflight, leases, musher, ambient).
//!
//! Set `CHUMP_REPO` or `CHUMP_HOME` to the repository root. Optional `CHUMP_LOCK_DIR`
//! matches `scripts/gap-preflight.sh` / `gap-claim.sh` for tests.
//!
//! Security: tools never read `.env` and never write `docs/gaps.yaml`.

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
        .map_err(|_| {
            anyhow!("CHUMP_REPO or CHUMP_HOME must be set to the Chump repository root")
        })?;
    let p = PathBuf::from(path.trim());
    if !p.is_dir() {
        return Err(anyhow!("CHUMP_REPO is not a directory: {}", p.display()));
    }
    Ok(p)
}

fn lock_dir() -> Result<PathBuf> {
    let repo = repo_dir()?;
    Ok(std::env::var("CHUMP_LOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo.join(".chump-locks")))
}

fn ambient_path() -> Result<PathBuf> {
    Ok(lock_dir()?.join("ambient.jsonl"))
}

fn reject_secret_leak(s: &str) -> Result<()> {
    if s.to_lowercase().contains(".env") {
        return Err(anyhow!(
            "refusing parameters that reference .env (keep secrets out of MCP tools)"
        ));
    }
    Ok(())
}

async fn run_bash_script(script_rel: &str, args: &[String]) -> Result<Value> {
    let repo = repo_dir()?;
    let script = repo.join("scripts").join(script_rel);
    if !script.is_file() {
        return Err(anyhow!(
            "script not found: {} (check CHUMP_REPO)",
            script.display()
        ));
    }
    for a in args {
        reject_secret_leak(a)?;
    }

    let mut cmd = Command::new("bash");
    cmd.arg(&script);
    for a in args {
        cmd.arg(a);
    }
    cmd.current_dir(&repo);
    cmd.env("CHUMP_LOCK_DIR", lock_dir()?.to_string_lossy().as_ref());

    let out = cmd
        .output()
        .await
        .map_err(|e| anyhow!("failed to run {}: {}", script_rel, e))?;

    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    Ok(json!({
        "success": out.status.success(),
        "exit_code": out.status.code(),
        "stdout": stdout,
        "stderr": stderr,
    }))
}

fn valid_gap_token(s: &str) -> bool {
    !s.is_empty() && s.contains('-') && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

async fn handle_gap_preflight(params: &Value) -> Result<Value> {
    let ids = params
        .get("gap_ids")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("missing gap_ids (non-empty array of strings)"))?;
    if ids.is_empty() {
        return Err(anyhow!("gap_ids must be non-empty"));
    }
    let mut args = Vec::new();
    for id in ids {
        let s = id
            .as_str()
            .ok_or_else(|| anyhow!("gap_ids must be strings"))?
            .trim()
            .to_string();
        reject_secret_leak(&s)?;
        if !valid_gap_token(&s) {
            return Err(anyhow!("invalid gap id: {}", s));
        }
        args.push(s);
    }
    run_bash_script("gap-preflight.sh", &args).await
}

async fn handle_gap_claim_lease(params: &Value) -> Result<Value> {
    let gap_id = params
        .get("gap_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing gap_id"))?
        .trim()
        .to_string();
    reject_secret_leak(&gap_id)?;
    if !valid_gap_token(&gap_id) {
        return Err(anyhow!("invalid gap_id"));
    }

    let paths_csv = params
        .get("paths")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if !paths_csv.is_empty() {
        reject_secret_leak(&paths_csv)?;
    }

    let mut args = vec![gap_id];
    if !paths_csv.is_empty() {
        args.push("--paths".into());
        args.push(paths_csv);
    }
    run_bash_script("gap-claim.sh", &args).await
}

async fn handle_lease_list_active(params: &Value) -> Result<Value> {
    let limit = params
        .get("limit")
        .and_then(|v| v.as_u64())
        .unwrap_or(50)
        .min(200) as usize;

    let dir = lock_dir()?;
    if !dir.is_dir() {
        return Ok(json!({
            "success": true,
            "leases": Value::Array(vec![]),
            "note": "lock directory does not exist"
        }));
    }

    let mut leases = Vec::new();
    for ent in std::fs::read_dir(&dir).map_err(|e| anyhow!("read_dir: {}", e))? {
        let ent = ent.map_err(|e| anyhow!("read_dir entry: {}", e))?;
        let name = ent.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".json") || name.starts_with('.') {
            continue;
        }
        let path = ent.path();
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let v: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => continue,
        };
        leases.push(json!({
            "file": name,
            "session_id": v.get("session_id"),
            "gap_id": v.get("gap_id"),
            "expires_at": v.get("expires_at"),
            "heartbeat_at": v.get("heartbeat_at"),
            "pending_new_gap": v.get("pending_new_gap"),
        }));
        if leases.len() >= limit {
            break;
        }
    }

    Ok(json!({
        "success": true,
        "count": leases.len(),
        "leases": Value::Array(leases),
    }))
}

async fn handle_musher_pick(_params: &Value) -> Result<Value> {
    run_bash_script("musher.sh", &["--pick".to_string()]).await
}

async fn handle_ambient_tail(params: &Value) -> Result<Value> {
    let n = params
        .get("lines")
        .and_then(|v| v.as_u64())
        .unwrap_or(30)
        .min(500) as usize;

    let path = ambient_path()?;
    if !path.is_file() {
        return Ok(json!({
            "success": true,
            "lines": Value::Array(vec![]),
            "note": "ambient.jsonl not present"
        }));
    }
    let text = std::fs::read_to_string(&path).map_err(|e| anyhow!("read ambient: {}", e))?;
    let all: Vec<&str> = text.lines().collect();
    let start = all.len().saturating_sub(n);
    let tail: Vec<Value> = all[start..]
        .iter()
        .map(|line| Value::String((*line).to_string()))
        .collect();

    Ok(json!({
        "success": true,
        "line_count": tail.len(),
        "lines": Value::Array(tail),
    }))
}

fn tools_list_json() -> Value {
    json!({
        "tools": [
            {
                "name": "gap_preflight",
                "description": "Run scripts/gap-preflight.sh for one or more gap IDs (read-only against origin/main + leases).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "gap_ids": {
                            "type": "array",
                            "items": { "type": "string" },
                            "description": "Gap IDs to check, e.g. [\"INFRA-033\"]"
                        }
                    },
                    "required": ["gap_ids"]
                }
            },
            {
                "name": "gap_claim_lease",
                "description": "Run scripts/gap-claim.sh to write/update the session lease JSON (never edits docs/gaps.yaml).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "gap_id": { "type": "string" },
                        "paths": { "type": "string", "description": "Optional comma-separated paths for --paths" }
                    },
                    "required": ["gap_id"]
                }
            },
            {
                "name": "lease_list_active",
                "description": "List JSON lease files under CHUMP_LOCK_DIR (or .chump-locks/), newest batch up to limit.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "limit": { "type": "integer", "description": "Max leases to return (default 50, max 200)" }
                    }
                }
            },
            {
                "name": "musher_pick",
                "description": "Run scripts/musher.sh --pick (may exit non-zero when queue is empty).",
                "inputSchema": { "type": "object", "properties": {} }
            },
            {
                "name": "ambient_tail",
                "description": "Read the last N lines of ambient.jsonl (read-only peripheral vision).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "lines": { "type": "integer", "description": "Lines to return (default 30, max 500)" }
                    }
                }
            }
        ]
    })
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "gap_preflight" => handle_gap_preflight(params).await,
        "gap_claim_lease" => handle_gap_claim_lease(params).await,
        "lease_list_active" => handle_lease_list_active(params).await,
        "musher_pick" => handle_musher_pick(params).await,
        "ambient_tail" => handle_ambient_tail(params).await,
        "tools/list" => Ok(tools_list_json()),
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
    async fn tools_list_has_five_tools() {
        let result = handle_method("tools/list", &json!({})).await.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 5);
    }

    #[tokio::test]
    async fn gap_preflight_requires_ids() {
        let r = handle_method("gap_preflight", &json!({})).await;
        assert!(r.is_err());
    }

    #[tokio::test]
    async fn rejects_dotenv_substring_in_claim_paths() {
        let r = handle_gap_claim_lease(&json!({
            "gap_id": "INFRA-033",
            "paths": "src/lib.rs,.env"
        }))
        .await;
        assert!(r.is_err());
    }
}
