//! # chump-mcp-lifecycle
//!
//! **Persistent per-session MCP server lifecycle: spawn, route, reap.**
//!
//! The Model Context Protocol lets a client declare external tool servers
//! (usually Python or Node binaries) that an agent can call during a
//! session. The lifecycle model in the ACP spec says: spawn each server
//! on `session/new`, route `tools/call` traffic over stdio JSON-RPC during
//! the session, then reap every child process on `session/cancel` or
//! agent-process exit.
//!
//! Most published MCP bridges handle a single call and spawn a fresh
//! child per invocation — a stateless model that works for simple tools
//! but breaks for MCP servers that do any warm-up (embedding indexes,
//! DB connections, loaded models). This crate is for the stateful case:
//! **one child per server, one pool per session, kill-on-drop on both.**
//!
//! Two primitives:
//!
//! - [`PersistentMcpServer`] — one long-lived child process with open
//!   stdin/stdout pipes, serialized JSON-RPC request/response over
//!   stdio, `tokio::process::Child::kill_on_drop(true)` for the reap
//!   safety net, and an explicit `Drop` impl that sends `start_kill()`
//!   synchronously.
//!
//! - [`SessionMcpPool`] — a bundle of N persistent servers for one ACP
//!   session, indexed by tool name so `pool.call_tool("echo", args)` is
//!   one hop to the right child. Pool `Drop` cascades to every server's
//!   `Drop`, guaranteeing child reap when the session ends.
//!
//! ## Quick start
//!
//! ```no_run
//! use chump_mcp_lifecycle::SessionMcpPool;
//! use serde_json::json;
//!
//! # #[tokio::main]
//! # async fn main() -> anyhow::Result<()> {
//! let configs = vec![
//!     ("filesystem".to_string(), "mcp-server-filesystem".to_string(), vec![]),
//! ];
//! let pool = SessionMcpPool::spawn_all(&configs).await?;
//! println!("spawned {} tools across {} servers",
//!     pool.tool_count(), pool.server_count());
//!
//! let result = pool.call_tool("read_file", json!({"path": "README.md"})).await?;
//! println!("result: {:?}", result);
//!
//! // Explicit shutdown (or just drop the pool — children get SIGKILL either way).
//! pool.shutdown().await;
//! # Ok(()) }
//! ```
//!
//! ## Lifecycle model
//!
//! Chump uses this crate from its ACP server to implement the ACP-001
//! spec: on `session/new` with non-empty `mcpServers`, spawn a pool
//! and attach it to the in-memory `SessionEntry`. When the session is
//! removed from the sessions map (session/cancel or ACP server drop),
//! the Entry drops, the pool drops, and every child gets SIGKILL via
//! the Drop cascade.
//!
//! `session/cancel` intentionally does NOT reap per ACP spec — cancel
//! kills the in-flight *prompt*, not the session. Session death (and
//! child reap) happens on the sessions-map removal or process exit.
//!
//! ## Why not a daemon
//!
//! We looked at a daemon model (one persistent MCP manager process
//! per host, sessions multiplex over it) and decided against it for
//! three reasons:
//!
//! 1. **Isolation** — two ACP clients running as different users on
//!    the same host should not share MCP servers.
//! 2. **Blast radius** — a buggy MCP server crashing shouldn't kill
//!    every session.
//! 3. **Operational complexity** — a daemon wants a systemd unit + a
//!    socket + a protocol for session attachment. Per-session spawn
//!    trades startup latency for operational simplicity.
//!
//! ## Hard cap
//!
//! [`SessionMcpPool::spawn_all`] refuses to spawn more than
//! [`MAX_SERVERS_PER_SESSION`] children to prevent a malicious or
//! buggy client from fork-bombing the host.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex as AsyncMutex;

/// Hard cap on MCP servers one session can request. Prevents a malicious or
/// buggy client from spawning hundreds of child processes.
pub const MAX_SERVERS_PER_SESSION: usize = 16;

/// Per-server spawn + response timeout. If a server doesn't produce its
/// `initialize` / `tools/list` response within this window we abandon it.
pub const SPAWN_HANDSHAKE_TIMEOUT_SECS: u64 = 10;

