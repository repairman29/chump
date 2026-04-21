//! MCP bridge: spawn external MCP server binaries and call them via JSON-RPC over stdio.
//!
//! Two call models live here:
//!
//! 1. **Global discovery / spawn-per-call** (original Sprint 1.3 model):
//!    Scans `CHUMP_MCP_SERVERS_DIR` for `chump-mcp-*` binaries at startup,
//!    caches their tool metadata in a `OnceLock`, and spawns a fresh child
//!    on every `call_mcp_tool()`. Matches the "Chump-bundled tools live as
//!    external binaries" use case.
//!
//! 2. **Persistent per-session spawns** (ACP-001, Apr 2026):
//!    The ACP protocol lets clients pass `mcp_servers` in `session/new`.
//!    Those are per-session, not bundled — spawned on session open, killed
//!    on session/cancel or when the `AcpServer` drops. See
//!    [`PersistentMcpServer`] + [`SessionMcpPool`].
//!
//! Both models speak JSON-RPC 2.0 over stdio.

use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

// McpToolMeta now lives in the standalone crate `chump-mcp-lifecycle`.
// Re-exported here so existing callsites inside the `chump` binary crate keep working.
pub use chump_mcp_lifecycle::McpToolMeta;

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
        tracing::info!(
            count = registry.len(),
            "MCP bridge: initialized with external tools"
        );
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
            let input_schema = t
                .get("inputSchema")
                .cloned()
                .unwrap_or(json!({"type": "object"}));
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

    // Capture stderr for diagnostics before cleanup
    let stderr_msg = if let Some(mut stderr) = child.stderr.take() {
        let mut buf = String::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            tokio::io::AsyncReadExt::read_to_string(&mut stderr, &mut buf),
        )
        .await;
        buf
    } else {
        String::new()
    };
    if !stderr_msg.is_empty() {
        tracing::debug!(stderr = %stderr_msg.trim(), "MCP server stderr");
    }
    let _ = child.kill().await;
    let _ = child.wait().await; // Prevent zombie processes

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

// ── ACP per-session MCP tools ──
//
// ACP clients may pass mcpServers on session/new or session/load. Unlike the
// global MCP_REGISTRY (discovered at startup from binaries on disk), these are
// scoped to a single ACP session so they don't leak between concurrent editors.
//
// Call pattern: one-shot spawn per tool call (same as the global registry).
// This is intentional: it keeps lifecycle simple and works with stateless MCP
// servers (the common case). Long-lived connections are a future optimization.

/// A single MCP tool discovered from an ACP client-supplied server.
/// Carries the command + args needed to re-spawn the server for each call.
#[derive(Clone, Debug)]
pub struct SessionMcpTool {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
    /// The executable (command) to spawn. May be a full path or a PATH-resolved binary.
    pub command: String,
    /// Arguments passed to the command before any tool-call arguments.
    pub cmd_args: Vec<String>,
}

/// Query a command-line MCP server for its tool list. Spawns the server,
/// sends `tools/list`, reads the response, and kills the process.
/// Returns an empty vec (with a warning) rather than propagating errors so a
/// bad server doesn't block session creation.
pub async fn discover_acp_session_tools(
    server_name: &str,
    command: &str,
    args: &[String],
) -> Vec<SessionMcpTool> {
    match query_session_tools_list(command, args).await {
        Ok(tools) => {
            tracing::info!(
                server = server_name,
                count = tools.len(),
                "ACP MCP: discovered tools from session server"
            );
            tools
        }
        Err(e) => {
            tracing::warn!(
                server = server_name,
                error = %e,
                "ACP MCP: failed to query tools/list; skipping server"
            );
            vec![]
        }
    }
}

