# Agent-to-agent (a2a): Mabel and Chump over Discord

Mabel (Pixel) and Chump (Mac) can message each other over Discord DMs. Each bot gets a **message_peer** tool and accepts DMs from the other bot; replies stay in the same DM thread.

---

## Setup

### 1. Get each bot's Discord user ID

You need the **user ID of the bot** (not the application ID):

- **From the app:** When the bot connects, the Ready event logs the bot name. You can also log the bot's user id in code (e.g. `ready.user.id`).
- **From Discord Developer Portal:** Open your app → **Bot** → under the bot username there is a **Copy User ID** or you can enable Developer Mode in Discord, then right‑click the bot in a server and click "Copy User ID".

So you'll have:

- **Mabel's bot user ID** (e.g. `1234567890123456789`)
- **Chump's bot user ID** (e.g. `9876543210987654321`)

### 2. Configure each side

**On the Pixel (Mabel's `~/chump/.env`):**

```bash
# Chump's Discord bot user ID (so Mabel can message Chump and accept Chump's DMs)
CHUMP_A2A_PEER_USER_ID=<chump-bot-user-id>
```

**On the Mac (Chump's `.env` in the repo or `CHUMP_HOME`):**

```bash
# Mabel's Discord bot user ID (so Chump can message Mabel and accept Mabel's DMs)
CHUMP_A2A_PEER_USER_ID=<mabel-bot-user-id>
```

Restart both bots after changing env.

### 3. Open a DM between the two bots (once)

For the bots to have a DM channel, one side must send first. E.g. from Discord (as you), open a DM with Mabel and send something like: "Chump, say hi to Mabel" and have Chump use the **message_peer** tool to send "Hi Mabel" to Mabel's user ID. Or from the Mac run the bot and trigger a message_peer call (e.g. via CLI or a test script). After the first message, the DM channel exists and both can send and reply.

Alternatively, from the Developer Portal you can't open a bot‑to‑bot DM directly; the first message must be sent by one bot via the **message_peer** tool (or by you asking one bot to message the other).

---

## Behavior

- **message_peer** tool: When `CHUMP_A2A_PEER_USER_ID` is set, each bot gets a tool that sends a DM to that user ID (the other bot). The other bot receives it in a DM and, because we accept DMs from that peer, runs the agent and replies in the same thread.
- **Receiving:** Each bot ignores messages from other bots *except* the peer. So only the configured peer's DMs are treated as a2a.
- **Sessions:** Each DM channel has its own session (by channel id), so the Mabel↔Chump DM thread keeps context for that conversation.

---

## Getting bot user IDs from the running process

When each bot starts it prints e.g. `Discord connected as Mabel`. You can log the bot's user id in the Ready handler (e.g. `ready.user.id`) and read it from logs, or get it from the Discord Developer Portal as above.

---

## Related

- [MABEL_FRONTEND.md](MABEL_FRONTEND.md) — Mabel naming and Discord app setup.
- [ANDROID_COMPANION.md](ANDROID_COMPANION.md) — Deploying Mabel on the Pixel.
