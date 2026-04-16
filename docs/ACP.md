# Agent Client Protocol (ACP) — Chump

[ACP](https://agentclientprotocol.com) is the open standard from Zed Industries and JetBrains for editor ↔ coding-agent communication. Chump implements ACP as a first-class adapter so it can be launched by any ACP-compatible client: Zed, JetBrains IDEs, and any tool in the [ACP Registry](https://blog.jetbrains.com/ai/2026/01/acp-agent-registry/).

## Quick Start

### Launch Chump as an ACP agent

```bash
chump --acp
```

Chump reads JSON-RPC messages from stdin and writes responses / streaming notifications to stdout. `stderr` carries `tracing` logs (never JSON-RPC — safe to redirect).

### Client side

Configure your ACP client to launch Chump. Example Zed configuration:

```json
{
  "agents": {
    "chump": {
      "command": "chump",
      "args": ["--acp"]
    }
  }
}
```

JetBrains IDEs discover ACP agents via the registry — once Chump is listed there, it's one click away in the Coding Agent sidebar.

## Implementation Status

**V1 (shipped):**

| Method | Direction | Status |
|--------|-----------|--------|
| `initialize` | client → agent | ✓ declares `tools`, `streaming`, `modes`, `mcpServers`, `skills` caps |
| `authenticate` | client → agent | ✓ (no-auth; we declare `"none"` method) |
| `session/new` | client → agent | ✓ returns sessionId + config options + modes (work / research / light) |
| `session/load` | client → agent | ✓ reattach to an existing in-memory session; returns configOptions + modes (no sessionId) |
| `session/list` | client → agent | ✓ enumerate known sessions; optional `cwd` filter; returns `sessions[]` + `nextCursor?` |
| `session/prompt` | client → agent | ✓ runs agent turn, streams progress |
| `session/cancel` | client → agent | ✓ notification; cancels in-flight prompt |
| `session/update` | agent → client | ✓ streams: `AgentMessageDelta`, `AgentMessageComplete`, `ToolCallStart`, `ToolCallResult` |

**V2 (not yet implemented — tracked for later sprint):**

- `session/list` cursor-based pagination (V1 returns all sessions in one shot; `cursor` is accepted and ignored)
- Cross-process session persistence for `session/load` (V1 only resumes sessions still in this process's memory)
- `session/request_permission` — tool approval callback (agent asks client for user consent)
- `session/set_config_option` — runtime reconfiguration
- `session/set_mode` — switch between work/research/light mid-session
- `fs/read_text_file`, `fs/write_text_file` — delegate file ops to the client (useful when Chump runs on a different host than the editor)
- `terminal/*` — delegate shell execution to the client

## Chump-Specific Capabilities

Standard ACP agents declare: `tools`, `streaming`, `modes`, `mcpServers`. Chump adds one extension:

- **`skills: true`** — Chump exposes its [procedural skills system](../src/skills.rs) through the same prompt interface. When clients discover this capability, they can surface a "skill library" UI element.

## Modes

`session/new` returns three modes that map to Chump's existing context engines:

| Mode | Description | Context engine |
|------|-------------|----------------|
| `work` | General coding tasks | default (full consciousness framework) |
| `research` | Synthesis across sources | default (higher compression threshold) |
| `light` | Fast responses, slim context | light (PWA-style) |

Clients can let users pick a mode per session.

## Transport Details

- **Framing:** newline-delimited JSON (one message per line)
- **Encoding:** UTF-8
- **stdin:** incoming messages from client
- **stdout:** responses + notifications to client
- **stderr:** `tracing` logs (use `RUST_LOG=info cargo run -- --acp` to see them)

## Testing

The ACP implementation has 31 unit tests covering:

- Initialize returns correct capabilities
- Unknown methods return `ERROR_METHOD_NOT_FOUND` (-32601)
- `session/new` returns sessionId and modes
- `session/load` for an unknown session returns `ERROR_INVALID_PARAMS`
- `session/load` for a known session returns `configOptions` + `modes` (no `sessionId`)
- `session/list` returns an empty array when no sessions exist
- `session/list` returns created sessions, supports `cwd` filtering, and accepts missing params
- Cancel notifications don't elicit responses (correct per spec)
- Malformed JSON returns parse errors with recovered-or-null `id`
- Prompt without text content returns `ERROR_INVALID_PARAMS`
- Event translation from Chump's `AgentEvent` to ACP `SessionUpdate`

Run with:

```bash
cargo test -- acp
```

## Related

- [src/acp.rs](../src/acp.rs) — type definitions
- [src/acp_server.rs](../src/acp_server.rs) — JSON-RPC stdio server
- [Agent Client Protocol spec](https://agentclientprotocol.com)
- [ACP Registry](https://jetbrains.com/acp)
- [Zed's ACP docs](https://zed.dev/acp)
