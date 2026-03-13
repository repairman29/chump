# Agent-to-agent (a2a): Mabel and Chump over Discord

Mabel (Pixel) and Chump (Mac) can message each other over Discord. Each bot gets a **message_peer** tool and accepts messages from the other bot. You can use either **DMs** or a **server channel** so you can follow along.

---

## Option A: Server channel (recommended so you can follow along)

Set **CHUMP_A2A_CHANNEL_ID** to a channel in a server where both bots are members. All a2a messages and replies go there.

1. Create a channel in your server (e.g. `#mabel-chump` or `#bot-talk`).
2. Invite both Mabel and Chump to the server if they aren’t already. Give them **Send Messages** (and Read Message History) in that channel.
3. Right‑click the channel → **Copy Channel ID** (Developer Mode must be on in Discord: Settings → App Settings → Advanced → Developer Mode).
4. Set the same channel ID on **both** bots.

**On the Pixel (Mabel's `~/chump/.env`):**

```bash
CHUMP_A2A_PEER_USER_ID=<chump-bot-user-id>
CHUMP_A2A_CHANNEL_ID=<your-server-channel-id>
```

**On the Mac (Chump's `.env`):**

```bash
CHUMP_A2A_PEER_USER_ID=<mabel-bot-user-id>
CHUMP_A2A_CHANNEL_ID=<your-server-channel-id>
```

Restart both bots. In that channel, either bot can use **message_peer** to send a message; the other bot sees it and replies in the same channel so you can follow the conversation.

---

## Option B: DMs (private)

If you do **not** set `CHUMP_A2A_CHANNEL_ID`, a2a uses DMs: **message_peer** sends a DM to the other bot and replies stay in that DM thread.

### 1. Get each bot's Discord user ID

- When the bot connects, the log line includes the user id: `Discord connected as Mabel (user id: 1234567890123456789; ...)`.
- Or in Discord: enable Developer Mode, then right‑click the bot in a server → **Copy User ID**.

You need **Mabel's bot user ID** and **Chump's bot user ID**.

### 2. Configure each side (DM-only)

**On the Pixel (Mabel's `~/chump/.env`):**  
`CHUMP_A2A_PEER_USER_ID=<chump-bot-user-id>`

**On the Mac (Chump's `.env`):**  
`CHUMP_A2A_PEER_USER_ID=<mabel-bot-user-id>`

Restart both bots. The first time one bot uses **message_peer**, it creates the DM with the other; after that they can reply in that thread.

---

## Shared goals and roles

When a2a is configured (`CHUMP_A2A_PEER_USER_ID` set), the runtime injects a **Team (a2a)** block into each bot’s system prompt so they are aware of each other and of shared goals:

- **Mabel** (Pixel): Keeps things running—farm monitor, ops—and can do more. She coordinates with Chump via **message_peer** when it helps.
- **Chump** (Mac): Improves the stack—code, tools, docs. He coordinates with Mabel via **message_peer** when it helps.

Both share common goals and priorities; more nodes will be added for the team to call or use. This avoids generic “who are you?” replies and keeps a2a conversations task-focused.

---

## Behavior

- **message_peer** tool: When `CHUMP_A2A_PEER_USER_ID` is set, each bot can send to the other. If **CHUMP_A2A_CHANNEL_ID** is set, messages go to that server channel; otherwise they go by DM.
- **Receiving:** Each bot ignores other bots except the peer. In a guild, it only responds in the a2a channel when the message author is the peer (or when the bot is @mentioned as usual).
- **Sessions:** Session is per channel, so the a2a channel (or the DM thread) keeps context.

---

## Getting channel and bot user IDs

- **Channel ID:** In Discord, enable Developer Mode (Settings → App Settings → Advanced). Right‑click the channel → **Copy Channel ID**.
- **Bot user ID:** When each bot starts it prints e.g. `Discord connected as Mabel (user id: 1234567890123456789; ...)`. Or right‑click the bot in the server → **Copy User ID**.

---

## Related

- [MABEL_FRONTEND.md](MABEL_FRONTEND.md) — Mabel naming and Discord app setup.
- [ANDROID_COMPANION.md](ANDROID_COMPANION.md) — Deploying Mabel on the Pixel.
