# Operations

## Run

| Mode           | Command                                                                                |
| -------------- | -------------------------------------------------------------------------------------- |
| CLI (one shot) | `cargo run -- --chump "message"`                                                       |
| CLI (repl)     | `cargo run -- --chump`                                                                 |
| Discord        | `DISCORD_TOKEN=... cargo run -- --discord`                                             |
| Scripts        | `./run-best.sh` (vLLM-MLX), `./run-local.sh` (Ollama), `./run-discord.sh` (loads .env) |

## Serve (model)

- **vLLM-MLX:** `./serve-vllm-mlx.sh` (default 30B 4-bit on 8000). Optional 8001 for worker: `WARM_PORT_2=8001`. Lower memory: `VLLM_MAX_MODEL_LEN=8192` or `VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit`.
- **Ollama:** `ollama serve`, `ollama pull qwen2.5:7b`; set `OPENAI_API_BASE=http://localhost:11434/v1`.
- **30B on 24GB:** May warn "close to maximum"; ignore or set `VLLM_MAX_MODEL_LEN=8192`. Crash/NSRangeException: use Ollama or `MLX_DEVICE=cpu` or smaller model (see README).

## Discord

Create bot at Discord Developer Portal; enable Message Content Intent. Set `DISCORD_TOKEN` in `.env`. Invite bot; it replies in DMs and when @mentioned. `CHUMP_READY_DM_USER_ID`: ready DM + notify target. `CHUMP_WARM_SERVERS=1`: start model on first message (warm-the-ovens). `CHUMP_PROJECT_MODE=1`: project-focused soul.

## Heartbeat

`./scripts/heartbeat-learn.sh` runs Chump on a timer (e.g. 8h, 45min interval). Needs model + optional Tavily. When schedule is used, heartbeat should call `schedule_due()` first and use due prompt as session prompt, then `schedule_mark_fired(id)`.

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

- **Connection closed / 5xx:** Restart model server; check `CHUMP_FALLBACK_API_BASE` if using fallback.
- **Memory:** Embed server can OOM with large models; use smaller main model or in-process embeddings (`--features inprocess-embed`, unset `CHUMP_EMBED_URL`).
- **SQLite missing:** Memory uses JSON fallback; state/episode/task/schedule need `sessions/` writable.
- **Pause:** Create `logs/pause` or set `CHUMP_PAUSED=1`; bot replies "I'm paused."