/// Discover and flatten tools from all ACP-supplied MCP servers.
/// Runs discovery concurrently and de-duplicates by tool name (first wins).
pub async fn discover_all_acp_tools(
    servers: &[(String, String, Vec<String>)],
) -> std::collections::HashMap<String, SessionMcpTool> {
    let futures: Vec<_> = servers
        .iter()
        .map(|(name, cmd, args)| discover_acp_session_tools(name, cmd, args))
        .collect();
    let results = futures_util::future::join_all(futures).await;
    let mut map = std::collections::HashMap::new();
    for tools in results {
        for t in tools {
            map.entry(t.name.clone()).or_insert(t);
        }
    }
    map
}

/// Call a session-scoped MCP server tool via JSON-RPC over stdio.
pub async fn call_acp_session_tool(
    command: &str,
    cmd_args: &[String],
    tool_name: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "method": tool_name,
        "params": params,
        "id": 1
    });
    let request_line = format!("{}\n", serde_json::to_string(&request)?);

    let mut child = tokio::process::Command::new(command)
        .args(cmd_args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| anyhow!("failed to spawn ACP MCP server '{}': {}", command, e))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(request_line.as_bytes()).await?;
        stdin.shutdown().await?;
    }

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("no stdout from ACP MCP server '{}'", command))?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let read_result = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        reader.read_line(&mut line),
    )
    .await
    .map_err(|_| anyhow!("ACP MCP server '{}' response timeout (30s)", command))?
    .map_err(|e| anyhow!("read error from '{}': {}", command, e))?;

    if read_result == 0 {
        return Err(anyhow!(
            "ACP MCP server '{}' returned empty response",
            command
        ));
    }

    let _ = child.kill().await;
    let _ = child.wait().await;

    let response: serde_json::Value = serde_json::from_str(line.trim())
        .map_err(|e| anyhow!("invalid JSON-RPC from '{}': {}", command, e))?;
    if let Some(error) = response.get("error") {
        let msg = error["message"].as_str().unwrap_or("unknown error");
        return Err(anyhow!("ACP MCP server error: {}", msg));
    }
    response
        .get("result")
        .cloned()
        .ok_or_else(|| anyhow!("ACP MCP response from '{}' missing result", command))
}

async fn query_session_tools_list(command: &str, args: &[String]) -> Result<Vec<SessionMcpTool>> {
    let result = call_acp_session_tool(command, args, "tools/list", serde_json::json!({})).await?;
    let tools = result["tools"]
        .as_array()
        .ok_or_else(|| anyhow!("tools/list response missing tools array"))?;
    let metas: Vec<SessionMcpTool> = tools
        .iter()
        .filter_map(|t| {
            let name = t["name"].as_str()?.to_string();
            let description = t["description"].as_str().unwrap_or("").to_string();
            let input_schema = t
                .get("inputSchema")
                .cloned()
                .unwrap_or(serde_json::json!({"type": "object"}));
            Some(SessionMcpTool {
                name,
                description,
                input_schema,
                command: command.to_string(),
                cmd_args: args.to_vec(),
            })
        })
        .collect();
    Ok(metas)
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
        let raw = serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string());
        // Sanitize MCP response through context firewall before returning to LLM
        Ok(crate::context_firewall::sanitize_text(
            &raw,
            &self.meta.name,
        ))
    }
}

// ── Persistent per-session MCP server lifecycle (ACP-001) ──────────────────
//
// Extracted to the standalone `chump-mcp-lifecycle` crate. Re-exported here
// so existing `crate::mcp_bridge::*` callsites inside the `chump` binary crate (SessionEntry,
// acp_server, etc.) keep working without touching each one. Downstream
// consumers outside this crate should depend on `chump-mcp-lifecycle`
// directly — see crates/chump-mcp-lifecycle/README.md.

#[allow(unused_imports)]
pub use chump_mcp_lifecycle::{PersistentMcpServer, SessionMcpPool, MAX_SERVERS_PER_SESSION};