/// Full metadata for an MCP-discovered tool. Emitted by MCP servers from
/// their `tools/list` response; consumed by an agent's ToolRegistry.
#[derive(Clone, Debug)]
pub struct McpToolMeta {
    /// Tool name — what the agent calls it.
    pub name: String,
    /// One-line description shown to the model.
    pub description: String,
    /// JSON Schema for the tool's arguments.
    pub input_schema: Value,
    /// Informational: path to the owning binary (for the global registry
    /// model) or `"(session-scoped)"` for tools routed through a pool.
    pub binary: PathBuf,
}

/// A single MCP server child process kept alive across multiple JSON-RPC
/// calls. Dropping this sends SIGKILL to the child.
pub struct PersistentMcpServer {
    /// Configured server name (from the caller). Not the tool name.
    name: String,
    /// Child handle. Moved out of the struct only by `shutdown()`; on Drop
    /// the handle's destructor runs `start_kill()` via the helper below.
    child: Option<Child>,
    /// Long-lived stdin/stdout pipes. Wrapped in AsyncMutex because the
    /// agent loop may send multiple concurrent `call()`s.
    stdin: Arc<AsyncMutex<ChildStdin>>,
    stdout: Arc<AsyncMutex<BufReader<ChildStdout>>>,
    /// Monotonic id for JSON-RPC request correlation. Starts at 1.
    request_counter: AtomicU64,
}

impl PersistentMcpServer {
    /// Spawn the given command + args as a child and keep its pipes open.
    /// Does NOT send an `initialize` request — callers who need the MCP
    /// handshake should follow up with `call("initialize", ...)`. We also
    /// don't pre-fetch the tool list here so the caller controls when that
    /// network cost is paid.
    pub async fn spawn(name: String, command: String, args: Vec<String>) -> Result<Self> {
        let mut child = Command::new(&command)
            .args(&args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("spawn MCP server {:?} (command={})", name, command))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("MCP server {:?}: no stdin pipe", name))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("MCP server {:?}: no stdout pipe", name))?;

        Ok(Self {
            name,
            child: Some(child),
            stdin: Arc::new(AsyncMutex::new(stdin)),
            stdout: Arc::new(AsyncMutex::new(BufReader::new(stdout))),
            request_counter: AtomicU64::new(1),
        })
    }

    /// The configured server name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The live PID, or `None` after `shutdown()` has been called.
    pub fn pid(&self) -> Option<u32> {
        self.child.as_ref().and_then(|c| c.id())
    }

    /// Send a JSON-RPC request and await the response. Serializes concurrent
    /// calls via the stdin mutex so the MCP server sees one request at a time
    /// (MCP servers are generally single-threaded over stdio).
    pub async fn call(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.request_counter.fetch_add(1, Ordering::SeqCst);
        let request = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id,
        });
        let line = format!("{}\n", serde_json::to_string(&request)?);

        let mut stdin = self.stdin.lock().await;
        stdin
            .write_all(line.as_bytes())
            .await
            .with_context(|| format!("MCP server {:?}: write {} request", self.name, method))?;
        stdin.flush().await.ok();
        drop(stdin);

        // Read the response. We wrap the read in a timeout so a crashed or
        // hung server can't deadlock the whole session.
        let mut stdout = self.stdout.lock().await;
        let mut response_line = String::new();
        let read_fut = stdout.read_line(&mut response_line);
        let n = tokio::time::timeout(
            std::time::Duration::from_secs(SPAWN_HANDSHAKE_TIMEOUT_SECS * 3),
            read_fut,
        )
        .await
        .map_err(|_| {
            anyhow!(
                "MCP server {:?}: response timeout on method {}",
                self.name,
                method
            )
        })?
        .with_context(|| format!("MCP server {:?}: read {} response", self.name, method))?;
        if n == 0 {
            return Err(anyhow!(
                "MCP server {:?}: EOF on stdout (child exited) during {}",
                self.name,
                method
            ));
        }

        let response: Value = serde_json::from_str(response_line.trim())
            .with_context(|| format!("MCP server {:?}: invalid JSON-RPC response", self.name))?;

        // Validate id round-trip when present. Loose: not all MCP servers
        // echo the id, so we don't fail if missing.
        if let Some(rid) = response.get("id").and_then(|v| v.as_u64()) {
            if rid != id {
                tracing::warn!(
                    server = %self.name,
                    expected = id,
                    got = rid,
                    "MCP server: JSON-RPC id mismatch (continuing)"
                );
            }
        }

        if let Some(err) = response.get("error") {
            let msg = err
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown error");
            return Err(anyhow!("MCP server {:?}: {}", self.name, msg));
        }

        response
            .get("result")
            .cloned()
            .ok_or_else(|| anyhow!("MCP server {:?}: response missing `result`", self.name))
    }

    /// Query the server's tool inventory. Caller decides when to pay this.
    pub async fn list_tools(&self) -> Result<Vec<McpToolMeta>> {
        let result = self.call("tools/list", json!({})).await?;
        let tools = result
            .get("tools")
            .and_then(|v| v.as_array())
            .ok_or_else(|| anyhow!("MCP server {:?}: tools/list missing array", self.name))?;
        let out: Vec<McpToolMeta> = tools
            .iter()
            .filter_map(|t| {
                let name = t.get("name")?.as_str()?.to_string();
                let description = t
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let input_schema = t
                    .get("inputSchema")
                    .cloned()
                    .unwrap_or_else(|| json!({"type": "object"}));
                Some(McpToolMeta {
                    name,
                    description,
                    input_schema,
                    // For persistent servers the `binary` field is informational —
                    // the real routing happens via SessionMcpPool's server map.
                    binary: PathBuf::from("(session-scoped)"),
                })
            })
            .collect();
        Ok(out)
    }

    /// Gracefully shut down the child. Awaits until the child exits (with a
    /// short grace period) so the caller knows it's reaped. If the graceful
    /// path times out, escalates to SIGKILL.
    pub async fn shutdown(mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), child.wait()).await;
        }
    }
}

