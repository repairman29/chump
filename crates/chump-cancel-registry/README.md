# chump-cancel-registry

Tiny global registry of per-request [`CancellationToken`](https://docs.rs/tokio-util/latest/tokio_util/sync/struct.CancellationToken.html) handles, keyed by string id.

The use case: a web/LLM agent server starts each user turn with a `request_id`. The turn handler creates a `CancellationToken`, registers it under that id, and threads the token through the async work. A separate `/api/stop?request_id=...` endpoint can then call `cancel(id)` to fire the token from anywhere.

## Why a separate crate

This is the lookup table side of cancellation — it pairs with `tokio_util::sync::CancellationToken` (which provides the actual cancel signal). The two are intentionally split: the token is created and consumed at the call site, this crate just holds the shared map. ~50 lines of code.

## Install

```bash
cargo add chump-cancel-registry
```

## Use

```rust
use chump_cancel_registry::{create_and_register, unregister, cancel};

async fn handle_turn(request_id: &str) {
    let token = create_and_register(request_id);
    let _guard = scopeguard::guard((), |_| unregister(request_id));

    tokio::select! {
        _ = token.cancelled() => { /* user hit /api/stop */ }
        result = do_work() => { /* normal completion */ }
    }
}

// elsewhere — e.g. an HTTP handler
fn handle_stop(request_id: &str) -> StatusCode {
    if cancel(request_id) {
        StatusCode::OK
    } else {
        StatusCode::NOT_FOUND
    }
}
```

## API

| fn | what |
|----|------|
| `register(id, token)` | store the token under `id` (replaces any prior token at that id) |
| `create_and_register(id) -> CancellationToken` | shortcut: create a fresh token, register it, return it |
| `cancel(id) -> bool` | fire the token at `id`; returns `false` if no entry |
| `unregister(id)` | remove the entry (call when the turn finishes or is cancelled) |

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo, where it powers per-request cancel for `chump --serve` web turns and mid-turn interrupt via `NewMessageSensor`)

## License

MIT.

## Companion crates

- [`chump-agent-lease`](https://crates.io/crates/chump-agent-lease) — multi-agent file-coordination leases
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — per-session MCP server lifecycle
- [`chump-tool-macro`](https://crates.io/crates/chump-tool-macro) — proc macro for declaring agent tools
