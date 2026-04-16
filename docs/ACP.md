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
| `session/new` | client → agent | ✓ returns sessionId + config options + modes (work / research / light); records client-requested `mcpServers` on `SessionEntry` (lifecycle management is V3) |
| `session/load` | client → agent | ✓ reattach to an existing session; memory-first, falls back to disk when `CHUMP_HOME`/`CHUMP_REPO` configured; returns configOptions + modes (no sessionId) |
| `session/list` | client → agent | ✓ cursor-paginated enumeration; optional `cwd` + `mode` filters + `pageSize` (default 50, max 200); merges memory + disk state; SessionInfo includes `currentMode`; returns `sessions[]` + `nextCursor?` |
| `session/prompt` | client → agent | ✓ runs agent turn, streams progress; flattens mixed-content prompts (text + images + resources). Image blocks become placeholders for text-only models; Resource URIs auto-fetch via `fs/read_text_file` when the editor declared `fs.read`. |
| `session/set_mode` | client → agent | ✓ switch between work/research/light mid-session; emits `ModeChanged` |
| `session/set_config_option` | client → agent | ✓ runtime reconfiguration of advertised options |
| `session/list_permissions` | client → agent | ✓ enumerate sticky decisions cached for the session (sorted by tool name); editor "Permissions" panel UX |
| `session/clear_permission` | client → agent | ✓ forget one sticky decision (`toolName`) or all (`toolName` omitted); returns `cleared: N` |
| `session/cancel` | client → agent | ✓ notification; cancels in-flight prompt |
| `session/request_permission` | agent → client | ✓ outbound RPC for tool-call user-consent prompts; fail-closed on RPC error/timeout. Wiring into `ToolTimeoutWrapper` is the remaining hook (V2.1) |
| `fs/read_text_file` | agent → client | ✓ delegates file reads to client's filesystem (line/limit slicing); use when Chump runs on a different host than the editor |
| `fs/write_text_file` | agent → client | ✓ delegates file writes; client owns encoding & line endings |
| `terminal/create` | agent → client | ✓ spawn shell process in client's environment; returns `terminalId` |
| `terminal/output` | agent → client | ✓ poll buffered output + truncated flag + (optional) exit status |
| `terminal/wait_for_exit` | agent → client | ✓ block until process exits, return `{ exitCode? \| signal? }` (1h timeout) |
| `terminal/kill` | agent → client | ✓ SIGKILL the process; idempotent |
| `terminal/release` | agent → client | ✓ tell client to free buffer + handles; always call when done |
| `session/update` | agent → client | ✓ streams: `AgentMessageDelta`, `AgentMessageComplete`, `ToolCallStart`, `ToolCallResult`, `ModeChanged` |

**V2 (not yet implemented — tracked for later sprint):**

All core ACP V2 items are shipped. The remaining roadmap items are polish and quality-of-life enhancements:

- Richer `session/update` streaming (currently streams core events; full spec also includes thinking tokens, structured tool I/O previews, etc.)
- First-class editor integration tests against real Zed + JetBrains clients (currently all tests use simulated clients)
- Sticky permission decisions surviving across process restarts (sticky cache persists to disk with the rest of SessionEntry, but the UI affordance "remember across restarts" isn't exposed yet)

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

The ACP implementation has 96 unit tests covering:

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
- `session/set_mode` happy path emits `ModeChanged` notification before ack and persists state
- `session/set_mode` rejects unknown mode ids and unknown sessions with `ERROR_INVALID_PARAMS`
- `session/set_config_option` persists JSON value and rejects unknown option ids/sessions
- Bidirectional RPC: outbound request → simulated client response → caller receives result
- Bidirectional RPC: client error response is propagated to the caller as `Err(JsonRpcError)`
- Bidirectional RPC: timeout reaps the pending entry so memory doesn't leak
- Unknown response ids are logged and dropped (no panic, no leak)
- `session/request_permission` round-trip with `allow_once`, `allow_always`, `cancelled`, RPC error, and unknown option-id outcomes — `is_allowed()` and `is_sticky()` honor a fail-closed default
- `fs/read_text_file` round-trip including line/limit forwarding, and `fs/read_text_file` client error propagation (e.g. ENOENT)
- `fs/write_text_file` round-trip with empty-result success ack, and EACCES error propagation
- `terminal/create` round-trip with command + args + cwd + env + outputByteLimit, and the omits-optional-fields case
- `terminal/output` for both running (no `exitStatus`) and exited (with `exitStatus`) processes; `truncated` flag verified
- `terminal/wait_for_exit` returns `{ exitCode? \| signal? }` with signal-killed processes mapping to `signal: "SIGTERM"`
- `terminal/kill` and `terminal/release` round-trips
- `terminal/create` client error propagation (e.g. command-not-found)
- `session/list` pagination: walks 5 sessions via 3 pages of size 2, verifying `nextCursor` threads correctly and is omitted on the final page
- `session/list` clamps oversize `pageSize` to the 200 max
- `session/list` with an unknown cursor returns an empty page (not an error) so clients paginating over a mutating set don't break
- Cross-process persistence round-trip: session created by server1 is reconstituted by server2 (separate memory) via `session/load` pointed at the same persist dir
- `session/list` merges disk-only sessions (persisted by a prior process) with in-memory sessions without duplicates
- `session/load` for a session not in memory nor on disk returns `ERROR_INVALID_PARAMS` (no auto-create)
- Per-instance `persist_dir` plumbing: tests construct `AcpServer::new_with_persist_dir(tx, None)` for no-persist or `Some(dir)` for scoped persistence, so parallel tests don't race on env vars
- Content block flattening: text-only join with blank-line separators, empty-text skip, image placeholder with size + mime, unknown-scheme resource placeholder, file-uri-outside-acp placeholder, mixed-prompt order preservation, image-only-prompt non-empty
- `session/new` records `mcpServers` on `SessionEntry.requested_mcp_servers` (name + command + args); empty mcpServers is fine and warning-free
- `session/list_permissions`: empty for fresh session, returns seeded decisions sorted by tool name, unknown session → `ERROR_INVALID_PARAMS`
- `session/clear_permission`: single-tool removal returns `cleared: 1`, all-clear returns count, unknown tool returns `cleared: 0` (idempotent), unknown session → `ERROR_INVALID_PARAMS`
- `session/list` `mode` filter: creates two work-mode sessions, switches one to research via `set_mode`, then verifies `mode=research` returns only the switched one, `mode=work` returns the other, no filter returns both. `SessionInfo.currentMode` exposed on the wire.

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
