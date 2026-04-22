# chump-mcp-coord

[MCP](https://modelcontextprotocol.io/) server for **fleet coordination** on the Chump repo: gap preflight, lease visibility, musher pick, and ambient tail — over JSON-RPC on stdio.

This crate **does not** read `.env` and **does not** edit `docs/gaps.yaml` (no status mutations). Lease changes go through `scripts/gap-claim.sh` only.

## Install

```bash
cargo install chump-mcp-coord
```

## Configure

Set **`CHUMP_REPO`** or **`CHUMP_HOME`** to the repository root (same as other Chump MCP servers).

Optional **`CHUMP_LOCK_DIR`**: override `.chump-locks/` for tests (must match `gap-preflight` / `gap-claim` in that session).

```json
{
  "mcpServers": {
    "chump-coord": {
      "command": "chump-mcp-coord",
      "cwd": "/path/to/chump",
      "env": { "CHUMP_REPO": "/path/to/chump" }
    }
  }
}
```

## Tools (MCP `tools/list`)

| Tool | Role |
|------|------|
| `gap_preflight` | Run `scripts/gap-preflight.sh` for one or more gap IDs. |
| `gap_claim_lease` | Run `scripts/gap-claim.sh` (writes lease JSON under `CHUMP_LOCK_DIR` / `.chump-locks/`). |
| `lease_list_active` | Summarize active `*.json` leases (excludes `ambient.jsonl`). |
| `musher_pick` | Run `scripts/musher.sh --pick` and return stdout/stderr. |
| `ambient_tail` | Read last *N* lines of `ambient.jsonl` (read-only). |

## Status

- v0.1.0 — initial publish (**INFRA-033**) from the [`chump`](https://github.com/repairman29/chump) monorepo.
