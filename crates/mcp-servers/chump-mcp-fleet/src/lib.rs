//! # chump-mcp-fleet
//!
//! **MCP server: Chump fleet OS over stdio / Unix socket.**
//!
//! Exposes 5 tools so any Claude instance (or other MCP-compatible client)
//! gets the fleet OS without learning shell:
//!
//! | Tool | What it wraps |
//! |---|---|
//! | `mcp__chump_fleet__inbox_drain` | read `.chump-locks/inbox/<session>.jsonl` since cursor |
//! | `mcp__chump_fleet__broadcast` | `scripts/coord/broadcast.sh FEEDBACK <kind> ...` |
//! | `mcp__chump_fleet__vote` | `chump vote <corr_id> <vote> --reason <reason>` |
//! | `mcp__chump_fleet__consensus_status` | `chump consensus-tally [--corr-id X] [--all]` |
//! | `mcp__chump_fleet__capabilities` | NATS KV `chump_capabilities` → offline: glob `.chump-locks/.curator-opus-*.lock` |
//!
//! ## Feature flag
//!
//! Set `CHUMP_FLEET_WIRE_V1=1` before starting the server. If unset the
//! binary exits 0 with an informational message so callers that don't need
//! the server don't need to gate on it.
//!
//! ## Transport
//!
//! - **stdio** (default): used for Claude Code `mcpServers` launch.
//! - **Unix socket** at `/tmp/chump-mcp-fleet.sock` (or `CHUMP_FLEET_SOCK`):
//!   used by daemonised callers. Pass `--socket` flag or set
//!   `CHUMP_FLEET_TRANSPORT=socket`.

pub mod server;
pub mod tools;
