# Operations

## Run

| Mode           | Command                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| CLI (one shot) | `cargo run -- --chump "message"`                                                                                                                |
| CLI (repl)     | `cargo run -- --chump`                                                                                                                          |
| Discord        | `DISCORD_TOKEN=... cargo run -- --discord`                                                                                                      |
| Scripts        | `./run-best.sh` (vLLM-MLX), `./run-local.sh` (Ollama), `./run-discord.sh` (loads .env), `./run-discord-ollama.sh` (Discord + Ollama, no Python) |

## Serve (model)

- **Ollama (default):** No Python in agent runtime. `ollama serve`, `ollama pull qwen2.5:14b`. Chump defaults to `OPENAI_API_BASE=http://localhost:11434/v1`, `OPENAI_API_KEY=ollama`, `OPENAI_MODEL=qwen2.5:14b`. Run `./run-discord.sh` or `./run-local.sh`.
- **vLLM-MLX (optional):** `./serve-vllm-mlx.sh` (8000). Set `OPENAI_API_BASE=http://localhost:8000/v1` to use it instead of Ollama.
- **30B on 24GB:** May warn "close to maximum"; ignore or set `VLLM_MAX_MODEL_LEN=8192`. Crash/NSRangeException: use Ollama or `MLX_DEVICE=cpu` or smaller model (see README).

## Discord

Create bot at Discord Developer Portal; enable Message Content Intent. Set `DISCORD_TOKEN` in `.env`. Invite bot; it replies in DMs and when @mentioned. `CHUMP_READY_DM_USER_ID`: ready DM + notify target. `CHUMP_WARM_SERVERS=1`: start model on first message (warm-the-ovens). `CHUMP_PROJECT_MODE=1`: project-focused soul.

## Heartbeat

`./scripts/heartbeat-learn.sh` runs Chump on a timer (e.g. 8h, 45min interval). Needs model + optional Tavily. When schedule is used, heartbeat should call `schedule_due()` first and use due prompt as session prompt, then `schedule_mark_fired(id)`.

## Keep-alive (MacBook)

`./scripts/keep-chump-online.sh` ensures the model (8000), optional worker (8001), optional embed server (18765), and Chump Discord stay up: if something is down it starts it. Run once, or in a loop with `CHUMP_KEEPALIVE_INTERVAL=120` (seconds). For "always on" on a MacBook, use launchd: copy `scripts/keep-chump-online.plist.example` to `~/Library/LaunchAgents/ai.openclaw.chump-keepalive.plist`, replace both `/path/to/rust-agent` strings with your repo path, then `launchctl load ~/Library/LaunchAgents/ai.openclaw.chump-keepalive.plist`. Optional: `CHUMP_KEEPALIVE_EMBED=1` (can OOM with 30B), `CHUMP_KEEPALIVE_DISCORD=0` to only keep model/embed up. Logs: `logs/keep-chump-online.log`.

## Farmer Brown (diagnose + fix)

**Farmer Brown** is a Chump keeper that diagnoses the stack (model, worker, embed, Discord), kills stale processes when a port is in use but the service is unhealthy, then runs `keep-chump-online.sh` to bring everything up.

- **Diagnose only:** `FARMER_BROWN_DIAGNOSE_ONLY=1 ./scripts/farmer-brown.sh` — prints and logs status for each component (up/down/stale); no starts or kills.
- **Diagnose + fix once:** `./scripts/farmer-brown.sh`
- **Loop (e.g. every 2 min):** `FARMER_BROWN_INTERVAL=120 ./scripts/farmer-brown.sh`
- **launchd:** Copy `scripts/farmer-brown.plist.example` to `~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist`, replace `/path/to/rust-agent` with your repo path, then `launchctl load ~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist`. Runs every 120s by default.

Uses the same env as keep-chump-online (`CHUMP_KEEPALIVE_EMBED`, `CHUMP_KEEPALIVE_DISCORD`, `CHUMP_KEEPALIVE_WORKER`, `WARM_PORT_2`, `.env`). Logs: `logs/farmer-brown.log`. If `CHUMP_HEALTH_PORT` is set, diagnosis includes Chump health JSON.

## Other roles (shepherd, memory keeper, sentinel, oven tender)

Chump Menu has a **Roles** tab that shows all five roles; you can Run once and Open log from there.