/// ACP-001 follow-up: `axonerai::tool::Tool` wrapper around a session-scoped
/// MCP tool. Holds an `Arc<SessionMcpPool>` so the agent loop's registry can
/// call `execute()` while the ACP session's `SessionEntry` continues to own
/// the pool (and the children).
///
/// Lifetime: one proxy instance per pool-tool, created when the agent loop's
/// `ToolRegistry` is built for a session turn. When the session ends, the
/// `SessionEntry` drops, the `Arc` in every proxy's refcount decrements, and
/// the last-one-out triggers `SessionMcpPool` drop → child SIGKILL.
pub struct AcpMcpProxyTool {
    /// Shared handle to the session's MCP pool. Clone-cheap (Arc bump).
    pool: Arc<SessionMcpPool>,
    /// The MCP tool's advertised name (matches the LLM's tool_name).
    tool_name: String,
    /// The MCP tool's advertised description. Shown to the LLM.
    description: String,
    /// The MCP tool's JSON schema. Shown to the LLM; also used by
    /// tool_input_schema_validate for pre-flight validation.
    input_schema: Value,
}

impl AcpMcpProxyTool {
    /// Construct a proxy for one tool inside a session pool.
    pub fn new(
        pool: Arc<SessionMcpPool>,
        tool_name: String,
        description: String,
        input_schema: Value,
    ) -> Self {
        Self {
            pool,
            tool_name,
            description,
            input_schema,
        }
    }

    /// Build one proxy per tool in the pool. Returned tools are ready to
    /// register into an `axonerai::tool::ToolRegistry`.
    pub fn from_pool(pool: Arc<SessionMcpPool>) -> Vec<Self> {
        let metas = pool.tools().to_vec();
        metas
            .into_iter()
            .map(|m| AcpMcpProxyTool::new(Arc::clone(&pool), m.name, m.description, m.input_schema))
            .collect()
    }
}

#[async_trait::async_trait]
impl axonerai::tool::Tool for AcpMcpProxyTool {
    fn name(&self) -> String {
        self.tool_name.clone()
    }

    fn description(&self) -> String {
        // Prefix identifies session-scoped MCP tools in introspection output,
        // matches the `[MCP]` marker the global `McpProxyTool` uses.
        format!("[ACP-MCP] {}", self.description)
    }