impl Drop for PersistentMcpServer {
    fn drop(&mut self) {
        if let Some(ref mut child) = self.child {
            // Synchronous kill — we can't `await` in Drop. kill_on_drop(true)
            // in spawn() is the safety net; this is belt-and-suspenders.
            let _ = child.start_kill();
        }
    }
}

/// A bundle of per-session MCP servers + their aggregated tool metadata.
///
/// Typical usage: constructed on `session/new` with the client's requested
/// mcpServers configs; attached to the in-memory SessionEntry; dropped on
/// session/cancel or process exit. When the pool drops, every
/// [`PersistentMcpServer`] drops, which SIGKILLs every child.
pub struct SessionMcpPool {
    servers: Vec<PersistentMcpServer>,
    tools: Vec<McpToolMeta>,
    /// Map `tool_name → index into servers` so call routing is O(1).
    tool_index: HashMap<String, usize>,
}

impl SessionMcpPool {
    /// Empty pool (no servers). Use when the caller didn't request any.
    pub fn empty() -> Self {
        Self {
            servers: Vec::new(),
            tools: Vec::new(),
            tool_index: HashMap::new(),
        }
    }

    /// Spawn every server in `configs` and query each one's tool list.
    /// Best-effort: servers that fail to spawn or return a bad tool
    /// list are logged and skipped, not fatal. Returns the pool on the OK
    /// path; returns Err only on invariant violations (too many servers).
    ///
    /// `configs` is `(name, command, args)` for each server to spawn.
    pub async fn spawn_all(configs: &[(String, String, Vec<String>)]) -> Result<Self> {
        if configs.len() > MAX_SERVERS_PER_SESSION {
            return Err(anyhow!(
                "too many MCP servers requested ({} > max {})",
                configs.len(),
                MAX_SERVERS_PER_SESSION
            ));
        }
        let mut servers: Vec<PersistentMcpServer> = Vec::with_capacity(configs.len());
        let mut tools: Vec<McpToolMeta> = Vec::new();
        let mut tool_index: HashMap<String, usize> = HashMap::new();

        for (name, command, args) in configs {
            let server =
                match PersistentMcpServer::spawn(name.clone(), command.clone(), args.clone()).await
                {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::warn!(
                            server = %name,
                            command = %command,
                            error = %e,
                            "MCP spawn failed; skipping this server"
                        );
                        continue;
                    }
                };
            let metas = match tokio::time::timeout(
                std::time::Duration::from_secs(SPAWN_HANDSHAKE_TIMEOUT_SECS),
                server.list_tools(),
            )
            .await
            {
                Ok(Ok(m)) => m,
                Ok(Err(e)) => {
                    tracing::warn!(
                        server = %name,
                        error = %e,
                        "MCP server: tools/list failed; server kept alive with 0 tools"
                    );
                    Vec::new()
                }
                Err(_) => {
                    tracing::warn!(
                        server = %name,
                        secs = SPAWN_HANDSHAKE_TIMEOUT_SECS,
                        "MCP server: tools/list timeout; server kept alive with 0 tools"
                    );
                    Vec::new()
                }
            };

            let idx = servers.len();
            for m in &metas {
                if tool_index.contains_key(&m.name) {
                    tracing::warn!(
                        tool = %m.name,
                        server = %name,
                        "MCP pool: duplicate tool name across session servers; first wins"
                    );
                    continue;
                }
                tool_index.insert(m.name.clone(), idx);
                tools.push(m.clone());
            }
            servers.push(server);
        }

