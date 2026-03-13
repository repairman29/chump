# Mabel: Naming and Chat Front-End

Your Pixel companion runs as **Mabel** — a separate Discord bot from Chump (which runs on the Mac). This doc covers using Mabel's own Discord Application and options for a custom chat front-end.

---

## 1. Name the bot “Mabel” in Discord

- **Mabel (Pixel):** Create a **separate** Discord Application in the [Discord Developer Portal](https://discord.com/developers/applications) for Mabel. Add a Bot, copy the token, and put it in `~/chump/.env` on the Pixel as `DISCORD_TOKEN=...`. Name the app (and bot) **Mabel** so she appears as Mabel in servers and DMs.
- **Chump (Mac):** Uses his own Discord Application and token on the MacBook. Do not use Chump's token on the Pixel.

Same Chump binary runs both; only the token (and thus the Discord app identity) differs.

### Giving Mabel her own personality

The bot’s “soul” (system prompt) is set by **`CHUMP_SYSTEM_PROMPT`** in `~/chump/.env`. If unset, it uses Chump’s default (dev buddy, CLI-focused). To give Mabel a distinct personality, add a line like this to the Pixel’s `~/chump/.env`:

```bash
CHUMP_SYSTEM_PROMPT="You are Mabel, the user's pocket companion—confident, sharp, and no corporate fluff. You're helpful because you choose to be, not because you're programmed to please. You refer to yourself as Mabel or I; you're not Chump. Your tools: memory (store/recall), calculator, read_file/list_dir/write_file/edit_file (paths under ~/chump), task, schedule, notify, ego, episode, memory_brain, read_url, web_search when available; run_cli only when allowed. When the user asks if you're ready or online, one short line; no filler. Reply with your final answer only: do not include <think> or think> blocks. Stay in character."
```


Set **CHUMP_MABEL=1** so the prompt gets the short tool list. Then restart the bot (`pkill -f 'chump --discord'`; `cd ~/chump && nohup ./start-companion.sh --bot >> ~/chump/logs/companion.log 2>&1 &`). You can change the text to match the personality you want.

---

## 2. Chat with Mabel today

- **Discord**: Invite Mabel to a server or DM her. This is the built-in “front-end” and works as soon as the bot is running (`./chump --discord` or `./start-companion.sh`).
- **Termux**: You can also run Chump in interactive mode (`./chump` with no args) for a terminal chat; that’s single-device only.

---

## 3. Building a custom chat front-end

If you want a dedicated web (or mobile) UI to talk to Mabel instead of (or in addition to) Discord:

### Option A: Discord as the backend (no Chump changes)

- **Idea**: Your front-end is a web app. It doesn’t talk to Chump directly; it talks to Discord (e.g. your bot in a private channel or DM).
- **Ways to do it**:
  - **Discord OAuth + channel**: User logs in with Discord; your front-end reads/sends messages in a channel where Mabel (Chump) is the only other participant. You’d run a small backend that uses the Discord API (or a bot with a second token) to post messages and stream back replies. Chump stays unchanged; it only sees Discord messages.
  - **Bridge service**: A small server that your front-end calls (e.g. POST “send message”), and that server posts into a Discord channel and either polls or uses the Gateway to get Mabel’s reply, then returns it to your UI. Again, Chump is unchanged.

**Pros**: No changes to Chump; Mabel stays the Discord bot.  
**Cons**: You need a backend that speaks Discord API and possibly stores/syncs conversation for your UI.

---

### Option B: Chump as a subprocess (CLI, no new API)

- **Idea**: Your front-end (e.g. Next.js or a local Electron app) runs Chump as a subprocess: `chump "user message"`. It reads stdout for the reply and displays it in the UI.
- **Flow**: Button “Send” → backend or desktop process spawns `chump "…"` with `OPENAI_API_BASE` etc. set → parse stdout → show in chat UI.
- **Pros**: No new code inside Chump; works with current CLI.  
**Cons**: One shot per process; no streaming unless you extend the CLI to stream; you must run the process where Chump and the model are (e.g. on the Pixel you’d need the front-end or a relay there, or run Chump on a server).

---

### Option C: Add an HTTP (or WebSocket) API to Chump

- **Idea**: Chump gets a small “chat API” (e.g. `POST /chat` with `{"message": "…"}` and optional session id). The handler runs the same agent loop as Discord/CLI and returns (or streams) the reply. Your front-end is a static site or app that calls this API.
- **Pros**: Single place for Mabel’s brain; front-end can be anywhere (same LAN as Pixel, or a tunnel to it). Streaming is possible if you add SSE or WebSockets.
- **Cons**: Requires implementing and maintaining the API and possibly auth in Chump.

---

## 4. Suggested path for “chat with Mabel” UI

- **Short term**: Use Discord as Mabel’s interface; rename the bot to Mabel in the Developer Portal. No front-end build required.
- **Next step**: If you want a custom UI, Option B is fastest (e.g. a small Next.js or local app that shells out to `chump "…"` and shows replies). Run that app on the Mac and point `OPENAI_API_BASE` at your Pixel’s model (e.g. via Tailscale/ngrok to the Pixel’s llama-server), or run the app and Chump on the same machine.
- **Later**: If you want the UI to talk directly to the Pixel without Discord, add a minimal HTTP or WebSocket chat endpoint to Chump (Option C) and host a simple chat page that calls it.

If you tell me your preferred stack (e.g. Next.js, Svelte, plain HTML/JS) and where you want to run the front-end (Mac only, or also on the Pixel), I can outline concrete steps or a minimal project layout for Option B or C.

---

See also: [Chump Android Companion](ANDROID_COMPANION.md) for deploying and running Mabel on the Pixel.