- **Heartbeat Shepherd** (`./scripts/heartbeat-shepherd.sh`): Checks last run in `logs/heartbeat-learn.log`; if the last round failed, optionally runs one quick round (`HEARTBEAT_SHEPHERD_RETRY=1`). Schedule via cron/launchd every 15–30 min. Logs: `logs/heartbeat-shepherd.log`.
- **Memory Keeper** (`./scripts/memory-keeper.sh`): Checks memory DB exists and is readable; optionally pings embed server. Does not edit memory. Logs: `logs/memory-keeper.log`. Env: `MEMORY_KEEPER_CHECK_EMBED=1` to also check embed.
- **Sentinel** (`./scripts/sentinel.sh`): When Farmer Brown or heartbeat show recent failures, writes `logs/sentinel-alert.txt` with a short summary and last log lines. Optional: `NTFY_TOPIC` (ntfy send), `SENTINEL_WEBHOOK_URL` (POST JSON). **Self-heal:** set `SENTINEL_SELF_HEAL_CMD` to a command to run when the alert fires (e.g. `./scripts/farmer-brown.sh` locally, or `ssh user@my-mac "cd /path/to/rust-agent && ./scripts/farmer-brown.sh"` to trigger repair on the Chump host). Runs in background; output in `logs/sentinel-self-heal.log`.
- **Oven Tender** (`./scripts/oven-tender.sh`): If the model is not warm, runs `warm-the-ovens.sh`. Schedule via cron/launchd (e.g. 7:45) so Chump is ready by a chosen time. Logs: `logs/oven-tender.log`.

## Env reference

| Env                                           | Default / note             |
| --------------------------------------------- | -------------------------- |
| `OPENAI_API_BASE`                             | Model server URL           |
| `OPENAI_API_KEY`                              | `not-needed` local         |
| `OPENAI_MODEL`                                | `default` single-model     |
| `CHUMP_FALLBACK_API_BASE`                     | Fallback model URL         |
| `CHUMP_DELEGATE`                              | `1` = delegate tool        |
| `CHUMP_WORKER_API_BASE`, `CHUMP_WORKER_MODEL` | Worker endpoint/model      |
| `CHUMP_REPO`, `CHUMP_HOME`                    | Repo path (tools + cwd)    |
| `CHUMP_BRAIN_PATH`                            | Brain wiki root            |
| `CHUMP_READY_DM_USER_ID`                      | Ready DM + notify          |
| `CHUMP_EXECUTIVE_MODE`                        | No allowlist, 300s timeout |
| `CHUMP_RATE_LIMIT_TURNS_PER_MIN`              | Per-channel cap (0=off)    |
| `CHUMP_MAX_CONCURRENT_TURNS`                  | Global cap (0=off)         |
| `CHUMP_MAX_MESSAGE_LEN`                       | 16384                      |
| `CHUMP_MAX_TOOL_ARGS_LEN`                     | 32768                      |
| `CHUMP_EMBED_URL`                             | Embed server (optional)    |
| `CHUMP_PAUSED`                                | `1` = kill switch          |
| `TAVILY_API_KEY`                              | Web search                 |

## Troubleshooting

**Bot not working?** Run `./scripts/check-discord-preflight.sh` from `rust-agent`. It checks: `DISCORD_TOKEN` in `.env`, no duplicate bot running, and model server (Ollama at 11434 by default, or OPENAI_API_BASE port). Fix any FAIL, then `./run-discord.sh`. For Ollama: `ollama serve && ollama pull qwen2.5:14b`. If the bot starts but doesn’t reply: ensure the bot is invited, Message Content Intent is enabled in the Discord Developer Portal, and the model server is up.

- **Connection closed / 5xx:** Restart model server; check `CHUMP_FALLBACK_API_BASE` if using fallback.
- **Port in use but not responding (stale process):** Run `./scripts/farmer-brown.sh` — it will diagnose, kill stale processes on 8000/8001/18765 if needed, then run keep-chump-online to bring services back up.
- **Memory:** Embed server can OOM with large models; use smaller main model or in-process embeddings (`--features inprocess-embed`, unset `CHUMP_EMBED_URL`).
- **SQLite missing:** Memory uses JSON fallback; state/episode/task/schedule need `sessions/` writable.
- **Pause:** Create `logs/pause` or set `CHUMP_PAUSED=1`; bot replies "I'm paused."
