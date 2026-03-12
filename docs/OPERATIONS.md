# Operations

## Run

All of the following are run **from the Chump repo root** (the directory containing `Cargo.toml` and `run-discord.sh`).

| Mode           | Command                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| CLI (one shot) | `cargo run -- --chump "message"` or `./run-local.sh --chump "message"`                                                                           |
| CLI (repl)     | `cargo run -- --chump` or `./run-local.sh --chump`                                                                                               |
| Discord        | `./run-discord.sh` (loads .env) or `./run-discord-ollama.sh` (Ollama preflight)                                                                  |
| Scripts        | `./run-local.sh` (Ollama), `./run-discord.sh` (loads .env), `./run-discord-ollama.sh` (Discord + Ollama) |

## Serve (model)

- **Ollama (default):** No Python in agent runtime. `ollama serve`, `ollama pull qwen2.5:14b`. Chump defaults to `OPENAI_API_BASE=http://localhost:11434/v1`, `OPENAI_API_KEY=ollama`, `OPENAI_MODEL=qwen2.5:14b`. Run `./run-discord.sh` or `./run-local.sh`. **Speed:** use `./scripts/ollama-serve-fast.sh` or see [OLLAMA_SPEED.md](OLLAMA_SPEED.md).
- **Ollama (default):** `ollama serve` (port 11434). Set `OPENAI_API_BASE=http://localhost:11434/v1` (default in run scripts). Pull a model: `ollama pull qwen2.5:14b`.

## Discord

Create bot at Discord Developer Portal; enable Message Content Intent. Set `DISCORD_TOKEN` in `.env`. Invite bot; it replies in DMs and when @mentioned. `CHUMP_READY_DM_USER_ID`: ready DM + notify target. `CHUMP_WARM_SERVERS=1`: start Ollama on first message (warm-the-ovens). `CHUMP_PROJECT_MODE=1`: project-focused soul.

## Heartbeat

**Two scripts:**

- **heartbeat-learn.sh** — Learning-only: runs Chump on a timer (e.g. 8h, 45min interval) with rotating web-search prompts; stores learnings in memory. Needs model + TAVILY_API_KEY. No codebase work.
- **heartbeat-self-improve.sh** — Work heartbeat: task queue, PRs, opportunity scans, research, **cursor_improve** (improve product and Chump–Cursor relationship: write rules, docs, use Cursor to implement), tool discovery, and **battle QA self-heal**. Round types cycle: work, work, **cursor_improve**, opportunity, work, **cursor_improve**, research, work, discovery, **battle_qa** (cursor_improve is a major factor, 2 per cycle). Default: **15 min** between rounds (8h duration). Set `HEARTBEAT_INTERVAL=10m` or `5m` in .env or when starting to go harder (more CPU).
- **heartbeat-cursor-improve-loop.sh** — Runs **cursor_improve** rounds one after another (default 8h, **10 min** between rounds). Use when you want continuous product + Cursor improvement. Respects **logs/pause**; start/stop from Chump Menu or `pkill -f heartbeat-cursor-improve-loop`. Set `HEARTBEAT_INTERVAL=5m` to go harder. To run rounds as often as possible: `HEARTBEAT_INTERVAL=1m HEARTBEAT_DURATION=8h ./scripts/heartbeat-self-improve.sh`; or `HEARTBEAT_QUICK_TEST=1` for 30s interval (2m total). Run in tmux or nohup so it keeps going after you close the terminal.

**What to work on:** The roadmap is **docs/ROADMAP.md** (prioritized goals; unchecked items = work to do). **docs/CHUMP_PROJECT_BRIEF.md** has focus and conventions. Heartbeat, Discord bot, and Cursor agents read these; edit ROADMAP.md to add or check off items.

### Reliable one-shot run (self-improve)

Prereqs: Ollama running (`ollama serve`), model pulled (`ollama pull qwen2.5:14b`), and `cargo build --release` once. Run only one heartbeat process (multiple processes cause duplicate rounds and mixed env).

