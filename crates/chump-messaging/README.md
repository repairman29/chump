# chump-messaging

Platform-agnostic messaging trait for LLM agents. Define one `MessagingAdapter` impl per platform (Telegram, Slack, Matrix, Discord, IRC, your own) and the agent loop talks to all of them through the same contract.

Capabilities are carried as **fields on `IncomingMessage` / `OutgoingMessage`** rather than per-platform enums, so adapters with weaker features just leave fields empty (e.g. an IRC adapter sets `attachments = vec![]` and `thread_id = None` — the agent loop already handles that case).

## Why a separate crate

If you're building an agent that needs multi-platform reach, you don't want to copy ~1400 lines of platform-specific glue per platform and let them diverge. The `MessagingAdapter` trait is the contract — implement it once per platform, plug all of them into the same router (`MessagingHub`).

The trait is async-first (`async fn` via `async-trait`), platform-agnostic, and has zero opinions about how the agent loop is structured underneath.

## Install

```bash
cargo add chump-messaging
```

## Use

```rust
use chump_messaging::{MessagingAdapter, IncomingMessage, OutgoingMessage};
use async_trait::async_trait;

pub struct MyTelegramAdapter { /* ... */ }

#[async_trait]
impl MessagingAdapter for MyTelegramAdapter {
    async fn start(&self) -> anyhow::Result<()> { /* spin up bot loop */ }
    async fn send_reply(&self, channel: &str, text: &str) -> anyhow::Result<()> { /* ... */ }
    async fn send_dm(&self, user: &str, text: &str) -> anyhow::Result<()> { /* ... */ }
    async fn request_approval(&self, user: &str, prompt: &str) -> anyhow::Result<bool> { /* ... */ }
}
```

## Core types

| symbol | what |
|--------|------|
| `MessagingAdapter` | the contract; 4 async methods (start / send_reply / send_dm / request_approval) |
| `IncomingMessage` | platform-agnostic user-sent message (text, channel_id, user_id, dm flag, attachments, thread context) |
| `OutgoingMessage` | the agent's reply (text, optional attachments, optional thread_id) |
| `ApprovalResponse` | yes / no / timeout result from `request_approval` |
| `MessagingHub` | dispatches incoming events from N adapters into a single agent loop, routes outgoing replies back by channel_id prefix |

## Channel-id namespacing convention

To route a reply back to the right adapter, channel ids are prefixed by platform:
- `telegram:<chat_id>`
- `slack:<channel_id>`
- `discord:<channel_id>`
- `web:<session_id>`

`MessagingHub::send_reply()` strips the prefix and dispatches to the matching adapter.

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo, where it powers the Telegram + Discord + PWA adapters via `chump --serve` / `chump --discord` / `chump --telegram`)

## License

MIT.

## Companion crates

- [`chump-agent-lease`](https://crates.io/crates/chump-agent-lease) — multi-agent file-coordination leases
- [`chump-cancel-registry`](https://crates.io/crates/chump-cancel-registry) — request-id-keyed CancellationToken store
- [`chump-belief-state`](https://crates.io/crates/chump-belief-state) — Bayesian per-tool reliability beliefs
- [`chump-cost-tracker`](https://crates.io/crates/chump-cost-tracker) — per-provider call/token + budget warnings
- [`chump-perception`](https://crates.io/crates/chump-perception) — rule-based perception layer
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — per-session MCP server lifecycle
- [`chump-tool-macro`](https://crates.io/crates/chump-tool-macro) — proc macro for declaring agent tools
