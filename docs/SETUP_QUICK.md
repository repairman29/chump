# Quick setup (Ollama + Discord + autonomy)

One-time setup for running Chump locally with Ollama, optional Discord, and autonomy tests.

## 1. Run the setup script

From the Chump repo root (`~/Projects/Chump`):

```bash
./scripts/setup-local.sh
# or if permission denied:
bash ./scripts/setup-local.sh
```

This creates `.env` from `.env.example` if missing and prints Ollama/Discord/autonomy commands.

## 2. Ollama

```bash
ollama serve
ollama pull qwen2.5:14b
```

Leave `ollama serve` running (or run it in the background). The run scripts use `qwen2.5:14b` by default.

## 3. Discord (optional)

1. In `.env`, set `DISCORD_TOKEN` (Discord Developer Portal → Bot → Reset Token).
2. In the Developer Portal, under Bot → **Privileged Gateway Intents**, enable **Message Content Intent** (required for Chump to read messages).
3. Preflight: `./scripts/check-discord-preflight.sh`
4. Start bot: `./run-discord.sh` or `./run-discord-ollama.sh`

If the bot is broken or doesn't reply, see [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md).

## 4. Autonomy tests (Chump Olympics)

With Ollama running and the model pulled:

```bash
OPENAI_API_BASE=http://localhost:11434/v1 OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:14b ./scripts/run-autonomy-tests.sh
```

Tiers 2 and 3 require `TAVILY_API_KEY` in `.env`; otherwise they are skipped. See [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md).

## 5. ChumpMenu

Build from repo root: `./scripts/build-chump-menu.sh`. The app default repo path is `~/Projects/Chump`; change it in the menu only if your repo lives elsewhere.
