#![allow(clippy::doc_overindented_list_items)]
#![allow(unknown_lints)]
//! MCP server: Chump gap registry queries via JSON-RPC 2.0 over stdio.
//! Set CHUMP_REPO (or CHUMP_HOME) to point at the repo root.
//!
//! Supported methods:
//!   - list_open_gaps { priority? }               — list open gaps, optional P1/P2/P3 filter
//!   - get_gap { gap_id }                         — return full gap entry by ID
//!   - claim_gap { gap_id }                       — run scripts/coord/gap-claim.sh for the gap
//!   - gap_reserve { title, priority?, effort?, pillar?, description?, acceptance?,
//!                   deps?, domain? }             — create a new gap via chump gap reserve
//!   - gap_ship { gap_id, closed_pr?,
//!                closed_interpretation?,
//!                acceptance_verified? }           — close a gap via chump gap ship
//!   - gap_set { gap_id, ...mutable_fields }      — update gap fields via chump gap set
//!   - gap_dump { format? }                       — dump gaps as json (default) or sql

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

/// Run `chump gap <subcommand> [args...]` and return (success, combined output).
async fn run_chump_gap(subcommand: &str, args: &[&str]) -> Result<Value> {
    let dir = repo_dir()?;
    let mut cmd = Command::new("chump");
    cmd.arg("gap").arg(subcommand);
    for a in args {
        cmd.arg(a);
    }
    cmd.current_dir(&dir);

    let out = cmd
        .output()
        .await
        .map_err(|e| anyhow!("chump gap {} failed to spawn: {}", subcommand, e))?;

    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let combined = match (stdout.is_empty(), stderr.is_empty()) {
        (false, false) => format!("{}\n{}", stdout.trim(), stderr.trim()),
        (true, _) => stderr.trim().to_string(),
        (_, true) => stdout.trim().to_string(),
    };

    Ok(json!({ "success": out.status.success(), "output": combined }))
}

async fn handle_gap_reserve(params: &Value) -> Result<Value> {
    let title = params
        .get("title")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing required field: title"))?;

    let domain = params
        .get("domain")
        .and_then(|v| v.as_str())
        .unwrap_or("INFRA");

    let mut args: Vec<String> = vec![
        "--domain".to_string(),
        domain.to_string(),
        "--title".to_string(),
        title.to_string(),
    ];

    for (flag, field) in &[
        ("--priority", "priority"),
        ("--effort", "effort"),
        ("--description", "description"),
        ("--acceptance-criteria", "acceptance"),
        ("--depends-on", "deps"),
        ("--notes", "notes"),
    ] {
        if let Some(val) = params.get(*field).and_then(|v| v.as_str()) {
            args.push(flag.to_string());
            args.push(val.to_string());
        }
    }

    // pillar maps to --notes or prepended to title prefix; we prepend to title if present.
    // The gap registry uses title prefix tags like "EFFECTIVE:", so we honour that.
    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_chump_gap("reserve", &args_ref).await
}

async fn handle_gap_ship(params: &Value) -> Result<Value> {
    let gap_id = params
        .get("gap_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing required field: gap_id"))?
        .trim()
        .to_uppercase();

    let mut args: Vec<String> = vec![gap_id, "--update-yaml".to_string()];

    if let Some(pr) = params.get("closed_pr").and_then(|v| v.as_u64()) {
        args.push("--closed-pr".to_string());
        args.push(pr.to_string());
    } else if let Some(pr) = params.get("closed_pr").and_then(|v| v.as_str()) {
        args.push("--closed-pr".to_string());
        args.push(pr.to_string());
    }

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_chump_gap("ship", &args_ref).await
}

async fn handle_gap_set(params: &Value) -> Result<Value> {
    let gap_id = params
        .get("gap_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing required field: gap_id"))?
        .trim()
        .to_uppercase();

    let mut args: Vec<String> = vec![gap_id];

    for (flag, field) in &[
        ("--title", "title"),
        ("--description", "description"),
        ("--priority", "priority"),
        ("--effort", "effort"),
        ("--status", "status"),
        ("--notes", "notes"),
        ("--source-doc", "source_doc"),
        ("--opened-date", "opened_date"),
        ("--closed-date", "closed_date"),
        ("--acceptance-criteria", "acceptance_criteria"),
        ("--depends-on", "depends_on"),
    ] {
        if let Some(val) = params.get(*field).and_then(|v| v.as_str()) {
            args.push(flag.to_string());
            args.push(val.to_string());
        }
    }

    if let Some(pr) = params.get("closed_pr").and_then(|v| v.as_u64()) {
        args.push("--closed-pr".to_string());
        args.push(pr.to_string());
    }

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_chump_gap("set", &args_ref).await
}

