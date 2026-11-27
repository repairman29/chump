---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Agent Client Protocol (ACP) Integration

[Agent Client Protocol (ACP)](https://agentclientprotocol.com) is the open JSON-RPC standard from Zed Industries and JetBrains for editor-to-coding-agent communication. Chump implements ACP natively in Rust (`src/acp.rs` + `src/acp_server.rs`) so you can run your configured Chump model cascade and tools directly inside **Zed**, **JetBrains IDEs**, and any ACP-compatible client.

---

## 1. Quick Start

Launch Chump in ACP stdio mode:

```bash
chump --acp
```

- **`stdin` / `stdout`:** newline-delimited UTF-8 JSON-RPC 2.0 frames only.
- **`stderr`:** structured `tracing` diagnostics (never mixed into `stdout`).

### Example Zed Configuration

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

---

## 2. Supported ACP Methods

| Method | Direction | Capability Summary |
|--------|-----------|--------------------|
| `initialize` | Client → Agent | Advertises `tools`, `streaming`, `modes`, `mcpServers`, and `skills` |
| `authenticate` | Client → Agent | Local stdio trust (`"none"` auth method; model credentials come from `~/.chump/config.toml`) |
| `session/new` | Client → Agent | Creates session and returns modes (`work`, `research`, `light`) + config options |
| `session/load` | Client → Agent | Reattaches to an in-memory or disk-persisted session (`{CHUMP_HOME}/acp_sessions/`) |
| `session/list` | Client → Agent | Cursor-paginated session listing with optional `cwd` and `mode` filters |
| `session/prompt` | Client → Agent | Streams agent turns over `session/update` (`AgentMessageDelta`, `ToolCallStart`, `ToolCallResult`, `Thinking`) |
| `session/set_mode` | Client → Agent | Switches between `work`, `research`, and `light` context profiles mid-session |
| `session/set_config_option` | Client → Agent | Updates advertised runtime session options |
| `session/list_permissions` / `clear_permission` | Client → Agent | Inspects or resets cached `AllowAlways` tool consent decisions |
| `session/cancel` | Client → Agent | Cancels an in-flight turn cleanly |
| `session/request_permission` | Agent → Client | Prompts the editor UI for user consent before write/shell tools (fail-closed on timeout) |
| `fs/read_text_file` / `fs/write_text_file` | Agent → Client | Delegates file I/O through the editor buffer layer when `fs.read` / `fs.write` are declared |
| `terminal/create`, `output`, `wait_for_exit`, `kill`, `release` | Agent → Client | Delegates shell execution to the editor's integrated terminal environment |

---

## 3. Reasoning Streams (`Thinking` Events)

When `CHUMP_THINKING=1` is enabled, model reasoning blocks (`<think>...</think>` or extended thinking tokens) are stripped out of `AgentMessageDelta` text chunks and emitted as structured `Thinking` events on `session/update`:

```json
{ "type": "thinking", "content": "Checking active file leases before editing..." }
```

---

## 4. Session Modes

| Mode | Best For | Context Profile |
|------|----------|-----------------|
| `work` | Multi-file implementation, tests, and refactoring | Full toolset + repository context |
| `research` | Codebase exploration and architecture synthesis | Higher summarization threshold for broad reading |
| `light` | Fast Q&A and small inline edits | Slim prompt and minimal tool overhead |

---

## 5. Verification

Run the 90+ ACP protocol unit tests locally in a source checkout:

```bash
cargo test --bin chump -- acp
```

---

## Related Guides

- [IDE & Terminal Workflows](../process/CHUMP_CURSOR_FLEET.md)
- [System Architecture](ARCHITECTURE.md)
- [Agent Client Protocol Specification](https://agentclientprotocol.com)