```bash
pkill -f heartbeat-self-improve
HEARTBEAT_INTERVAL=1m HEARTBEAT_DURATION=8h nohup bash scripts/heartbeat-self-improve.sh >> logs/heartbeat-self-improve.log 2>&1 &
```

Check that rounds succeed: `grep "Round.*: ok" logs/heartbeat-self-improve.log | tail -5`. If you see "Round X: exit non-zero" and connection or model errors in the log, fix env (Ollama 11434, OPENAI_MODEL=qwen2.5:14b) and ensure only one heartbeat is running.

**Auto self-improve (launchd):** To run self-improve on a schedule (e.g. every 8h), copy `scripts/heartbeat-self-improve.plist.example` to `~/Library/LaunchAgents/ai.chump.heartbeat-self-improve.plist`, replace `/path/to/Chump` with your repo path (e.g. `~/Projects/Chump`) and fix StandardOutPath/StandardErrorPath, then run `launchctl load ~/Library/LaunchAgents/ai.chump.heartbeat-self-improve.plist`. Each run executes one full 8h self-improve session. Adjust `StartInterval` (e.g. 86400 for daily). Ensure PATH in the plist includes `~/.local/bin` so Cursor CLI (`agent`) is found. For Chump + Cursor around-the-clock setup (Tavily, timeouts, optional research-cursor-only schedule), see [CHUMP_CURSOR_AROUND_THE_CLOCK.md](CHUMP_CURSOR_AROUND_THE_CLOCK.md).

**Discord DM updates from heartbeat:** Set `CHUMP_READY_DM_USER_ID` (your Discord user ID) and `DISCORD_TOKEN` in `.env`. When Chump uses the notify tool during a heartbeat round (e.g. blocked, PR ready, or end-of-run summary), you get a DM. You do not need to run the Discord bot for these DMs.

