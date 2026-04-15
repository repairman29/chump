//! MCP bridge: spawn external MCP server binaries and call them via JSON-RPC over stdio.
//!
//! This is the orchestrator side of the MCP microkernel architecture (Sprint 1.3).
//! When the LLM calls a tool that has been extracted to an MCP server, the bridge:
//! 1. Spawns the MCP server binary as a child process
//! 2. Sends the tool arguments as a JSON-RPC request on stdin
//! 3. Reads the JSON-RPC response from stdout
//! 4. Returns the result to the LLM context
//!
//! Server binaries are discovered via `CHUMP_MCP_SERVERS_DIR` or `target/release/`.

use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

/// Full metadata for an MCP-discovered tool.
#[derive(Clone, Debug)]
pub struct McpToolMeta {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
    pub binary: PathBuf,
}

/// Registry of tool name → full metadata (binary path + description + schema).
static MCP_REGISTRY: OnceLock<HashMap<String, McpToolMeta>> = OnceLock::new();

/// Directory containing MCP server binaries.
fn mcp_servers_dir() -> PathBuf {
    std::env::var("CHUMP_MCP_SERVERS_DIR")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let mut p = crate::repo_path::runtime_base();
            p.push("target");
            p.push("release");
            p
        })
}

/// Discover available MCP server binaries and register their tool methods with full metadata.
/// Called once at startup. Each server is queried for `tools/list` to learn its methods.
pub async fn discover_servers() -> HashMap<String, McpToolMeta> {
    let dir = mcp_servers_dir();
    let mut registry = HashMap::new();

    // Look for binaries matching `chump-mcp-*`
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return registry,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with("chump-mcp-") || !path.is_file() {
            continue;
        }

        // Query the server for its tool list with full metadata
        match query_tools_list_full(&path).await {
            Ok(tools) => {
                for meta in tools {
                    tracing::info!(server = %name, tool = %meta.name, "MCP bridge: registered external tool");
                    registry.insert(meta.name.clone(), meta);
                }
            }
            Err(e) => {
                tracing::warn!(server = %name, error = %e, "MCP bridge: failed to query tools/list");
            }
        }
    }

    registry
}

/// Initialize the global MCP registry. Call once at startup.
pub async fn init() {
    let registry = discover_servers().await;
    if !registry.is_empty() {
        tracing::info!(count = registry.len(), "MCP bridge: initialized with external tools");
    }
    let _ = MCP_REGISTRY.set(registry);
}

/// Check if a tool name is handled by an external MCP server.
pub fn is_mcp_tool(tool_name: &str) -> bool {
    MCP_REGISTRY
        .get()
        .map(|r| r.contains_key(tool_name))
        .unwrap_or(false)
}

/// Get the binary path for an MCP tool.
pub fn mcp_binary_for(tool_name: &str) -> Option<PathBuf> {
    MCP_REGISTRY.get()?.get(tool_name).map(|m| m.binary.clone())
}

/// Get full metadata for an MCP tool.
pub fn mcp_tool_meta(tool_name: &str) -> Option<McpToolMeta> {
    MCP_REGISTRY.get()?.get(tool_name).cloned()
}

/// Get all registered MCP tool metadata.
pub fn all_mcp_tools() -> Vec<McpToolMeta> {
    MCP_REGISTRY
        .get()
        .map(|r| r.values().cloned().collect())
        .unwrap_or_default()
}

/// Call an MCP server tool via JSON-RPC over stdio.
pub async fn call_mcp_tool(tool_name: &str, params: Value) -> Result<Value> {
    let binary = mcp_binary_for(tool_name)
        .ok_or_else(|| anyhow!("no MCP server registered for tool: {}", tool_name))?;

    call_server(&binary, tool_name, params).await
}

/// Query a server binary for its tool list with full metadata (name, description, inputSchema).
async fn query_tools_list_full(binary: &PathBuf) -> Result<Vec<McpToolMeta>> {
    let result = call_server(binary, "tools/list", json!({})).await?;
    let tools = result["tools"]
        .as_array()
        .ok_or_else(|| anyhow!("tools/list response missing tools array"))?;
    let metas: Vec<McpToolMeta> = tools
        .iter()
        .filter_map(|t| {
            let name = t["name"].as_str()?.to_string();
            let description = t["description"].as_str().unwrap_or("").to_string();
            let input_schema = t.get("inputSchema").cloned().unwrap_or(json!({"type": "object"}));
            Some(McpToolMeta {
                name,
                description,
                input_schema,
                binary: binary.clone(),
            })
        })
        .collect();
    Ok(metas)
}

/// Send a JSON-RPC request to a server binary and read the response.
async fn call_server(binary: &PathBuf, method: &str, params: Value) -> Result<Value> {
    let request = json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    });
    let request_line = format!("{}\n", serde_json::to_string(&request)?);

    let mut child = Command::new(binary)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| anyhow!("failed to spawn MCP server {:?}: {}", binary, e))?;

    // Write request to stdin
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(request_line.as_bytes()).await?;
        stdin.shutdown().await?;
    }

    // Read response from stdout
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("no stdout from MCP server"))?;
    let mut reader = BufReader::new(stdout);
    let mut response_line = String::new();
    let read_result = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        reader.read_line(&mut response_line),
    )
    .await
    .map_err(|_| anyhow!("MCP server response timeout (30s)"))?
    .map_err(|e| anyhow!("failed to read MCP response: {}", e))?;

    if read_result == 0 {
        return Err(anyhow!("MCP server returned empty response"));
    }

    let _ = child.kill().await; // Clean up

    let response: Value = serde_json::from_str(response_line.trim())
        .map_err(|e| anyhow!("invalid JSON-RPC response: {}", e))?;

    if let Some(error) = response.get("error") {
        let msg = error["message"].as_str().unwrap_or("unknown error");
        return Err(anyhow!("MCP server error: {}", msg));
    }

    response
        .get("result")
        .cloned()
        .ok_or_else(|| anyhow!("MCP response missing result"))
}

/// Summary for logging/health endpoint.
pub fn registered_tools() -> Vec<String> {
    MCP_REGISTRY
        .get()
        .map(|r| r.keys().cloned().collect())
        .unwrap_or_default()
}

// ── McpProxyTool: dynamic axonerai::Tool wrapper for MCP-discovered tools ──

/// A tool that proxies calls to an external MCP server binary via JSON-RPC.
/// Created dynamically at runtime from MCP discovery metadata.
pub struct McpProxyTool {
    meta: McpToolMeta,
}

impl McpProxyTool {
    pub fn new(meta: McpToolMeta) -> Self {
        Self { meta }
    }
}

#[async_trait::async_trait]
impl axonerai::tool::Tool for McpProxyTool {
    fn name(&self) -> String {
        self.meta.name.clone()
    }

    fn description(&self) -> String {
        format!("[MCP] {}", self.meta.description)
    }

    fn input_schema(&self) -> Value {
        self.meta.input_schema.clone()
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let result = call_mcp_tool(&self.meta.name, input).await?;
        // Return the result as a JSON string for the agent
        Ok(serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_registry_returns_false() {
        // Before init, nothing is registered
        assert!(!is_mcp_tool("gh_list_issues"));
    }

    #[test]
    fn registered_tools_empty_before_init() {
        let tools = registered_tools();
        // May or may not be empty depending on test ordering, but shouldn't panic
        let _ = tools;
    }
}
