# chump-mcp-tavily

A standalone [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server exposing [Tavily](https://tavily.com/) web-search operations over JSON-RPC stdio. Plug it into any MCP-aware agent (Claude Desktop, Zed, the [`chump`](https://github.com/repairman29/chump) agent, etc.) to give the model fast LLM-tuned web search without writing a custom tool layer.

## Install

```bash
cargo install chump-mcp-tavily
```

## Configure

Set `TAVILY_API_KEY` in the agent's environment. Get a free key at https://tavily.com.

In Claude Desktop / Zed:

```json
{
  "mcpServers": {
    "tavily": {
      "command": "chump-mcp-tavily",
      "env": { "TAVILY_API_KEY": "tvly-..." }
    }
  }
}
```

## Tools provided

- `tavily_search` — general web search returning top-N results with snippets
- `tavily_extract` — pull full content of a URL with optional summarization

(Full schema published via the standard MCP `tools/list` JSON-RPC method — the agent discovers them automatically.)

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo)

## License

MIT.

## Companion crates

- [`chump-mcp-github`](https://crates.io/crates/chump-mcp-github) — GitHub MCP server
- [`chump-mcp-adb`](https://crates.io/crates/chump-mcp-adb) — Android Debug Bridge MCP server
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — manage MCP server lifecycles inside an agent runtime
