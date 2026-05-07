//! MCP server: Chump gap registry queries via JSON-RPC 2.0 over stdio.
//! Set CHUMP_REPO (or CHUMP_HOME) to point at the repo root.
//!
//! Supported methods:
//!   - list_open_gaps { priority? }   — list open gaps, optional P0/P1/P2 filter
//!   - get_gap { gap_id }             — return full gap entry by ID (prefix match)
//!   - claim_gap { gap_id }           — run scripts/coord/gap-claim.sh for the gap

use anyhow::{anyhow, Result};
use rusqlite::{params, Connection, OpenFlags};
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

fn state_db_path() -> Result<PathBuf> {
    Ok(repo_dir()?.join(".chump").join("state.db"))
}

fn open_db() -> Result<Connection> {
    let path = state_db_path()?;
    Connection::open_with_flags(
        &path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| anyhow!("failed to open {}: {}", path.display(), e))
}

fn row_to_json(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id":                  row.get::<_, String>(0)?,
        "domain":              row.get::<_, String>(1)?,
        "title":               row.get::<_, String>(2)?,
        "description":         row.get::<_, String>(3)?,
        "priority":            row.get::<_, String>(4)?,
        "effort":              row.get::<_, String>(5)?,
        "status":              row.get::<_, String>(6)?,
        "acceptance_criteria": row.get::<_, String>(7)?,
        "depends_on":          row.get::<_, String>(8)?,
        "notes":               row.get::<_, String>(9)?,
        "source_doc":          row.get::<_, String>(10)?,
        "opened_date":         row.get::<_, String>(11)?,
        "closed_pr":           row.get::<_, Option<i64>>(12)?,
    }))
}

async fn handle_list_open_gaps(params: &Value) -> Result<Value> {
    let priority_filter = params
        .get("priority")
        .and_then(|v| v.as_str())
        .map(|s| s.to_uppercase());
    let conn = open_db()?;

    let gaps: Vec<Value> = {
        const SQL_ALL: &str = "SELECT id, domain, title, description, priority, effort, status,
                    acceptance_criteria, depends_on, notes, source_doc,
                    opened_date, closed_pr
             FROM gaps WHERE status = 'open' ORDER BY id";
        const SQL_PRI: &str = "SELECT id, domain, title, description, priority, effort, status,
                    acceptance_criteria, depends_on, notes, source_doc,
                    opened_date, closed_pr
             FROM gaps WHERE status = 'open' AND upper(priority) = ?1 ORDER BY id";

        let mut stmt_all;
        let mut stmt_pri;
        let rows: Box<dyn Iterator<Item = rusqlite::Result<Value>>> =
            if let Some(ref pf) = priority_filter {
                stmt_pri = conn.prepare(SQL_PRI)?;
                Box::new(stmt_pri.query_map(params![pf], |row| row_to_json(row))?)
            } else {
                stmt_all = conn.prepare(SQL_ALL)?;
                Box::new(stmt_all.query_map([], |row| row_to_json(row))?)
            };
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| anyhow!("query failed: {}", e))?
    };

    let summary: Vec<Value> = gaps
        .iter()
        .map(|g| {
            json!({
                "id":       g["id"],
                "title":    g["title"],
                "domain":   g["domain"],
                "priority": g["priority"],
                "effort":   g["effort"],
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

    let conn = open_db()?;

    // Try exact match first, then prefix match (e.g. "INFRA-628" or "628")
    let mut stmt = conn.prepare(
        "SELECT id, domain, title, description, priority, effort, status,
                acceptance_criteria, depends_on, notes, source_doc,
                opened_date, closed_pr
         FROM gaps
         WHERE upper(id) = ?1 OR upper(id) LIKE ?2
         ORDER BY id
         LIMIT 1",
    )?;
    let pattern = format!("%-{}", gap_id);
    let result = stmt.query_row(params![gap_id, pattern], |row| row_to_json(row));

    match result {
        Ok(gap) => Ok(json!({ "success": true, "gap": gap })),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            Ok(json!({ "success": false, "error": format!("gap '{}' not found", gap_id) }))
        }
        Err(e) => Err(anyhow!("query failed: {}", e)),
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
    let script = dir.join("scripts").join("coord").join("gap-claim.sh");
    let script = if script.exists() {
        script
    } else {
        dir.join("scripts").join("gap-claim.sh")
    };
    if !script.exists() {
        return Err(anyhow!("gap-claim.sh not found under scripts/"));
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
                    "description": "List open gaps in the Chump gap registry (.chump/state.db). Optional priority filter (P0, P1, P2).",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "priority": {
                                "type": "string",
                                "description": "Optional priority filter: P0, P1, or P2"
                            }
                        }
                    }
                },
                {
                    "name": "get_gap",
                    "description": "Get full details for a specific gap by ID or short prefix (e.g. INFRA-628, MEM-007, or just 628).",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "gap_id": { "type": "string", "description": "Gap ID or suffix, e.g. INFRA-628 or 628" }
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
                            "gap_id": { "type": "string", "description": "Gap ID to claim, e.g. INFRA-628" }
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