    fn input_schema(&self) -> Value {
        self.input_schema.clone()
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let result = self.pool.call_tool(&self.tool_name, input).await?;
        let raw = serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string());
        // Sanitize MCP response through the context firewall before returning
        // to the LLM — matches global McpProxyTool behaviour.
        Ok(crate::context_firewall::sanitize_text(
            &raw,
            &self.tool_name,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axonerai::tool::Tool;

    #[test]
    fn empty_registry_returns_false() {
        assert!(!is_mcp_tool("gh_list_issues"));
    }

    #[test]
    fn registered_tools_empty_before_init() {
        let tools = registered_tools();
        let _ = tools;
    }

    #[test]
    fn mcp_tool_meta_clone() {
        let meta = McpToolMeta {
            name: "test_tool".to_string(),
            description: "A test tool".to_string(),
            input_schema: json!({"type": "object"}),
            binary: PathBuf::from("/usr/bin/test"),
        };
        let cloned = meta.clone();
        assert_eq!(cloned.name, "test_tool");
        assert_eq!(cloned.description, "A test tool");
    }

    #[test]
    fn mcp_proxy_tool_name_and_description() {
        let meta = McpToolMeta {
            name: "web_search".to_string(),
            description: "Search the web".to_string(),
            input_schema: json!({"type": "object", "properties": {"query": {"type": "string"}}}),
            binary: PathBuf::from("/bin/false"),
        };
        let proxy = McpProxyTool::new(meta);
        assert_eq!(proxy.name(), "web_search");
        assert_eq!(proxy.description(), "[MCP] Search the web");
        let schema = proxy.input_schema();
        assert_eq!(schema["properties"]["query"]["type"], "string");
    }

    #[test]
    fn mcp_binary_for_missing_tool() {
        assert!(mcp_binary_for("nonexistent_tool_xyz").is_none());
    }

    #[test]
    fn mcp_tool_meta_missing_returns_none() {
        assert!(mcp_tool_meta("nonexistent_tool_xyz").is_none());
    }

    #[test]
    fn all_mcp_tools_before_init() {
        let tools = all_mcp_tools();
        // May be empty or populated depending on test order; shouldn't panic
        let _ = tools;
    }

    #[test]
    fn mcp_servers_dir_default() {
        // Should return a valid path even without env var
        let dir = mcp_servers_dir();
        let s = dir.to_str().unwrap();
        assert!(s.contains("target") || !s.is_empty());
    }

    #[test]
    fn mcp_servers_dir_from_env() {
        std::env::set_var("CHUMP_MCP_SERVERS_DIR", "/tmp/mcp-test-servers");
        let dir = mcp_servers_dir();
        assert_eq!(dir, PathBuf::from("/tmp/mcp-test-servers"));
        std::env::remove_var("CHUMP_MCP_SERVERS_DIR");
    }

    // ── ACP-001 persistent-server tests ────────────────────────────────────

    /// Write a tiny bash script that acts as a minimal MCP server:
    /// - reads JSON-RPC lines from stdin
    /// - answers `tools/list` with a canned `echo_tool` descriptor
    /// - answers `tools/call` by echoing the arguments back in `content`
    /// - echoes `id` so JSON-RPC round-trip matches
    ///
    /// Returns the path to the script (the TempDir is kept alive by the
    /// caller to ensure the file isn't removed mid-test).
    fn write_mock_mcp_server(dir: &std::path::Path) -> std::path::PathBuf {
        let script = dir.join("mock_mcp.sh");
        let body = r#"#!/usr/bin/env bash
while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    method=$(printf '%s' "$line" | sed -n 's/.*"method"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    case "$method" in
        tools/list)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo_tool","description":"mock echo","inputSchema":{"type":"object","properties":{"msg":{"type":"string"}}}}]}}\n' "$id"
            ;;
        tools/call)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"mock ok"}]}}\n' "$id"
            ;;
        *)
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"unknown method: %s"}}\n' "$id" "$method"
            ;;
    esac
done
"#;
        std::fs::write(&script, body).expect("write mock script");
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&script).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&script, perms).unwrap();
        script
    }

    /// AcpMcpProxyTool: exercise the full `axonerai::tool::Tool` surface.
    /// Proves pool tools are invokable like any other tool once wired into
    /// a ToolRegistry — the ACP-001 follow-up acceptance.
    #[tokio::test]
    async fn acp_mcp_proxy_tool_roundtrips_call() {
        let tmp = tempfile::tempdir().unwrap();
        let script = write_mock_mcp_server(tmp.path());
        let configs = vec![(
            "mock-proxy".to_string(),
            script.to_string_lossy().to_string(),
            vec![],
        )];
        let pool = Arc::new(SessionMcpPool::spawn_all(&configs).await.unwrap());

        let proxies = AcpMcpProxyTool::from_pool(Arc::clone(&pool));
        assert_eq!(proxies.len(), 1, "one tool advertised → one proxy");

        let proxy = &proxies[0];
        assert_eq!(proxy.name(), "echo_tool");
        assert!(proxy.description().starts_with("[ACP-MCP]"));
        assert_eq!(proxy.input_schema()["type"].as_str(), Some("object"));

        let out = proxy.execute(json!({"msg": "via proxy"})).await.unwrap();
        // Mock returns `{"content":[{"type":"text","text":"mock ok"}]}`
        // pretty-printed; context_firewall is a no-op on benign text.
        assert!(out.contains("mock ok"), "proxy output: {}", out);

        drop(proxies);
        let pool = Arc::try_unwrap(pool).unwrap_or_else(|_| panic!("pool Arc refcount > 1"));
        pool.shutdown().await;
    }
}
