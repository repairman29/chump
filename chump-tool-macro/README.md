# chump-tool-macro

Procedural macro for declaring agent tools. Derives the `name`, `description`, and JSON `input_schema` from a struct and a few attributes, so a tool implementation looks like:

```rust
use chump_tool_macro::tool;

#[tool(
    name = "echo",
    description = "Echo the provided message back unchanged."
)]
pub struct EchoTool {
    /// The text to echo.
    pub message: String,
}
```

The macro emits the boilerplate that an LLM-facing tool-calling runtime needs (name, description, input schema, deserialization), so handler code only has to define the actual `execute` body.

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo)
- API is intentionally minimal; richer attributes (constraints, enums, examples) tracked as follow-up

## License

MIT.

## Companion crates

- [`chump-agent-lease`](https://crates.io/crates/chump-agent-lease) — multi-agent file-coordination leases
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — per-session MCP server lifecycle
- [`chump-mcp-github`](https://crates.io/crates/chump-mcp-github) / [`chump-mcp-tavily`](https://crates.io/crates/chump-mcp-tavily) / [`chump-mcp-adb`](https://crates.io/crates/chump-mcp-adb) — concrete MCP server implementations
