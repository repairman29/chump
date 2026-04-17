# chump-mcp-lifecycle

**Persistent per-session MCP (Model Context Protocol) server lifecycle for Rust agents: spawn, route, reap.**

The [Model Context Protocol](https://modelcontextprotocol.io) lets a client declare external tool servers (usually Python or Node binaries) that an agent can call during a session. The Agent Client Protocol spec says: spawn each server on `session/new`, route `tools/call` traffic over stdio JSON-RPC for the session's duration, then reap every child process on session end or agent crash.

Most published MCP bridges spawn a fresh child per invocation — a stateless model that works for simple tools but breaks for MCP servers that do any warm-up (embedding indexes, DB connections, loaded models). This crate is for the stateful case: **one child per server, one pool per session, kill-on-drop on both.**

## Two primitives

- **`PersistentMcpServer`** — one long-lived child process with open stdin/stdout pipes, serialized JSON-RPC request/response, `kill_on_drop(true)` safety net, and an explicit `Drop` impl that sends `start_kill()` synchronously.
- **`SessionMcpPool`** — a bundle of N persistent servers for one session, indexed by tool name so `pool.call_tool("echo", args)` is one hop to the right child. Pool `Drop` cascades to every server's `Drop`, guaranteeing child reap when the session ends.

## Installation

```toml
[dependencies]
chump-mcp-lifecycle = "0.1"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
```

## Example

```rust
use chump_mcp_lifecycle::SessionMcpPool;
use serde_json::json;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let configs = vec![
        ("filesystem".to_string(), "mcp-server-filesystem".to_string(), vec!["--path=/".to_string()]),
        ("browser".to_string(),    "mcp-server-browser".to_string(),    vec![]),
    ];
    let pool = SessionMcpPool::spawn_all(&configs).await?;

    println!(
        "spawned {} tools across {} servers",
        pool.tool_count(), pool.server_count()
    );

    let result = pool.call_tool("read_file", json!({"path": "README.md"})).await?;
    println!("{}", serde_json::to_string_pretty(&result)?);

    // Explicit shutdown (or just drop the pool — children get SIGKILL either way).
    pool.shutdown().await;
    Ok(())
}
```

## Hard cap

`SessionMcpPool::spawn_all` refuses to spawn more than `MAX_SERVERS_PER_SESSION` (= 16) children per session, preventing a malicious or buggy client from fork-bombing the host.

## Why not a daemon

We considered a persistent MCP manager daemon (one per host, sessions multiplex over it) and chose per-session spawn for three reasons:

1. **Isolation.** Two clients running as different users on the same host should not share MCP servers.
2. **Blast radius.** A buggy MCP server shouldn't crash every session.
3. **Operational simplicity.** A daemon wants a systemd unit + a socket + a session-attach protocol. Per-session spawn trades a few hundred ms of startup latency for operational simplicity.

## Lifecycle diagram

```text
session/new  ──▶ SessionMcpPool::spawn_all(...)
                     │
                     ├─▶ PersistentMcpServer::spawn("filesystem", ...)   ─▶ child 1
                     ├─▶ PersistentMcpServer::spawn("browser", ...)      ─▶ child 2
                     └─▶ tools/list on each ─▶ build tool_name → idx map

agent turn  ──▶ pool.call_tool("read_file", args)
                     │
                     └─▶ servers[idx].call("tools/call", { name, arguments }) over stdio

session end ──▶ SessionEntry drops ─▶ SessionMcpPool drops
                     │
                     ├─▶ PersistentMcpServer drops ─▶ child.start_kill()
                     ├─▶ PersistentMcpServer drops ─▶ child.start_kill()
                     └─▶ tokio's drop-time reaper wait()s children
```

## License

MIT. Part of the [Chump](https://github.com/repairman29/chump) project.
