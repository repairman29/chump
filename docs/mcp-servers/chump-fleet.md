# chump-mcp-fleet — Fleet OS MCP Server

MCP server that exposes the Chump fleet OS as 5 JSON-RPC tools. Any Claude
instance (or MCP-compatible client) can read inboxes, broadcast events, vote on
consensus rounds, and inspect fleet capabilities — without learning shell.

**Crate:** `crates/mcp-servers/chump-mcp-fleet/`  
**Binary:** `chump-mcp-fleet`  
**Gap:** META-167-h / META-174  
**Feature flag:** `CHUMP_FLEET_WIRE_V1=1` (server exits 0 if unset)

---

## Prerequisites

```bash
export CHUMP_REPO=/path/to/chump-repo   # required
export CHUMP_FLEET_WIRE_V1=1            # required: opt-in gate
```

---

## Transport modes

| Mode | How to select | Use case |
|---|---|---|
| **stdio** (default) | no flag | Claude Code `mcpServers` launch |
| **Unix socket** | `--socket` flag or `CHUMP_FLEET_TRANSPORT=socket` | Daemonised callers |

Unix socket path: `/tmp/chump-mcp-fleet.sock` (override with `CHUMP_FLEET_SOCK`).

---

## Claude Code mcp-config snippet

Add to your `claude_desktop_config.json` (or equivalent `mcp-config`):

```json
{
  "mcpServers": {
    "chump-fleet": {
      "command": "chump-mcp-fleet",
      "env": {
        "CHUMP_FLEET_WIRE_V1": "1",
        "CHUMP_REPO": "/path/to/chump-repo"
      }
    }
  }
}
```

Or if running from source:

```json
{
  "mcpServers": {
    "chump-fleet": {
      "command": "cargo",
      "args": ["run", "--bin", "chump-mcp-fleet", "--manifest-path", "/path/to/chump-repo/Cargo.toml"],
      "env": {
        "CHUMP_FLEET_WIRE_V1": "1",
        "CHUMP_REPO": "/path/to/chump-repo"
      }
    }
  }
}
```

---

## Tools

### `mcp__chump_fleet__inbox_drain`

Read pending fleet messages for a session from `.chump-locks/inbox/<session_id>.jsonl`
since the last cursor position.

**Parameters:**

| Field | Type | Required | Description |
|---|---|---|---|
| `session_id` | string | yes | Session ID whose inbox to drain |
| `advance_cursor` | boolean | no | Advance cursor after read (default `true`) |

**Response shape:**

```json
{
  "success": true,
  "session_id": "claim-infra-1234-56789-1780000000",
  "messages": [ { "ts": "...", "kind": "...", "from": "..." } ],
  "messages_read": 3,
  "previous_offset": 0,
  "new_offset": 512
}
```

**Wraps:** direct file read of `.chump-locks/inbox/<session_id>.jsonl`

---

### `mcp__chump_fleet__broadcast`

Emit a structured broadcast event via `scripts/coord/broadcast.sh`.

**Parameters:**

| Field | Type | Required | Description |
|---|---|---|---|
| `event_type` | string | yes | `INTENT` \| `HANDOFF` \| `STUCK` \| `DONE` \| `WARN` \| `ALERT` \| `FEEDBACK` |
| `subject` | string | yes | Main message / subject text |
| `kind` | string | no | Sub-type for FEEDBACK/ALERT (e.g. `lesson`, `upgrade`) |
| `rationale` | string | no | Supporting detail |
| `vote` | string | no | Vote value for FEEDBACK events |
| `to` | string | no | Recipient session ID for targeted delivery |
| `urgency` | string | no | `INFO` \| `WARN` \| `CRIT` \| `EMERGENCY` (default `INFO`) |

**Example — send a lesson broadcast:**

```json
{
  "event_type": "FEEDBACK",
  "kind": "lesson",
  "subject": "always run cargo fmt before committing",
  "urgency": "INFO"
}
```

**Wraps:** `scripts/coord/broadcast.sh [--to <recipient>] [--urgency <level>] <EVENT_TYPE> [args...]`

---

### `mcp__chump_fleet__vote`

Cast a vote on a fleet consensus round.

**Parameters:**

| Field | Type | Required | Description |
|---|---|---|---|
| `corr_id` | string | yes | Correlation ID for the vote round |
| `vote` | string | yes | Vote value: `yes`, `no`, `abstain`, `+1`, `-1` |
| `reason` | string | no | Free-text reason |

**Example:**

```json
{
  "corr_id": "meta-157-merge-2026-05-30",
  "vote": "yes",
  "reason": "CI green, LGTM"
}
```

**Wraps:** `chump vote <corr_id> <vote> [--reason <reason>]`

---

### `mcp__chump_fleet__consensus_status`

Query the current consensus tally for a vote round or all active rounds.

**Parameters (at least one of `corr_id` or `all=true` required):**

| Field | Type | Required | Description |
|---|---|---|---|
| `corr_id` | string | no | Filter to a specific correlation ID |
| `all` | boolean | no | Show all active rounds |
| `since` | string | no | ISO-8601 timestamp filter |

**Example — check a specific round:**

```json
{ "corr_id": "meta-157-merge-2026-05-30" }
```

**Example — list all active rounds:**

```json
{ "all": true }
```

**Wraps:** `chump consensus-tally [--corr-id <X>] [--all] [--since <ts>]`

---

### `mcp__chump_fleet__capabilities`

List online Chump fleet sessions and their capabilities.

**Parameters:**

| Field | Type | Required | Description |
|---|---|---|---|
| `include_stale` | boolean | no | Include sessions past their TTL (default `false`) |

**Response shape (NATS online):**

```json
{
  "success": true,
  "source": "nats_kv",
  "capabilities": { ... }
}
```

**Response shape (offline fallback):**

```json
{
  "success": true,
  "source": "offline_glob",
  "sessions": [
    { "session_id": "claim-infra-1234", "gap_id": "INFRA-1234", "expires_at": "..." },
    { "session_id": "curator-opus-ci-audit", "source": "lock_file" }
  ],
  "count": 2,
  "note": "NATS unavailable; using offline lock-file scan"
}
```

**Wraps:** `chump capabilities --json` → offline: glob `.chump-locks/` for claim leases + `.curator-opus-*.lock` files.

---

## Development

```bash
# Build
cargo build -p chump-mcp-fleet

# Run tests
cargo test -p chump-mcp-fleet

# Run in stdio mode (requires CHUMP_REPO set)
CHUMP_FLEET_WIRE_V1=1 CHUMP_REPO=/path/to/repo cargo run -p chump-mcp-fleet

# Run in socket mode
CHUMP_FLEET_WIRE_V1=1 CHUMP_REPO=/path/to/repo cargo run -p chump-mcp-fleet -- --socket
```

---

## Security notes

- Parameters are scanned for `.env` substrings — any parameter referencing `.env` is rejected to prevent secret leaks via MCP tool arguments.
- `session_id`, `corr_id`, `vote`, and `to` fields are validated as safe tokens (alphanumeric + `-_/.`) before being passed to shell commands.
- The server never reads `.env` files itself and never writes `docs/gaps/*.yaml`.
