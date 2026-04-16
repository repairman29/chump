# ACP V3 Backlog

Tracking the work that's clearly identified but not yet shipped, so the next
person picking up the ACP adapter has a starting list rather than a blank page.

V1 (the spec), V2 (cross-process persistence), and V2.1 (tool-middleware
integration) all landed. Everything below is genuinely incremental polish or
new capability — Chump is a fully spec-conforming ACP agent today.

## High-value, well-scoped

### MCP server lifecycle management

**Current state (post-`d3955da`):** `NewSessionRequest.mcpServers` is recorded
on `SessionEntry.requested_mcp_servers` (name + command + args), persisted to
disk, and logged on `session/new`. Not yet spawned.

**What's needed:**

1. On `session/new` with non-empty `mcpServers`, spawn each as a child process.
2. Query each server's `tools/list` (already plumbed via `mcp_bridge`).
3. Register the discovered tools in a per-session sub-registry that scopes
   them to this ACP session only — global registration would leak between
   editors.
4. On `session/cancel` or process exit, send `SIGTERM` to each child + cleanup
   stdio.
5. On `session/load` of a session whose persisted `requested_mcp_servers` is
   non-empty, re-spawn (don't try to inherit from the previous process; the
   PIDs are gone).

**Risks:** Process leaks. Need per-session ChildProcess handles + Drop impl
on `SessionEntry` that kills children. Need to test what happens when the
client disconnects mid-session (currently `session/cancel` only sends a
notification but doesn't reap state).

**Scope:** ~2-3 days. Touches `mcp_bridge.rs`, `acp_server.rs`, and adds
roughly 200 lines.

### Vision-capable model passthrough

**Current state:** `ContentBlock::Image` becomes a text placeholder
`[Image attached: <mime>, ~N bytes (vision not supported by current local
stack)]` in `flatten_prompt_blocks`. Models without vision capability can
acknowledge but not see.

**What's needed:**

1. Detect when the active provider supports vision (check provider
   capabilities — e.g. Claude's vision models, gpt-4o, llava-on-Ollama).
2. When vision-capable: emit the image as a real multipart message segment
   instead of a placeholder. The provider trait already supports this in
   `axonerai`; the agent loop just needs to thread image data through.
3. Add a `CHUMP_VISION_ENABLED` env var to manually opt in for testing.
4. Update `chump_event_to_acp_update` to emit an `AgentMessageDelta` for
   vision-derived text so the UX matches text-only flow.

**Risks:** Image data is base64 — large prompts will blow context budgets.
Need an image-specific size cap separate from `RESOURCE_INLINE_LIMIT`.

**Scope:** ~3-5 days depending on provider plumbing. Higher because Chump's
default local stack (qwen2.5:14b) doesn't do vision; need to test against
llava-on-Ollama or a cloud provider.

### Real-editor integration tests

**Current state:** 88 ACP unit tests use a simulated client (in-memory
`mpsc::channel`). Mock-client lifecycle test (`end_to_end_mock_client_lifecycle`)
drives a 6-step sequence. Real Zed and JetBrains haven't been touched by CI.

**What's needed:**

1. CI job that installs Zed CLI, registers Chump as an ACP agent via Zed's
   config, drives a scripted session via `zed --headless` (or equivalent),
   asserts the agent responds correctly to `initialize → session/new →
   session/prompt`.
2. Same for JetBrains via the registry. Their ACP harness is JVM-based; CI
   image needs JDK + JetBrains gateway tools.
3. Capture network traces (the JSON-RPC bytes on the wire) and snapshot-test
   them so spec-drift breaks builds.

**Risks:** Editor binaries are large; CI download time matters. Headless
modes for both editors are still maturing.

**Scope:** 1 week minimum. Worth it once we hit ~10 issues from real-editor
testing that the simulated client missed.

## Medium-value, well-defined

### `session/update` Thinking streaming for vision-capable models

**Current state:** `Thinking` only fires from `TurnComplete.thinking_monologue`
(end-of-turn). The 500ms `AgentEvent::Thinking` heartbeats are dropped.

**What's needed:** When a model emits *streaming* chain-of-thought (some
providers do — Claude's extended thinking, R1-style models), forward each
chunk as a `SessionUpdate::Thinking` so editors can render the reasoning
live instead of in a single end-of-turn dump.

**Risks:** Chump doesn't currently parse streaming thinking deltas — they
arrive concatenated in the final response text. Provider trait would need
a `text_delta_thinking` channel separate from `text_delta`.

**Scope:** ~3 days. Needs provider-side work first.

### MCP server ↔ ACP capability propagation

If a client requests an MCP server that exposes a `read_file` tool, and the
client also declared `fs.read` capability, *which one wins*?

Today: undefined — both could be registered. Cleanest answer: when the
client declared an ACP capability, the matching MCP server tool is shadowed
(MCP server still spawns for non-overlapping tools). Needs a mapping table
of "ACP capability X subsumes tool name Y" and registry filtering at
session/new time.

**Scope:** ~1 day after MCP server lifecycle (above) lands.

## Smaller polish

- **Cursor-pagination by `last_accessed_at`** instead of `session_id`: today
  pagination falls back to id-tiebreaker when timestamps collide. Could be
  more intuitive to paginate by timestamp directly with a tiebreaker, since
  clients sort by recency anyway.
- **`session/list` filter by `mode`**: lets editors group sessions by
  work/research/light. Trivial — extend `ListSessionsRequest`.
- **`fs/write_text_file` append support** server-side: today we
  read-modify-write inside `WriteFileTool` when `mode=append`. ACP could add
  an `append: bool` field to `WriteTextFileParams` for atomicity. Spec-side
  conversation needed.
- **`terminal/output` push notifications**: today we poll every 100ms. ACP
  could add a `terminal/output` server-push notification. Would require
  spec extension; may already be discussed upstream.

## Won't-do (explicit non-goals)

- **Custom transport beyond stdio**: WebSocket / Unix-socket transports add
  complexity without clear demand. stdio works for every editor in the
  registry today.
- **MCP server hot-reload**: if the user wants different MCP servers, they
  can `session/cancel` + `session/new`. Hot-reload during a live session
  would compromise the typed session model.

## Conventions

- Each shipped item updates `docs/ACP.md`'s methods table + tests section.
- Each shipped item adds a CHANGELOG entry under `[Unreleased]`.
- Each shipped item updates this backlog by deleting its section (don't move
  to a "shipped" section here — the CHANGELOG is the source of truth).
