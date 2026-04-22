# chump-mcp-gaps

[MCP](https://modelcontextprotocol.io/) server for **read-only** queries against Chump’s `docs/gaps.yaml` ledger over JSON-RPC on stdio.

## Install

```bash
cargo install chump-mcp-gaps
```

## Configure

Run from the Chump repo root (or set `CHUMP_HOME` to the repo) so the server can resolve `docs/gaps.yaml`.

```json
{
  "mcpServers": {
    "chump-gaps": {
      "command": "chump-mcp-gaps",
      "cwd": "/path/to/chump"
    }
  }
}
```

## Tools

Discover via MCP `tools/list`. This crate focuses on gap-registry reads, not lease or musher coordination (see **INFRA-033** / future `chump-mcp-coord`).

## Status

- v0.1.0 — initial publish from the [`chump`](https://github.com/repairman29/chump) monorepo.
