# chump-mcp-memory

MCP server exposing Chump session memory and episode logging via JSON-RPC 2.0 over stdio.

## Tools

| Tool | Description |
|---|---|
| `memory_search` | FTS5 keyword search over semantic memory (chump_memory table) |
| `memory_recall` | LIKE-search everything known about a named entity/topic |
| `episode_save` | Append an episodic event (cross-session, cross-repo searchable) |
| `episode_search` | Search episode history by keyword, optional repo filter |

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `CHUMP_REPO` / `CHUMP_HOME` | cwd | Repo root; DB lives at `<root>/sessions/chump_memory.db` |
| `CHUMP_MEMORY_DB` | — | Override absolute path to the SQLite DB |

Per-repo isolation is the default: each `CHUMP_REPO` gets its own `sessions/chump_memory.db`.
Cross-repo linking is a follow-up (REQ-004).

## Claude Code `.mcp.json` snippet

```json
{
  "mcpServers": {
    "chump-memory": {
      "command": "chump-mcp-memory",
      "env": { "CHUMP_REPO": "/path/to/your/repo" }
    }
  }
}
```
