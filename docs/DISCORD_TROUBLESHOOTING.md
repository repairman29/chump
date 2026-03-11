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

## 4. Model server (Ollama)

If the bot connects but replies fail or time out, the model server may be down. Default is Ollama:

```bash
ollama serve
ollama pull qwen2.5:14b
```

Preflight checks Ollama when `OPENAI_API_BASE` points to 11434. If you use another server (e.g. vLLM on 8000), set it in `.env` and ensure that server is running.

## 5. “No such file or directory (os error 2)”

This usually means the process is running with the wrong working directory, so paths like `./sessions` or `./.env` don’t exist.

- **From Terminal:** Always start from the Chump repo root: `cd ~/Projects/Chump` then `./run-discord.sh`. The script sets `CHUMP_HOME` and changes into the repo directory.
- **From ChumpMenu:** Set **Chump repo path** to the real repo (e.g. `~/Projects/Chump`). The app sets `CHUMP_HOME` and the process working directory to that path; if the path is wrong or missing, you can get this error.
- The code uses `CHUMP_HOME` (or `CHUMP_REPO`) when set for sessions and logs, so the repo directory must exist and be readable.

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
