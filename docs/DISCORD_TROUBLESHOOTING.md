# Discord troubleshooting

If the bot won't start, connects but doesn't reply, or only works in DMs, check the following. For a full picture of what's configured, see [DISCORD_CONFIG.md](DISCORD_CONFIG.md).

## 1. Message Content Intent (most common)

Chump needs to read message text. Discord requires the **Message Content Intent** to be enabled for your bot.

1. Open [Discord Developer Portal](https://discord.com/developers/applications) → your application → **Bot**.
2. Under **Privileged Gateway Intents**, turn **Message Content Intent** **ON**.
3. Save. Restart the bot (`./run-discord.sh`).

Without this, the bot may connect but receive empty message content and never reply in servers (DMs can still work in some cases).

## 2. Token and .env

- **DISCORD_TOKEN** must be set in `.env` (or exported). Get it from Developer Portal → Bot → Reset Token.
- No extra prefix: use the token value only (no `DISCORD_TOKEN=` in the token itself).
- If you copied the token with a newline or space, trim it. The code trims the token; ensure the rest of the line is only the token.
- **We do not burn tokens:** all log lines and Discord error messages are redacted (token and other secrets replaced with `[REDACTED]`) before writing to chump.log or stderr.

Run preflight to verify:

```bash
./scripts/check-discord-preflight.sh
# or: bash ./scripts/check-discord-preflight.sh
```

## 3. Only one instance

Multiple processes cause duplicate replies. Stop any existing Chump Discord process before starting:

- ChumpMenu: use **Stop Chump**.
- Or: `pkill -f 'rust-agent.*--discord'`

Then start again with `./run-discord.sh` or `./run-discord-ollama.sh`.

## 4. Model server (Ollama or vLLM)

If the bot connects but **every reply is "Error: error sending request for url (http://localhost:8000/...)"** (or another host:port), the model server at that URL is not running. The bot needs a live inference endpoint.

- **Default (Ollama):** `run-discord.sh` sets `OPENAI_API_BASE=http://localhost:11434/v1`. Start Ollama:
  ```bash
  ollama serve
  ollama pull qwen2.5:14b
  ```
- **vLLM / other:** If your `.env` has `OPENAI_API_BASE=http://localhost:8000/v1` (or another URL), that server must be running. Start it, or switch to Ollama by removing/commenting that line so the default 11434 is used.

Preflight checks Ollama (11434) by default. Set `OPENAI_API_BASE` in `.env` only when you use another server; ensure that server is running.

## 5. “No such file or directory (os error 2)” / “path not found or not accessible”

The error message now includes **which path** was tried and the **repo root** (e.g. `tried "docs/foo.md" (repo root: /Users/you/Projects/Chump)`). Use that to fix it.

- **Repo root wrong or missing:** Ensure `CHUMP_REPO` or `CHUMP_HOME` in `.env` points to a directory that exists and is readable (e.g. `/Users/you/Projects/Chump`). No trailing slash. If you use ChumpMenu, set **Chump repo path** to that same path.
- **File doesn’t exist:** The path Chump tried to read isn’t in the repo (typo, wrong path, or file deleted). Check the “tried” path in the error; fix the path or create the file.
- **From Terminal:** Start from the Chump repo root: `cd ~/Projects/Chump` then `./run-discord.sh`. The script sets `CHUMP_HOME` and sources `.env`.

## 6. Build and path

- From repo root: `cargo build --release` then `./run-discord.sh`. The script runs `cargo run -- --discord` if there is no release binary.
- If you use ChumpMenu, set the Chump repo path to the directory that contains `Cargo.toml` and `run-discord.sh` (e.g. `~/Projects/Chump`). Wrong path → "binary not found" or "run-discord.sh not found".

## Errors in the reply ("Error: ..." in Discord)

When the bot sends a message that starts with **"Error: ..."**, the agent or model call failed. The full error is now logged so you can see the cause.

**Where to look**

1. **`logs/chump.log`** (in the Chump repo) — Look for lines with `error_response` and the full error text (secrets are redacted). Same `request_id` as the message/reply lines so you can match the turn.
2. **`logs/discord.log`** — Stdout/stderr of `run-discord.sh`; may show panics or connection errors.

**Common causes**

- **Ollama not running or unreachable** — e.g. "connection refused", "timed out". Start Ollama: `ollama serve` and ensure `ollama pull qwen2.5:14b` has been run.
- **Wrong model name** — If you set `OPENAI_MODEL` in `.env`, it must match a model your server exposes (e.g. `qwen2.5:14b` for Ollama).
- **Circuit breaker** — After several transient failures the client stops calling the model for 30s; wait or restart the bot.
- **Tool or session failure** — e.g. "No such file or directory" for sessions: ensure `CHUMP_HOME` is set (run scripts set it) or you started from the repo root; see the "No such file or directory" section above.
- **Rate limit / capacity** — If you set `CHUMP_RATE_LIMIT_TURNS_PER_MIN` or `CHUMP_MAX_CONCURRENT_TURNS`, the bot may reply with a short message instead of running the agent; those are not logged as `error_response`.

After fixing the cause, try again in Discord; no need to restart the bot unless you changed `.env` or the model server.

## Quick checklist

1. Developer Portal → Bot → **Message Content Intent** ON.
2. `.env` has `DISCORD_TOKEN=<your-token>` (no quotes unless the token contains spaces).
3. `./scripts/check-discord-preflight.sh` passes.
4. Only one bot process; Ollama (or your model server) is running.
5. Restart the bot after changing .env or intents.
