//! MCP server: Chump eval harness runner via JSON-RPC 2.0 over stdio.
//! Set CHUMP_REPO (or CHUMP_HOME) to point at the repo root.
//!
//! Supported methods:
//!   - list_fixtures {}                          — list fixture files in scripts/ab-harness/fixtures/
//!   - run_ab_sweep { fixture_path, model, n_per_cell? }  — run scripts/ab-harness/run-cloud-v2.py
//!   - get_sweep_results { tag }                — read logs/ab-harness/<tag>/summary.json
//!   - run_ab_sweep_with_summary { fixture_path, model, n_per_cell? }
//!                                              — run sweep, then call sampling/createMessage
//!                                                to ask the calling agent for a 2-sentence summary
//!                                                (MCP 2025-11-05 Sampling pattern)
//!   - run_destructive_sweep { fixture_path, model, output_dir }
//!                                              — confirm via elicitation/create before overwriting
//!                                                results (MCP 2025-11-05 Elicitation pattern)

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

async fn run_ab_sweep_inner(
    fixture_path: &str,
    model: &str,
    n_per_cell: u32,
) -> Result<(bool, String)> {
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
        .arg(fixture_path)
        .arg("--model")
        .arg(model)
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

    Ok((out.status.success(), trimmed))
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

    let (success, output) = run_ab_sweep_inner(&fixture_path, &model, n_per_cell).await?;
    Ok(json!({ "success": success, "output": output }))
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

// ---------------------------------------------------------------------------
// MCP Sampling pattern — run_ab_sweep_with_summary
// ---------------------------------------------------------------------------
//
// TODO(COG-022): MCP Sampling protocol (spec version 2025-11-05)
//
// Sampling lets an MCP *server* ask the *calling agent* (the LLM client) to
// perform a reasoning step and return the result.  The flow is:
//
//   1. Server runs some work (here: the A/B sweep).
//   2. Server sends a "sampling/createMessage" request *upstream* to the
//      connected MCP client (the agent host).
//   3. The client passes the prompt to its LLM, waits for a completion, and
//      returns the result in a sampling response.
//   4. The server receives the response and incorporates it into its reply.
//
// Wire format (MCP JSON-RPC, server → client):
//   {"jsonrpc":"2.0","id":"<id>","method":"sampling/createMessage","params":{
//     "messages":[{"role":"user","content":{"type":"text","text":"<prompt>"}}],
//     "maxTokens":256
//   }}
//
// Response (client → server):
//   {"jsonrpc":"2.0","id":"<id>","result":{
//     "role":"assistant","content":{"type":"text","text":"<summary>"}
//   }}
//
// Because this server communicates over *stdio* in a single-threaded
// request/response loop, sending an upstream request mid-handler requires
// muxing the stdin/stdout channel (see the MCP SDK for a full implementation).
// This stub logs the sampling request and returns a placeholder, documenting
// the pattern without requiring a full duplex transport.
//
async fn handle_run_ab_sweep_with_summary(params: &Value) -> Result<Value> {
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

    let (success, sweep_output) = run_ab_sweep_inner(&fixture_path, &model, n_per_cell).await?;

    // Build the sampling/createMessage request that would be sent upstream to
    // the calling agent if this server had a full duplex MCP transport.
    let sampling_prompt = format!(
        "The following is the output of an A/B eval sweep for fixture '{}' \
         on model '{}'.  Please write exactly 2 sentences summarising the key \
         finding and any significant win/loss delta.\n\nSweep output:\n{}",
        fixture_path, model, sweep_output
    );

    let sampling_request = json!({
        "jsonrpc": "2.0",
        "id": "sampling-1",
        "method": "sampling/createMessage",
        "params": {
            "messages": [
                {
                    "role": "user",
                    "content": { "type": "text", "text": sampling_prompt }
                }
            ],
            "maxTokens": 256
        }
    });

    // SAMPLING REQUEST — would be sent upstream over the MCP transport channel.
    // In a full MCP SDK implementation the server would write this to the
    // client transport and await the sampling response before continuing.
    eprintln!(
        "SAMPLING REQUEST: {}",
        serde_json::to_string(&sampling_request).unwrap_or_default()
    );

    // Stub response: in a live implementation this would be replaced by the
    // agent's actual reply received via the sampling response message.
    let stub_summary = "[sampling stub] Agent summary not available — \
        full duplex MCP transport required for live sampling. \
        See TODO(COG-022) comment in source for wire format.";

    Ok(json!({
        "success": success,
        "sweep_output": sweep_output,
        "sampling_request_sent": sampling_request,
        "agent_summary": stub_summary
    }))
}

// ---------------------------------------------------------------------------
// MCP Elicitation pattern — run_destructive_sweep
// ---------------------------------------------------------------------------
//
// TODO(COG-022): MCP Elicitation protocol (spec version 2025-11-05)
//
// Elicitation lets an MCP *server* pause mid-execution and ask the *user*
// (not the LLM — the human in the loop) for a structured confirmation or
// data input before continuing a potentially dangerous operation.  The flow:
//
//   1. Server reaches a decision point that requires human sign-off.
//   2. Server sends an "elicitation/create" request upstream to the MCP client.
//   3. The client surfaces a UI prompt to the user and waits for their input.
//   4. The client returns the user's response; the server decides whether to
//      proceed, abort, or retry.
//
// Wire format (MCP JSON-RPC, server → client):
//   {"jsonrpc":"2.0","id":"<id>","method":"elicitation/create","params":{
//     "message": "<human-readable description of what will happen>",
//     "requestedSchema": {
//       "type": "object",
//       "properties": {
//         "confirmed": { "type": "boolean", "title": "Proceed?",
//                        "description": "Check to overwrite existing results." }
//       },
//       "required": ["confirmed"]
//     }
//   }}
//
// Response (client → server):
//   {"jsonrpc":"2.0","id":"<id>","result":{
//     "action": "accept",          // "accept" | "decline" | "cancel"
//     "content": { "confirmed": true }
//   }}
//
// If action is "decline" or "cancel", the server should abort without
// performing the destructive operation.
//
// Same duplex-transport caveat as Sampling above — this stub logs the request.
//
async fn handle_run_destructive_sweep(params: &Value) -> Result<Value> {
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
    let output_dir = params
        .get("output_dir")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("missing output_dir"))?
        .trim()
        .to_string();

    if fixture_path.is_empty() {
        return Err(anyhow!("fixture_path is empty"));
    }
    if model.is_empty() {
        return Err(anyhow!("model is empty"));
    }
    if output_dir.is_empty() {
        return Err(anyhow!("output_dir is empty"));
    }
    // Guard against path traversal in output_dir
    if output_dir.contains("..") {
        return Err(anyhow!("output_dir must not contain '..'"));
    }

    // Build the elicitation/create request that would be sent upstream to the
    // calling MCP client (which surfaces it to the human user).
    let elicitation_request = json!({
        "jsonrpc": "2.0",
        "id": "elicitation-1",
        "method": "elicitation/create",
        "params": {
            "message": format!(
                "This sweep will OVERWRITE all existing results in '{}'.  \
                 Fixture: {}  Model: {}  \
                 This cannot be undone.  Do you want to proceed?",
                output_dir, fixture_path, model
            ),
            "requestedSchema": {
                "type": "object",
                "properties": {
                    "confirmed": {
                        "type": "boolean",
                        "title": "Overwrite existing results?",
                        "description": "Check to confirm overwriting all results in the output directory."
                    }
                },
                "required": ["confirmed"]
            }
        }
    });

    // ELICITATION REQUEST — would be sent upstream over the MCP transport.
    // In a full MCP SDK implementation the server would write this to the
    // client transport, await the elicitation response, and proceed only if
    // action == "accept" && content.confirmed == true.
    eprintln!(
        "ELICITATION REQUEST: {}",
        serde_json::to_string(&elicitation_request).unwrap_or_default()
    );

    // Stub: treat as declined (safe default — never actually delete data in
    // a stub implementation).
    Ok(json!({
        "success": false,
        "elicitation_request_sent": elicitation_request,
        "elicitation_response": {
            "action": "decline",
            "reason": "[elicitation stub] Full duplex MCP transport required for live elicitation. \
                See TODO(COG-022) comment in source for wire format."
        },
        "sweep_executed": false
    }))
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "list_fixtures" => handle_list_fixtures(params).await,
        "run_ab_sweep" => handle_run_ab_sweep(params).await,
        "get_sweep_results" => handle_get_sweep_results(params).await,
        "run_ab_sweep_with_summary" => handle_run_ab_sweep_with_summary(params).await,
        "run_destructive_sweep" => handle_run_destructive_sweep(params).await,
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
                },
                {
                    "name": "run_ab_sweep_with_summary",
                    "description": "Run an A/B eval sweep then issue a sampling/createMessage request to the calling agent asking it to produce a 2-sentence summary of the results (MCP 2025-11-05 Sampling pattern). In the stub implementation the sampling request is logged to stderr and a placeholder summary is returned.",
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
                    "name": "run_destructive_sweep",
                    "description": "Run an A/B eval sweep that would overwrite an existing output directory. Issues an elicitation/create request to ask the user for explicit confirmation before proceeding (MCP 2025-11-05 Elicitation pattern). In the stub implementation the elicitation request is logged to stderr and the sweep is not executed.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "fixture_path": { "type": "string", "description": "Path to fixture JSON (relative to repo root or absolute)" },
                            "model": { "type": "string", "description": "Model identifier to evaluate against" },
                            "output_dir": { "type": "string", "description": "Output directory that would be overwritten (relative to logs/ab-harness/)" }
                        },
                        "required": ["fixture_path", "model", "output_dir"]
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
    async fn tools_list_has_five_tools() {
        let result = handle_method("tools/list", &json!({})).await.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 5);
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"list_fixtures"));
        assert!(names.contains(&"run_ab_sweep"));
        assert!(names.contains(&"get_sweep_results"));
        assert!(names.contains(&"run_ab_sweep_with_summary"));
        assert!(names.contains(&"run_destructive_sweep"));
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
    async fn run_ab_sweep_with_summary_missing_params_errors() {
        let result = handle_method("run_ab_sweep_with_summary", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn run_destructive_sweep_missing_params_errors() {
        let result = handle_method("run_destructive_sweep", &json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn run_destructive_sweep_path_traversal_blocked() {
        std::env::set_var("CHUMP_REPO", "/tmp");
        let result = handle_method(
            "run_destructive_sweep",
            &json!({
                "fixture_path": "fixtures/test.json",
                "model": "gpt-4",
                "output_dir": "../../../etc"
            }),
        )
        .await;
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("'..'"));
    }

    #[tokio::test]
    async fn run_destructive_sweep_stub_returns_declined() {
        std::env::set_var("CHUMP_REPO", "/tmp");
        let result = handle_method(
            "run_destructive_sweep",
            &json!({
                "fixture_path": "fixtures/test.json",
                "model": "gpt-4",
                "output_dir": "my-run"
            }),
        )
        .await
        .unwrap();
        assert_eq!(result["success"], false);
        assert_eq!(result["sweep_executed"], false);
        assert_eq!(result["elicitation_response"]["action"], "decline");
    }

    #[tokio::test]
    async fn unknown_method_errors() {
        let result = handle_method("does_not_exist", &json!({})).await;
        assert!(result.is_err());
    }
}
