# chump-mcp-eval

[MCP](https://modelcontextprotocol.io/) server that exposes Chump **eval harness** operations over JSON-RPC on stdio (for MCP-aware agents).

## Install

```bash
cargo install chump-mcp-eval
```

## Configure

Run from the Chump repo root so paths to `scripts/ab-harness/` and fixtures resolve.

```json
{
  "mcpServers": {
    "chump-eval": {
      "command": "chump-mcp-eval",
      "cwd": "/path/to/chump"
    }
  }
}
```

## Tools

Discover via MCP `tools/list`. Intended for bounded eval runs, not general shell access.

## Status

- v0.1.0 — initial publish from the [`chump`](https://github.com/repairman29/chump) monorepo.