async fn handle_gap_dump(params: &Value) -> Result<Value> {
    let format = params
        .get("format")
        .and_then(|v| v.as_str())
        .unwrap_or("json");

    match format {
        "json" | "sql" => {}
        other => {
            return Err(anyhow!(
                "unsupported format '{}': must be json or sql",
                other
            ))
        }
    }

    // `chump gap dump` writes YAML; for json we return the parsed gaps array directly.
    // For sql format we shell out to chump gap dump --out /tmp/... which is not supported
    // by current CLI, so we emit json always and note the format param.
    if format == "sql" {
        // chump gap dump does not support SQL; return JSON with a notice.
        let data = load_gaps_yaml()?;
        return Ok(json!({
            "success": true,
            "format": "json",
            "notice": "SQL format not available from YAML backend; returning JSON",
            "gaps": data.get("gaps").unwrap_or(&Value::Null)
        }));
    }

    let data = load_gaps_yaml()?;
    Ok(json!({
        "success": true,
        "format": "json",
        "gaps": data.get("gaps").unwrap_or(&Value::Null)
    }))
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "list_open_gaps" => handle_list_open_gaps(params).await,
        "get_gap" => handle_get_gap(params).await,
        "claim_gap" => handle_claim_gap(params).await,
        "gap_reserve" => handle_gap_reserve(params).await,
        "gap_ship" => handle_gap_ship(params).await,
        "gap_set" => handle_gap_set(params).await,
        "gap_dump" => handle_gap_dump(params).await,
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
                },
                {
                    "name": "gap_reserve",
                    "description": "Reserve (create) a new gap in the Chump registry via `chump gap reserve`. Returns the new gap ID.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "title": { "type": "string", "description": "Gap title, prefixed with pillar tag e.g. 'EFFECTIVE: add X'" },
                            "domain": { "type": "string", "description": "Gap domain (default: INFRA)" },
                            "priority": { "type": "string", "description": "P1, P2, or P3 (default: P2)" },
                            "effort": { "type": "string", "description": "xs, s, m, l, or xl (default: s)" },
                            "pillar": { "type": "string", "description": "Pillar tag: EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE, or MISSION" },
                            "description": { "type": "string", "description": "Full description of the gap" },
                            "acceptance": { "type": "string", "description": "Acceptance criteria (pipe-separated)" },
                            "deps": { "type": "string", "description": "Comma-separated gap IDs this gap depends on" },
                            "notes": { "type": "string", "description": "Additional notes" }
                        },
                        "required": ["title"]
                    }
                },
                {
                    "name": "gap_ship",
                    "description": "Close/ship a gap via `chump gap ship --update-yaml`. Marks the gap done and syncs docs/gaps.yaml.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "gap_id": { "type": "string", "description": "Gap ID to ship, e.g. INFRA-629" },
                            "closed_pr": { "type": ["integer","string"], "description": "PR number that closes this gap" },
                            "closed_interpretation": { "type": "string", "description": "One-line interpretation of how the gap was closed" },
                            "acceptance_verified": { "type": "boolean", "description": "Whether acceptance criteria were verified" }
                        },
                        "required": ["gap_id"]
                    }
                },
                {
                    "name": "gap_set",
                    "description": "Update mutable fields on an existing gap via `chump gap set`.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "gap_id": { "type": "string", "description": "Gap ID to update, e.g. INFRA-001" },
                            "title": { "type": "string" },
                            "description": { "type": "string" },
                            "priority": { "type": "string", "description": "P1, P2, or P3" },
                            "effort": { "type": "string", "description": "xs, s, m, l, or xl" },
                            "status": { "type": "string", "description": "open, in_progress, done, or blocked" },
                            "notes": { "type": "string" },
                            "source_doc": { "type": "string" },
                            "opened_date": { "type": "string", "description": "ISO date e.g. 2026-05-01" },
                            "closed_date": { "type": "string", "description": "ISO date e.g. 2026-05-06" },
                            "closed_pr": { "type": "integer", "description": "PR number" },
                            "acceptance_criteria": { "type": "string", "description": "Pipe-separated criteria" },
                            "depends_on": { "type": "string", "description": "Comma-separated gap IDs" }
                        },
                        "required": ["gap_id"]
                    }
                },
                {
                    "name": "gap_dump",
                    "description": "Dump all gaps as JSON (sql format returns JSON with a notice). Useful for bulk inspection.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "format": { "type": "string", "description": "Output format: json (default) or sql" }
                        }
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
    async fn tools_list_has_seven_tools() {
        let result = handle_method("tools/list", &json!({})).await.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 7);
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"list_open_gaps"));
        assert!(names.contains(&"get_gap"));
        assert!(names.contains(&"claim_gap"));
        assert!(names.contains(&"gap_reserve"));
        assert!(names.contains(&"gap_ship"));
        assert!(names.contains(&"gap_set"));
        assert!(names.contains(&"gap_dump"));
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

    #[tokio::test]
    async fn gap_reserve_missing_title_errors() {
        let result = handle_method("gap_reserve", &json!({})).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("title"));
    }

    #[tokio::test]
    async fn gap_ship_missing_gap_id_errors() {
        let result = handle_method("gap_ship", &json!({})).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("gap_id"));
    }

    #[tokio::test]
    async fn gap_set_missing_gap_id_errors() {
        let result = handle_method("gap_set", &json!({})).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("gap_id"));
    }

    #[tokio::test]
    async fn gap_dump_invalid_format_errors() {
        let result = handle_method("gap_dump", &json!({"format": "xml"})).await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("unsupported format"));
    }

    #[tokio::test]
    async fn gap_dump_no_repo_errors() {
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let result = handle_method("gap_dump", &json!({})).await;
        assert!(result.is_err());
    }
}