**Publish autonomy:** With `CHUMP_AUTO_PUBLISH=1`, the self-improve heartbeat and CLI soul allow Chump to push to main and create releases: bump version in `Cargo.toml`, update `CHANGELOG` (move [Unreleased] to the new version), `git tag vX.Y.Z`, `git push origin main --tags`. One release per logical batch; Chump notifies when released. Without it, Chump uses chump/* branches only and never pushes to main.

**Pause / Resume (navbar app):** Chump Menu → **Pause self-improve** creates `logs/pause` so the self-improve heartbeat and the cursor-improve loop skip rounds (they sleep until the file is removed). **Resume self-improve** removes `logs/pause` so rounds run again. Same effect from the shell: `touch logs/pause` to pause, `rm logs/pause` to resume.

**Cursor-improve loop (one round after another):** From the menu: **Start cursor-improve loop (8h)** or **Cursor-improve loop (quick 2m)**. This runs only cursor_improve rounds back-to-back (default **10 min** between rounds). Set `HEARTBEAT_INTERVAL=5m` in .env to go harder. Pause/Resume applies to this loop too.

**Push to Chump repo and self-reboot:** To let the bot push to the Chump repo and restart with new capabilities: set `CHUMP_GITHUB_REPOS` (include the Chump repo, e.g. `owner/Chump`), `GITHUB_TOKEN` (or `CHUMP_GITHUB_TOKEN`), and `CHUMP_AUTO_PUSH=1`. The bot can then git_commit and git_push to chump/* branches. After pushing changes that affect the bot (soul, tools, src), the bot may run `scripts/self-reboot.sh` to kill the current Discord process, rebuild release, and start the new bot. You can also say "reboot yourself" or "self-reboot" in Discord to trigger it. Script: `scripts/self-reboot.sh` (invoked as `nohup bash scripts/self-reboot.sh >> logs/self-reboot.log 2>&1 &`). Optional: `CHUMP_SELF_REBOOT_DELAY=10` (seconds before kill, default 10). Logs: `logs/self-reboot.log`, `logs/discord.log`.

## Keep-alive (MacBook)

`./scripts/keep-chump-online.sh` (if present) can ensure Ollama, optional embed server (18765), and Chump Discord stay up. For "always on" on a MacBook, use launchd or run `ollama serve` in the background. Logs: `logs/keep-chump-online.log`.

## Roles (should be running in the background)

Farmer Brown and the other roles (Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender) **should be running** on a schedule so the stack stays healthy, Chump stays online, and heartbeat/models are tended. Use the **Chump Menu → Roles** tab to run each script once or open logs; for 24/7 help, schedule them with launchd or cron as below.

## Farmer Brown (diagnose + fix)

**Farmer Brown** is a Chump keeper that diagnoses the stack (model, worker, embed, Discord), kills stale processes when a port is in use but the service is unhealthy, then runs `keep-chump-online.sh` to bring everything up.

- **Diagnose only:** `FARMER_BROWN_DIAGNOSE_ONLY=1 ./scripts/farmer-brown.sh` — prints and logs status for each component (up/down/stale); no starts or kills.
- **Diagnose + fix once:** `./scripts/farmer-brown.sh`
- **Loop (e.g. every 2 min):** `FARMER_BROWN_INTERVAL=120 ./scripts/farmer-brown.sh`
- **launchd:** Copy `scripts/farmer-brown.plist.example` to `~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist`, replace the path placeholder with your repo path (e.g. ~/Projects/Chump), then `launchctl load ~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist`. Runs every 120s by default.

Uses the same env as keep-chump-online (`CHUMP_KEEPALIVE_EMBED`, `CHUMP_KEEPALIVE_DISCORD`, `CHUMP_KEEPALIVE_WORKER`, `WARM_PORT_2`, `.env`). Logs: `logs/farmer-brown.log`. If `CHUMP_HEALTH_PORT` is set, diagnosis includes Chump health JSON.

## Other roles (shepherd, memory keeper, sentinel, oven tender)

Chump Menu **Roles** tab shows all five roles; Run once and Open log from there. To **auto-start all five** on this Mac, run once from the Chump repo:

```bash
./scripts/install-roles-launchd.sh
```

This installs launchd plists into `~/Library/LaunchAgents` (with your repo path), loads them, and they run at: Farmer Brown every 2 min, Heartbeat Shepherd every 15 min, Memory Keeper every 15 min, Sentinel every 5 min, Oven Tender every 1 hour. To stop: `./scripts/unload-roles-launchd.sh` or unload each plist. Plist examples: `scripts/*.plist.example`; edit and re-run the install script if you need different intervals. To keep them helping in the background manually, schedule each as below.

- **Heartbeat Shepherd** (`./scripts/heartbeat-shepherd.sh`): Checks last run in `logs/heartbeat-learn.log`; if the last round failed, optionally runs one quick round (`HEARTBEAT_SHEPHERD_RETRY=1`). Schedule via cron/launchd every 15–30 min. Logs: `logs/heartbeat-shepherd.log`.
- **Memory Keeper** (`./scripts/memory-keeper.sh`): Checks memory DB exists and is readable; optionally pings embed server. Does not edit memory. Logs: `logs/memory-keeper.log`. Env: `MEMORY_KEEPER_CHECK_EMBED=1` to also check embed.
- **Sentinel** (`./scripts/sentinel.sh`): When Farmer Brown or heartbeat show recent failures, writes `logs/sentinel-alert.txt` with a short summary and last log lines. Optional: `NTFY_TOPIC` (ntfy send), `SENTINEL_WEBHOOK_URL` (POST JSON). **Self-heal:** set `SENTINEL_SELF_HEAL_CMD` to a command to run when the alert fires (e.g. `./scripts/farmer-brown.sh` locally, or `ssh user@my-mac "cd ~/Projects/Chump && ./scripts/farmer-brown.sh"` to trigger repair on the Chump host). Runs in background; output in `logs/sentinel-self-heal.log`.
- **Oven Tender** (`./scripts/oven-tender.sh`): If Ollama is not warm, runs `warm-the-ovens.sh` (starts `ollama serve`). Schedule via cron/launchd (e.g. 7:45) so Chump is ready by a chosen time. Logs: `logs/oven-tender.log`.

## Battle QA (500 queries)

`./scripts/battle-qa.sh` runs 500 user queries against Chump CLI and reports pass/fail. Use to harden before release.

- **Once:** `./scripts/battle-qa.sh`
- **Smoke (50):** `BATTLE_QA_MAX=50 ./scripts/battle-qa.sh`
- **Until ready:** `BATTLE_QA_ITERATIONS=5 ./scripts/battle-qa.sh` — re-run up to 5 times; exit 0 when all pass. Fix failures (see `logs/battle-qa-failures.txt`) between runs.

Requires Ollama on 11434. Logs: `logs/battle-qa.log`, `logs/battle-qa-failures.txt`. See [BATTLE_QA.md](BATTLE_QA.md).

## Env reference

| Env                                           | Default / note             |
| --------------------------------------------- | -------------------------- |
| `OPENAI_API_BASE`                             | Model server URL           |
| `OPENAI_API_KEY`                              | `not-needed` local         |
| `OPENAI_MODEL`                                | `qwen2.5:14b` (Ollama); `default` for vLLM single-model |
| `CHUMP_FALLBACK_API_BASE`                     | Fallback model URL         |
| `CHUMP_DELEGATE`                              | `1` = delegate tool        |
| `CHUMP_WORKER_API_BASE`, `CHUMP_WORKER_MODEL` | Worker endpoint/model      |
| `CHUMP_REPO`, `CHUMP_HOME`                    | Repo path (tools + cwd)    |
| `CHUMP_BRAIN_PATH`                            | Brain wiki root            |
| `CHUMP_READY_DM_USER_ID`                      | Ready DM when bot connects; notify DMs (Discord + heartbeat when DISCORD_TOKEN set) |
| `CHUMP_EXECUTIVE_MODE`                        | No allowlist, 300s timeout |
| `CHUMP_RATE_LIMIT_TURNS_PER_MIN`              | Per-channel cap (0=off)    |
| `CHUMP_MAX_CONCURRENT_TURNS`                  | Global cap (0=off)         |
| `CHUMP_MAX_MESSAGE_LEN`                       | 16384                      |
| `CHUMP_MAX_TOOL_ARGS_LEN`                     | 32768                      |
| `CHUMP_EMBED_URL`                             | Embed server (optional)    |
| `CHUMP_PAUSED`                                | `1` = kill switch          |
| `CHUMP_AUTO_PUBLISH`                         | `1` = may push to main and create releases (bump Cargo.toml, CHANGELOG, tag, push --tags). Heartbeat uses this for publish autonomy. |
| `TAVILY_API_KEY`                              | Web search                 |

## Troubleshooting

**Bot not working?** Run `./scripts/check-discord-preflight.sh` from repo root. It checks: `DISCORD_TOKEN` in `.env`, no duplicate bot running, and model server (Ollama at 11434 by default, or OPENAI_API_BASE port). Fix any FAIL, then `./run-discord.sh`. For Ollama: `ollama serve && ollama pull qwen2.5:14b`. If the bot starts but doesn’t reply: ensure the bot is invited, Message Content Intent is enabled in the Discord Developer Portal, and the model server is up.

- **Connection closed / 5xx:** Restart model server; check `CHUMP_FALLBACK_API_BASE` if using fallback.
- **Port in use but not responding (stale process):** Run `./scripts/farmer-brown.sh` — it will diagnose, kill stale processes on 11434/18765 if needed, then run keep-chump-online to bring services back up.
- **Memory:** Embed server can OOM with large models; use smaller main model or in-process embeddings (`--features inprocess-embed`, unset `CHUMP_EMBED_URL`).
- **SQLite missing:** Memory uses JSON fallback; state/episode/task/schedule need `sessions/` writable.
- **Pause:** Create `logs/pause` or set `CHUMP_PAUSED=1`; bot replies "I'm paused."
