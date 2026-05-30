//! JSON-RPC dispatch loop for chump-mcp-fleet.
//!
//! Handles both the stdio transport (default, for Claude Code mcpServers launch)
//! and Unix socket transport (for daemonised callers).
//!
//! The MCP wire protocol is newline-delimited JSON-RPC 2.0. Each request line
//! produces exactly one response line on stdout (stdio) or the accepted socket
//! connection (Unix socket).

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tracing::{debug, info, warn};

use crate::tools;

// ── JSON-RPC types ────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
    pub id: Value,
}

#[derive(Serialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub result: Option<Value>,
    pub error: Option<JsonRpcError>,
    pub id: Value,
}

#[derive(Serialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
}

// ── method dispatch ───────────────────────────────────────────────────────────

pub async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        // MCP protocol methods
        "initialize" => Ok(json!({
            "protocolVersion": "2024-11-05",
            "serverInfo": {
                "name": "chump-mcp-fleet",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {
                "tools": {}
            }
        })),
        "tools/list" | "initialized" => Ok(tools::tools_list_json()),
        "tools/call" => {
            let tool_name = params
                .get("name")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("tools/call missing 'name'"))?;
            let tool_params = params.get("arguments").cloned().unwrap_or(Value::Null);
            dispatch_tool(tool_name, &tool_params).await
        }

        // Direct tool methods (legacy / convenience path)
        "mcp__chump_fleet__inbox_drain" => tools::handle_inbox_drain(params).await,
        "mcp__chump_fleet__broadcast" => tools::handle_broadcast(params).await,
        "mcp__chump_fleet__vote" => tools::handle_vote(params).await,
        "mcp__chump_fleet__consensus_status" => tools::handle_consensus_status(params).await,
        "mcp__chump_fleet__capabilities" => tools::handle_capabilities(params).await,

        _ => Err(anyhow::anyhow!("unknown method: {}", method)),
    }
}

async fn dispatch_tool(name: &str, params: &Value) -> Result<Value> {
    match name {
        "mcp__chump_fleet__inbox_drain" => tools::handle_inbox_drain(params).await,
        "mcp__chump_fleet__broadcast" => tools::handle_broadcast(params).await,
        "mcp__chump_fleet__vote" => tools::handle_vote(params).await,
        "mcp__chump_fleet__consensus_status" => tools::handle_consensus_status(params).await,
        "mcp__chump_fleet__capabilities" => tools::handle_capabilities(params).await,
        _ => Err(anyhow::anyhow!("unknown tool: {}", name)),
    }
}

fn make_response(id: Value, result: Result<Value>) -> JsonRpcResponse {
    match result {
        Ok(r) => JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            result: Some(r),
            error: None,
            id,
        },
        Err(e) => JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            result: None,
            error: Some(JsonRpcError {
                code: -32603,
                message: e.to_string(),
            }),
            id,
        },
    }
}

// ── stdio transport ───────────────────────────────────────────────────────────

/// Run the JSON-RPC dispatch loop over stdin/stdout (Claude Code mcpServers mode).
pub async fn run_stdio() -> Result<()> {
    info!(transport = "stdio", "chump-mcp-fleet started");
    let stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        debug!(transport = "stdio", bytes = line.len(), "request received");
        let resp = parse_and_dispatch(&line).await;
        let has_err = resp.error.is_some();
        let encoded = serde_json::to_string(&resp).unwrap_or_else(|_| {
            r#"{"jsonrpc":"2.0","error":{"code":-32700,"message":"serialisation error"},"id":null}"#
                .to_string()
        });
        if has_err {
            warn!(transport = "stdio", "tool call returned error");
        }
        stdout
            .write_all(format!("{}\n", encoded).as_bytes())
            .await
            .ok();
        stdout.flush().await.ok();
    }
    info!(transport = "stdio", "chump-mcp-fleet stdin closed, exiting");
    Ok(())
}

// ── Unix socket transport ─────────────────────────────────────────────────────

/// Run the JSON-RPC dispatch loop over a Unix domain socket.
///
/// Accepts one connection at a time; each accepted connection runs until EOF.
/// The socket path is taken from `CHUMP_FLEET_SOCK` env or defaults to
/// `/tmp/chump-mcp-fleet.sock`.
pub async fn run_unix_socket() -> Result<()> {
    use tokio::net::UnixListener;

    let sock_path = std::env::var("CHUMP_FLEET_SOCK")
        .unwrap_or_else(|_| "/tmp/chump-mcp-fleet.sock".to_string());

    // Remove stale socket file so bind succeeds after an unclean shutdown.
    let _ = std::fs::remove_file(&sock_path);

    let listener = UnixListener::bind(&sock_path)
        .map_err(|e| anyhow::anyhow!("bind Unix socket {}: {}", sock_path, e))?;

    info!(transport = "unix_socket", path = %sock_path, "chump-mcp-fleet listening");

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                info!(transport = "unix_socket", "accepted connection");
                tokio::spawn(async move {
                    if let Err(e) = handle_unix_conn(stream).await {
                        warn!(transport = "unix_socket", error = %e, "socket conn error");
                    }
                });
            }
            Err(e) => {
                warn!(transport = "unix_socket", error = %e, "accept error");
                // Brief back-off to avoid tight loop on persistent accept errors.
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
}

async fn handle_unix_conn(stream: tokio::net::UnixStream) -> Result<()> {
    let (read_half, mut write_half) = tokio::io::split(stream);
    let reader = BufReader::new(read_half);
    let mut lines = reader.lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }
        debug!(
            transport = "unix_socket",
            bytes = line.len(),
            "request received"
        );
        let resp = parse_and_dispatch(&line).await;
        let encoded = serde_json::to_string(&resp).unwrap_or_else(|_| {
            r#"{"jsonrpc":"2.0","error":{"code":-32700,"message":"serialisation error"},"id":null}"#
                .to_string()
        });
        write_half
            .write_all(format!("{}\n", encoded).as_bytes())
            .await
            .ok();
        write_half.flush().await.ok();
    }
    Ok(())
}

// ── shared parse + dispatch ───────────────────────────────────────────────────

async fn parse_and_dispatch(line: &str) -> JsonRpcResponse {
    let req: JsonRpcRequest = match serde_json::from_str(line) {
        Ok(r) => r,
        Err(e) => {
            return JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32700,
                    message: format!("Parse error: {}", e),
                }),
                id: Value::Null,
            };
        }
    };

    if req.jsonrpc != "2.0" {
        return JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            result: None,
            error: Some(JsonRpcError {
                code: -32600,
                message: "Invalid Request: jsonrpc must be \"2.0\"".to_string(),
            }),
            id: req.id,
        };
    }

    let result = handle_method(&req.method, &req.params).await;
    make_response(req.id, result)
}
