# chump-mcp-github

A standalone [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server exposing GitHub operations over JSON-RPC stdio. Plug it into any MCP-aware agent (Claude Desktop, Zed, the [`chump`](https://github.com/repairman29/chump) agent, etc.) to give the model GitHub access without writing a custom tool layer.

## Install

```bash
cargo install chump-mcp-github
```

## Configure

Set `GITHUB_TOKEN` in the agent's environment. The server auto-detects scope from the token; minimal scope is `repo:read` for read-only ops.

In Claude Desktop / Zed:

```json
{
  "mcpServers": {
    "github": {
      "command": "chump-mcp-github",
      "env": { "GITHUB_TOKEN": "ghp_..." }
    }
  }
}
```

## Tools provided

The server registers tools mirroring common `gh` CLI operations:
- list issues / PRs
- read issue / PR body + comments
- post a comment
- list repository files

(Full schema published via the standard MCP `tools/list` JSON-RPC method — the agent discovers them automatically.)

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo)
- Uses `gh` under the hood for auth — install Github CLI separately if not on PATH

## License

MIT.

## Companion crates

- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — manage MCP server lifecycles inside an agent runtime
- [`chump-mcp-tavily`](https://crates.io/crates/chump-mcp-tavily) — Tavily search MCP server
- [`chump-mcp-adb`](https://crates.io/crates/chump-mcp-adb) — Android Debug Bridge MCP server