        Ok(Self {
            servers,
            tools,
            tool_index,
        })
    }

    /// True if the pool has no spawned servers.
    pub fn is_empty(&self) -> bool {
        self.servers.is_empty()
    }

    /// Number of live servers in the pool.
    pub fn server_count(&self) -> usize {
        self.servers.len()
    }

    /// Configured names of live servers, in spawn order.
    pub fn server_names(&self) -> Vec<&str> {
        self.servers.iter().map(|s| s.name()).collect()
    }

    /// All tools exposed by any server in the pool. Names are unique
    /// (duplicates across servers get silently dropped with a warning
    /// during `spawn_all`).
    pub fn tools(&self) -> &[McpToolMeta] {
        &self.tools
    }

    /// Total tool count across every server in the pool.
    pub fn tool_count(&self) -> usize {
        self.tools.len()
    }

    /// Whether the pool exposes a tool by this name.
    pub fn has_tool(&self, name: &str) -> bool {
        self.tool_index.contains_key(name)
    }

    /// Route a tool call to the server that owns `tool_name`. Returns Err if
    /// the tool isn't registered with any server in this pool.
    pub async fn call_tool(&self, tool_name: &str, params: Value) -> Result<Value> {
        let idx = *self
            .tool_index
            .get(tool_name)
            .ok_or_else(|| anyhow!("tool `{}` not in session MCP pool", tool_name))?;
        let server = self
            .servers
            .get(idx)
            .ok_or_else(|| anyhow!("tool index out of range (internal bug)"))?;
        // MCP `tools/call` wraps {name, arguments} inside the request.
        server
            .call(
                "tools/call",
                json!({ "name": tool_name, "arguments": params }),
            )
            .await
    }

    /// Gracefully shut down every server. Consumes self so the caller can't
    /// accidentally reuse the pool after shutdown.
    pub async fn shutdown(self) {
        for server in self.servers {
            server.shutdown().await;
        }
    }
}

// Direct read access to the servers vector for tests + advanced callers that
// need to inspect (not own) the list. Hidden from rustdoc since it's a
// plumbing detail, not part of the advertised API surface.
#[doc(hidden)]
impl SessionMcpPool {
    pub fn __servers(&self) -> &[PersistentMcpServer] {
        &self.servers
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    /// Write a tiny bash script that acts as a minimal MCP server:
    /// - reads JSON-RPC lines from stdin
    /// - answers `tools/list` with a canned `echo_tool` descriptor
    /// - answers `tools/call` with a canned content payload
    /// - echoes `id` so JSON-RPC round-trip matches
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
        // Create the file with executable permissions in one shot (no separate
        // set_permissions call) and call sync_all() so the kernel has flushed
        // the write before we try to exec it. Without sync_all() Linux can return
        // ETXTBSY ("Text file busy", os error 26) on rapid write-then-exec cycles
        // seen in parallel CI environments.
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .mode(0o755)
            .open(&script)
            .expect("create mock script");
        f.write_all(body.as_bytes())
            .expect("write mock script body");
        f.sync_all().expect("sync mock script to disk");
        drop(f);
        script
    }

    /// True if the given PID exists as a live process (kill -0 semantics).
    fn pid_alive(pid: u32) -> bool {
        std::process::Command::new("kill")
            .arg("-0")
            .arg(pid.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    #[tokio::test]
    #[serial]
    async fn persistent_mcp_server_spawn_list_shutdown() {
        let tmp = tempfile::tempdir().unwrap();
        let script = write_mock_mcp_server(tmp.path());

        let server = PersistentMcpServer::spawn(
            "mock".to_string(),
            script.to_string_lossy().to_string(),
            vec![],
        )
        .await
        .expect("spawn mock MCP server");

        let tools = server.list_tools().await.expect("list_tools");
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0].name, "echo_tool");
        assert_eq!(tools[0].description, "mock echo");

        // Second call must also work (persistent — not spawn-per-call).
        let tools2 = server.list_tools().await.expect("list_tools (2)");
        assert_eq!(tools2.len(), 1);

        server.shutdown().await;
    }

