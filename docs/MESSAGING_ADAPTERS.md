# Messaging Platform Adapters

Hermes Phase 1.5. Chump's core agent loop is platform-agnostic; messaging
platforms plug in through the `PlatformAdapter` trait in `src/adapters/mod.rs`.

## Architecture

```
                    +-----------------------+
                    |   Core Agent Loop     |
                    |  (turns, tools, mem)  |
                    +-----------+-----------+
                                |
                       PlatformAdapter (trait)
                                |
        +-----------+-----------+-----------+-------------+
        |           |           |           |             |
   discord.rs   telegram     matrix       slack         ...future
   (legacy,    (V1: send-    (planned)   (planned)
    not yet     only)
    migrated)
```

One agent core, many adapters. Each adapter normalizes inbound platform
events into `InboundMessage` and sends `OutboundMessage` back out.

## Current state

| Adapter  | Status                            | Module                  |
|----------|-----------------------------------|-------------------------|
| Discord  | Legacy full implementation        | `src/discord.rs`        |
| Telegram | V1 send-only over Bot HTTP API    | `src/adapters/telegram.rs` |
| Matrix   | Planned                           | —                       |
| Slack    | Live — Socket Mode (COMP-004c)    | `src/slack.rs`          |

The Discord adapter predates this trait and is **not** migrated; it remains
the reference of a fully wired adapter. New platforms implement
`PlatformAdapter` directly.

## Configuration

Each adapter has an enable flag and a token. The enable flag follows the
pattern `CHUMP_<NAME>_ENABLED=1`; the token is platform-specific.

| Adapter  | Enable flag                  | Credentials               |
|----------|------------------------------|---------------------------|
| Telegram | `CHUMP_TELEGRAM_ENABLED=1`   | `TELEGRAM_BOT_TOKEN`      |
| Slack    | `chump --slack` (CLI flag)   | `SLACK_APP_TOKEN` (xapp-…) + `SLACK_BOT_TOKEN` (xoxb-…) |

Adapters that are enabled but fail to construct (missing token, etc.) are
logged and skipped — they don't crash startup.

## Adding a new adapter

1. Create `src/adapters/<name>.rs`.
2. Define a struct holding any client/credentials it needs.
3. `impl PlatformAdapter for YourAdapter` — implement `name`, `start`,
   `send`, and `request_approval`.
4. Add a constructor (e.g. `from_env`) that reads its credentials.
5. Wire it into `available_adapters()` in `src/adapters/mod.rs` behind
   `adapter_enabled("<name>")`.
6. Document the env vars in this file.
7. Add tests for construction and trait object-safety.

## Telegram V1 details

V1 is **send-only**. Outbound messages POST to
`https://api.telegram.org/bot<token>/sendMessage` via `reqwest`. No new
crate dependency was added for V1. Long-poll / webhook intake (V2) will
gate richer behavior behind the `telegram` cargo feature.

`request_approval` synthesizes a human prompt and sends it; correlating
the reply back to the request id requires inbound polling, which lands
with V2.

## Slack Socket Mode details

Start with `chump --slack`. Uses a persistent WebSocket connection — no
public URL or webhook endpoint needed. Two tokens are required:

- `SLACK_APP_TOKEN` (xapp-…) — Socket Mode token; grants the WSS URL.
- `SLACK_BOT_TOKEN` (xoxb-…) — Bot OAuth token; used for `chat.postMessage` and other REST calls.

**What's live:** message events + app_mention, replies via `chat.postMessage`, thread replies using
`thread_ts`, DMs, auto-reconnect with exponential back-off (ceiling 60s).
Messages over 2990 chars are truncated to fit Slack's text field limit.

**What's deferred (V2):** Block Kit interactive approval buttons, multi-workspace installs,
slash command payloads, file attachment upload.

Override `SLACK_API_BASE` for local testing (default `https://slack.com/api`).
