---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Optional Chat Platform Adapters

Chump's core coordinator (`chump claim`, `chump hook`, `chump ship`, `chumpd`) and local surfaces (`chump --once`, `chump --web`, `chump --acp`) require **no chat account or bot token**.

For teams who also want mobile/chat notifications or remote tool-approval prompts, Chump includes optional adapters in `src/adapters/`, `src/slack.rs`, and `src/discord.rs`. Unconfigured adapters stay completely dormant and never block CLI or Web Cockpit startup.

---

## 1. Adapter Overview

```
                     +----------------------------+
                     |    Core Governed Agent     |
                     | (turns, tools, approvals)  |
                     +-------------+--------------+
                                   |
                          PlatformAdapter / Bot
                                   |
            +----------------------+----------------------+
            |                      |                      |
      Slack Socket Mode     Telegram Bot HTTP        Discord Bot
      (chump --slack)     (CHUMP_TELEGRAM_ENABLED) (chump --discord)
```

| Adapter | Launch / Enable | Required Environment Variables | Capabilities |
|---------|-----------------|--------------------------------|--------------|
| **Slack** | `chump --slack` | `SLACK_APP_TOKEN` (`xapp-...`) + `SLACK_BOT_TOKEN` (`xoxb-...`) | Outbound WebSocket (Socket Mode—no public webhook URL needed), mentions, DMs, `thread_ts` replies, auto-reconnect |
| **Telegram** | `CHUMP_TELEGRAM_ENABLED=1` | `TELEGRAM_BOT_TOKEN` | Outbound Bot HTTP notifications (`sendMessage`) and approval alerts |
| **Discord** | `chump --discord` | `DISCORD_TOKEN` | Optional bot gateway (`--discord` flag required), DM / channel replies, and button-based tool approval prompts |

---

## 2. Slack Socket Mode Setup (`chump --slack`)

Slack Socket Mode connects outbound over TLS WebSockets, so your workstation or server does not need a public IP or inbound firewall port:

1. Create a Slack App with **Socket Mode** enabled (`SLACK_APP_TOKEN`, `xapp-...`).
2. Grant `app_mentions:read`, `chat:write`, and `im:history` bot scopes (`SLACK_BOT_TOKEN`, `xoxb-...`).
3. Start the adapter:
   ```bash
   SLACK_APP_TOKEN=xapp-... SLACK_BOT_TOKEN=xoxb-... chump --slack
   ```

*(Optional: set `SLACK_API_BASE` when testing against a local mock server.)*

---

## 3. Telegram Notifications (`CHUMP_TELEGRAM_ENABLED=1`)

Enable lightweight outbound notifications over the Telegram Bot HTTP API:

```bash
export CHUMP_TELEGRAM_ENABLED=1
export TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrSTUvwxYZ
```

---

## 4. Discord Bot Mode (`chump --discord`)

When explicitly launched with `chump --discord`:

```bash
DISCORD_TOKEN=<your-discord-bot-token> chump --discord
```

If `DISCORD_TOKEN` is unset during normal CLI, ACP, or `chump --web` usage, Discord remains disabled silently with zero warnings.

---

## 5. Implementing a Custom `PlatformAdapter`

1. Create `src/adapters/<platform>.rs` implementing `PlatformAdapter` (`name`, `start`, `send`, `request_approval`).
2. Read credentials from environment variables without panicking when unset.
3. Register the adapter behind `adapter_enabled("<platform>")` in `src/adapters/mod.rs` and add unit tests for message formatting and trait object safety.

---

## Related Guides

- [System Architecture](ARCHITECTURE.md)
- [Editor Integration (ACP)](ACP.md)
- [Web Cockpit (`/v2/`)](../PWA_USER_GUIDE.md)