    #[tokio::test]
    #[serial]
    async fn session_mcp_pool_empty_is_ok() {
        let pool = SessionMcpPool::spawn_all(&[]).await.unwrap();
        assert!(pool.is_empty());
        assert_eq!(pool.tool_count(), 0);
        assert_eq!(pool.server_count(), 0);
    }

    #[tokio::test]
    #[serial]
    async fn session_mcp_pool_spawn_routes_tool_call() {
        let tmp = tempfile::tempdir().unwrap();
        let script = write_mock_mcp_server(tmp.path());
        let configs = vec![(
            "mock-a".to_string(),
            script.to_string_lossy().to_string(),
            vec![],
        )];
        let pool = SessionMcpPool::spawn_all(&configs).await.unwrap();

        assert_eq!(pool.server_count(), 1);
        assert_eq!(pool.tool_count(), 1);
        assert!(pool.has_tool("echo_tool"));
        assert_eq!(pool.server_names(), vec!["mock-a"]);

        let result = pool
            .call_tool("echo_tool", json!({"msg": "hi"}))
            .await
            .expect("call_tool echo");
        assert_eq!(
            result
                .get("content")
                .and_then(|c| c.get(0))
                .and_then(|c| c.get("text"))
                .and_then(|v| v.as_str()),
            Some("mock ok")
        );

        pool.shutdown().await;
    }

    #[tokio::test]
    #[serial]
    async fn session_mcp_pool_drop_kills_children() {
        let tmp = tempfile::tempdir().unwrap();
        let script = write_mock_mcp_server(tmp.path());
        let configs = vec![(
            "mock-drop".to_string(),
            script.to_string_lossy().to_string(),
            vec![],
        )];

        let pid = {
            let pool = SessionMcpPool::spawn_all(&configs).await.unwrap();
            let pid = pool
                .__servers()
                .first()
                .and_then(|s| s.pid())
                .expect("child PID available");
            assert!(pid_alive(pid), "mock server should be alive after spawn");
            pid
            // pool drops here; Drop impl kills each PersistentMcpServer's child.
        };

        // Give the kernel a moment to reap — kill_on_drop only sends the
        // signal; the wait happens via tokio's drop-time reaper.
        for _ in 0..20 {
            if !pid_alive(pid) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert!(
            !pid_alive(pid),
            "mock server (PID {}) should be dead after pool drop",
            pid
        );
    }

    #[tokio::test]
    #[serial]
    async fn session_mcp_pool_rejects_too_many_servers() {
        let configs: Vec<_> = (0..=MAX_SERVERS_PER_SESSION)
            .map(|i| (format!("s{}", i), "/bin/true".to_string(), vec![]))
            .collect();
        // Don't `unwrap_err()` — SessionMcpPool doesn't impl Debug (children
        // in it don't), and Debug is required for unwrap_err. Match instead.
        let result = SessionMcpPool::spawn_all(&configs).await;
        match result {
            Ok(_) => panic!("expected err from oversized config"),
            Err(e) => assert!(
                e.to_string().contains("too many MCP servers"),
                "unexpected err: {e}"
            ),
        }
    }

    #[tokio::test]
    #[serial]
    async fn session_mcp_pool_skips_failed_spawn() {
        let tmp = tempfile::tempdir().unwrap();
        let script = write_mock_mcp_server(tmp.path());
        let configs = vec![
            (
                "bad".to_string(),
                "/nonexistent/path/does/not/exist".to_string(),
                vec![],
            ),
            (
                "good".to_string(),
                script.to_string_lossy().to_string(),
                vec![],
            ),
        ];
        let pool = SessionMcpPool::spawn_all(&configs).await.unwrap();
        assert_eq!(pool.server_count(), 1);
        assert_eq!(pool.server_names(), vec!["good"]);
        assert!(pool.has_tool("echo_tool"));
        pool.shutdown().await;
    }

    #[tokio::test]
    #[serial]
    async fn session_mcp_pool_call_unknown_tool_errors() {
        let tmp = tempfile::tempdir().unwrap();
        let script = write_mock_mcp_server(tmp.path());
        let configs = vec![(
            "mock".to_string(),
            script.to_string_lossy().to_string(),
            vec![],
        )];
        let pool = SessionMcpPool::spawn_all(&configs).await.unwrap();
        let err = pool
            .call_tool("not_registered", json!({}))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not in session MCP pool"));
        pool.shutdown().await;
    }
}
