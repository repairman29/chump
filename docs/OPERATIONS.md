# Operations

## Run

All of the following are run **from the Chump repo root** (the directory containing `Cargo.toml` and `run-discord.sh`).

| Mode           | Command                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| CLI (one shot) | `cargo run -- --chump "message"` or `./run-local.sh --chump "message"`                                                                           |
| CLI (repl)     | `cargo run -- --chump` or `./run-local.sh --chump`                                                                                               |
| Discord        | `./run-discord.sh` (loads .env) or `./run-discord-ollama.sh` (Ollama preflight)                                                                  |
| Web (PWA)      | **Preferred:** `./run-web.sh` (ensures model on 8000 is up when `.env` points at 8000, then starts on port 3000). Or `./run-web.sh --port 3001`. Raw: `./target/release/rust-agent --web` (port 3000). Serves `web/`, `/api/health`, `/api/chat`. Set `CHUMP_HOME` to repo so `web/` is found. The PWA talks to **one** agent per process: Chump by default, or Mabel if you start with `CHUMP_MABEL=1`. No in-app bot selector yet. |
| Scripts        | `./run-local.sh` (Ollama), `./run-discord.sh` (loads .env), `./run-discord-ollama.sh` (Discord + Ollama) |

### PWA as primary interface (chat with different bots)

You don't have to stop using Discord: both can run. The roadmap treats **Scout/PWA as the primary interface** (see [FLEET_ROLES.md](FLEET_ROLES.md)). To get "chat with Chump vs Mabel" in one place:

- **Today:** Use `./run-web.sh` so the model (8000 or Ollama) is started if down, then the PWA runs. For two bots in one place, run two web processes: one with default env (Chump) and one with `CHUMP_MABEL=1` on different ports (e.g. 3000 and 3001). No UI bot selector yet.
- **Next step:** Add a **bot** (or **agent**) parameter to `POST /api/chat` (e.g. `bot: "chump" | "mabel"`) and have the backend build the right agent per request; then add a bot switcher in the PWA UI and separate sessions per bot. That gives one PWA URL, one place for all chats, and no dependency on Discord for daily use.

## Keeping the stack running (Farmer Brown + Mabel)

The PWA and Discord need the **model server** (e.g. vLLM on 8000 or Ollama on 11434) to be up. Two layers keep it that way:

1. **Farmer Brown (Mac)** — Diagnoses model (8000), embed, Discord; if something is down, kills stale processes and runs **keep-chump-online**, which starts vLLM (via `restart-vllm-if-down.sh`) when `.env` points at 8000, or Ollama when not. Run once: `./scripts/farmer-brown.sh`. For **self-heal every 2 min**, install the launchd role: `./scripts/install-roles-launchd.sh` (includes Farmer Brown). Then the Mac stack recovers automatically after crashes or reboot.

2. **Mabel (Pixel)** — She keeps the Chump stack running by running **mabel-farmer.sh** in her **patrol** round (from `heartbeat-mabel.sh`). Mabel SSHs to the Mac and runs **farmer-brown.sh** when the stack is unhealthy, so the Mac gets fixed even if you're not at the Mac. For this to work:
   - **On the Pixel:** In `~/chump/.env` set **`MAC_TAILSCALE_IP`** to your Mac's Tailscale IP (e.g. `100.x.y.z`). Optionally `MAC_CHUMP_HOME` (e.g. `~/Projects/Chump`), `MAC_TAILSCALE_USER`, `MAC_SSH_PORT`.
   - **On the Mac:** SSH must allow the Pixel's key (e.g. add Pixel's `~/.ssh/id_ed25519.pub` to Mac's `~/.ssh/authorized_keys`). Tailscale (or reachable network) so the Pixel can reach the Mac.
   - **Run Mabel's heartbeat on the Pixel:** `./scripts/heartbeat-mabel.sh` (in tmux or Termux:Boot). Patrol rounds run `mabel-farmer.sh`; when the Mac stack is down, Mabel SSHs in and runs `farmer-brown.sh`, which runs keep-chump-online and brings up vLLM/Discord.

Using **both** — Farmer Brown on the Mac (launchd every 2 min) and Mabel's patrol on the Pixel — means the stack stays up even when the model crashes or the Mac reboots, and Mabel can fix the Mac remotely when you're away.

## Serve (model)

- **Ollama (default):** No Python in agent runtime. `ollama serve`, `ollama pull qwen2.5:14b`. Chump defaults to `OPENAI_API_BASE=http://localhost:11434/v1`, `OPENAI_API_KEY=ollama`, `OPENAI_MODEL=qwen2.5:14b`. Run `./run-discord.sh` or `./run-local.sh`. **Speed:** use `./scripts/ollama-serve-fast.sh` or see [OLLAMA_SPEED.md](OLLAMA_SPEED.md).
- **Ollama (default):** `ollama serve` (port 11434). Set `OPENAI_API_BASE=http://localhost:11434/v1` (default in run scripts). Pull a model: `ollama pull qwen2.5:14b`.

### Keep Chump running (14B on 8000 only)

Minimal setup: one model (14B) on port 8000, no Ollama, no scout/triage, no launchd roles. Start the model and Chump manually when you need them.

1. **.env:** Set `OPENAI_API_BASE=http://localhost:8000/v1` and `OPENAI_MODEL=mlx-community/Qwen2.5-14B-Instruct-4bit` (see `.env.example` M4-max section).
2. **Start the model:** From repo root, `./scripts/restart-vllm-if-down.sh`. If 8000 is down it starts vLLM-MLX 14B and waits until ready (up to 4 min). If 8000 is already up it exits immediately.
3. **Run Chump:** `./run-discord.sh` (Discord) or `./run-local.sh --chump "message"` (CLI). To keep the Discord bot running after closing the terminal: run in **tmux** or **screen** (e.g. `tmux new -s chump && cd ~/Projects/Chump && ./run-discord.sh`), or use Chump Menu → Start.
4. **If 8000 dies (OOM/crash):** Run `./scripts/restart-vllm-if-down.sh` again. Check `logs/vllm-mlx-8000.log` and [GPU_TUNING.md](GPU_TUNING.md#5-investigating-oom--metal-crashes) if it keeps crashing.

**Fine-tuning and keeping it steady:** See [STEADY_RUN.md](STEADY_RUN.md) for vLLM/Chump .env tuning, retries, and optional launchd/cron so 8000 and Discord stay up.

## Discord

Create bot at Discord Developer Portal; enable Message Content Intent. Set `DISCORD_TOKEN` in `.env`. Invite bot; it replies in DMs and when @mentioned. `CHUMP_READY_DM_USER_ID`: ready DM + notify target (and hourly updates / "reach out when stuck"). To send a proactive "I'm up" DM on demand (same idea as Mabel's `mabel-explain.sh`), run `./scripts/chump-explain.sh`. `CHUMP_WARM_SERVERS=1`: start Ollama on first message (warm-the-ovens). `CHUMP_PROJECT_MODE=1`: project-focused soul.

**Hourly updates:** Install the hourly-update launchd job (see Roles below) so Chump sends you a brief DM every hour (episode recent, task list, blockers). Requires `CHUMP_READY_DM_USER_ID` and `DISCORD_TOKEN` in `.env`.

**When you message while Chump is busy:** Set `CHUMP_MAX_CONCURRENT_TURNS=1` (recommended for autopilot). If you message while a turn is in progress, Chump replies that your message is queued and will respond at the next available moment. Messages are stored in `logs/discord-message-queue.jsonl` and processed one-by-one after each turn (no need to retry).

## Heartbeat

**Two scripts:**

- **heartbeat-learn.sh** — Learning-only: runs Chump on a timer (e.g. 8h, 45min interval) with rotating web-search prompts; stores learnings in memory. Needs model + TAVILY_API_KEY. No codebase work.
- **heartbeat-self-improve.sh** — Work heartbeat: task queue, PRs, opportunity scans, research, **cursor_improve**, tool discovery, **battle QA self-heal**. Round types cycle: work, work, cursor_improve, opportunity, work, cursor_improve, research, work, discovery, battle_qa. Default: **8 min** between rounds (8h, ~60 rounds). Set `HEARTBEAT_INTERVAL=5m` or `3m` to top out; watch logs for `exit non-zero` and back off if rounds fail.
- **heartbeat-cursor-improve-loop.sh** — Runs **cursor_improve** rounds back-to-back (default 8h, **5 min** between rounds, ~96 rounds). Respects **logs/pause**; start/stop from Chump Menu or `pkill -f heartbeat-cursor-improve-loop`. Set `HEARTBEAT_INTERVAL=3m` to top out. Max aggressive self-improve: `HEARTBEAT_INTERVAL=1m HEARTBEAT_DURATION=8h ./scripts/heartbeat-self-improve.sh`; or `HEARTBEAT_QUICK_TEST=1` for 30s interval (2m total). Run in tmux or nohup so it keeps going after you close the terminal.
- **heartbeat-mabel.sh** (runs on Pixel) — Mabel's autonomous heartbeat: patrol (mabel-farmer + Chump heartbeat check), research, report (unified fleet report + notify), intel, **verify** (QA after Chump code changes), peer_sync. Start/stop from Chump Menu → **Mabel (Pixel)** or via SSH. Shared brain: git pull/push to `chump-brain`; optional hybrid inference via `MABEL_HEAVY_MODEL_BASE`. See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) and [ANDROID_COMPANION.md](ANDROID_COMPANION.md#mabel-heartbeat). What's in place vs what to bring in: [ROADMAP_MABEL_DRIVER.md#two-node-setup-whats-in-place--what-to-bring-in](ROADMAP_MABEL_DRIVER.md#two-node-setup-whats-in-place--what-to-bring-in).

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

**Cursor-improve loop (one round after another):** From the menu: **Start cursor-improve loop (8h)** or **Cursor-improve loop (quick 2m)**. This runs only cursor_improve rounds back-to-back (default **5 min** between rounds). Set `HEARTBEAT_INTERVAL=3m` in .env to top out. Pause/Resume applies to this loop too.

**Check every 20m and tune for peak:** Run `./scripts/check-heartbeat-health.sh` every 20 minutes to see recent ok vs fail counts and a recommendation (back off, hold, or try a shorter interval). To automate: copy `scripts/heartbeat-health-check.plist.example` to `~/Library/LaunchAgents/ai.chump.heartbeat-health-check.plist`, replace `/path/to/Chump` with your repo path, then `launchctl load ~/Library/LaunchAgents/ai.chump.heartbeat-health-check.plist`. It runs the check every 20 min and appends to `logs/heartbeat-health.log`. Use the recommendations and adjust `HEARTBEAT_INTERVAL` (then restart the heartbeat) until you see mostly "all recent rounds ok" and optional "try 5m/3m to top out".

**Push to Chump repo and self-reboot:** To let the bot push to the Chump repo and restart with new capabilities: set `CHUMP_GITHUB_REPOS` (include the Chump repo, e.g. `owner/Chump`), `GITHUB_TOKEN` (or `CHUMP_GITHUB_TOKEN`), and `CHUMP_AUTO_PUSH=1`. The bot can then git_commit and git_push to chump/* branches. After pushing changes that affect the bot (soul, tools, src), the bot may run `scripts/self-reboot.sh` to kill the current Discord process, rebuild release, and start the new bot. You can also say "reboot yourself" or "self-reboot" in Discord to trigger it. Script: `scripts/self-reboot.sh` (invoked as `nohup bash scripts/self-reboot.sh >> logs/self-reboot.log 2>&1 &`). Optional: `CHUMP_SELF_REBOOT_DELAY=10` (seconds before kill, default 10). Logs: `logs/self-reboot.log`, `logs/discord.log`.

## Keep-alive (MacBook)

`./scripts/keep-chump-online.sh` (if present) can ensure Ollama, optional embed server (18765), and Chump Discord stay up. For "always on" on a MacBook, use launchd or run `ollama serve` in the background. Logs: `logs/keep-chump-online.log`.

## Roles (should be running in the background)

Farmer Brown and the other roles (Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender) **should be running** on a schedule so the stack stays healthy, Chump stays online, and heartbeat/models are tended. Use the **Chump Menu → Roles** tab to run each script once or open logs; for 24/7 help, schedule them with launchd or cron as below.

**Bring up the whole stack (after reboot or updates):** Run `./scripts/bring-up-stack.sh` to build release, install/load the five launchd roles, run keep-chump-online once (Ollama + optional embed/Discord), and start the self-improve and cursor-improve heartbeats. With `PULL=1 ./scripts/bring-up-stack.sh` you git pull first, then build and start. With `BUILD_ONLY=1` only `cargo build --release` runs. See script header for env (ROLES=0, KEEPALIVE=0, HEARTBEATS=0 to skip parts). After the bot pushes code, `scripts/self-reboot.sh` restarts only the Discord bot (kill, build, start); use bring-up-stack if you want the full stack restarted (e.g. after you pull locally).

## Farmer Brown (diagnose + fix)

**Farmer Brown** is a Chump keeper that diagnoses the stack (model, worker, embed, Discord), kills stale processes when a port is in use but the service is unhealthy, then runs `keep-chump-online.sh` to bring everything up.

- **Diagnose only:** `FARMER_BROWN_DIAGNOSE_ONLY=1 ./scripts/farmer-brown.sh` — prints and logs status for each component (up/down/stale); no starts or kills.
- **Diagnose + fix once:** `./scripts/farmer-brown.sh`
- **Loop (e.g. every 2 min):** `FARMER_BROWN_INTERVAL=120 ./scripts/farmer-brown.sh`
- **launchd:** Copy `scripts/farmer-brown.plist.example` to `~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist`, replace the path placeholder with your repo path (e.g. ~/Projects/Chump), then `launchctl load ~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist`. Runs every 120s by default.

Uses the same env as keep-chump-online (`CHUMP_KEEPALIVE_EMBED`, `CHUMP_KEEPALIVE_DISCORD`, `CHUMP_KEEPALIVE_WORKER`, `WARM_PORT_2`, `.env`). Logs: `logs/farmer-brown.log`. If `CHUMP_HEALTH_PORT` is set, diagnosis includes Chump health JSON.

## Hourly update to Discord

When you want a brief DM from Chump every hour (what he did recently, tasks, blockers): install the hourly-update launchd job. Run `./scripts/install-roles-launchd.sh` (it includes `hourly-update-to-discord.plist.example`). Or copy `scripts/hourly-update-to-discord.plist.example` to `~/Library/LaunchAgents/ai.chump.hourly-update-to-discord.plist`, replace `/path/to/Chump` and `/Users/you`, then `launchctl load ...`. Requires `CHUMP_READY_DM_USER_ID` and `DISCORD_TOKEN` in `.env`. Logs: `logs/hourly-update.log`.

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

## What slows rounds (speed)

Round latency is affected by: **prompt size** (system prompt + assembled context: memory, episodes, health DB, file watch); **number of context messages** (recent conversation); **model** (local vs remote, model size); **network** (if API is remote). To speed up: trim context assembly (e.g. fewer episodes, shorter memory snippets), use a smaller/faster model for simple turns, reduce `CHUMP_MAX_CONTEXT_MESSAGES`, and ensure the model server is local (Ollama/vLLM on same machine). See also OLLAMA_SPEED.md and GPU_TUNING.md for model-side tuning.

## Battle QA (500 queries)

`./scripts/battle-qa.sh` runs 500 user queries against Chump CLI and reports pass/fail. Use to harden before release.

- **Once:** `./scripts/battle-qa.sh`
- **Smoke (50):** `BATTLE_QA_MAX=50 ./scripts/battle-qa.sh`
- **Until ready:** `BATTLE_QA_ITERATIONS=5 ./scripts/battle-qa.sh` — re-run up to 5 times; exit 0 when all pass. Fix failures (see `logs/battle-qa-failures.txt`) between runs.

Requires Ollama on 11434. Logs: `logs/battle-qa.log`, `logs/battle-qa-failures.txt`. See [BATTLE_QA.md](BATTLE_QA.md). To run tests against **default** (Ollama) or **max M4** (vLLM-MLX 8000) without editing .env: `./scripts/run-tests-with-config.sh <default|max_m4> battle-qa.sh` — see [BATTLE_QA.md](BATTLE_QA.md) "Testing against a specific config."

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
| `CHUMP_MAX_CONCURRENT_TURNS`                  | Global cap (0=off); 1 recommended for autopilot |
| `CHUMP_MAX_MESSAGE_LEN`                       | 16384                      |
| `CHUMP_MAX_TOOL_ARGS_LEN`                     | 32768                      |
| **Performance**                               | See [PERFORMANCE.md](PERFORMANCE.md) for review and tuning. |
| `CHUMP_EMBED_URL`                             | Embed server (optional)    |
| `CHUMP_PAUSED`                                | `1` = kill switch          |
| `CHUMP_AUTO_PUBLISH`                         | `1` = may push to main and create releases (bump Cargo.toml, CHANGELOG, tag, push --tags). Heartbeat uses this for publish autonomy. |
| `TAVILY_API_KEY`                              | Web search                 |

## vLLM-MLX on 8000 (max mode) and Python crash recovery

The default model on 8000 is **14B** (`mlx-community/Qwen2.5-14B-Instruct-4bit`), which runs on typical Apple Silicon without Metal OOM. Start with `./serve-vllm-mlx.sh`.

- **Restart 8000 after a crash:** Chump Menu → **Start** next to 8000 (vLLM-MLX), or run `./scripts/restart-vllm-if-down.sh`. Oven Tender (when scheduled via launchd) will also restart vLLM if 8000 is down.
- **Defaults in serve-vllm-mlx.sh** are conservative (max_num_seqs=1, max_tokens=8192, cache 15%). If runs are stable, you can override: `VLLM_MAX_NUM_SEQS=2 VLLM_MAX_TOKENS=16384 ./serve-vllm-mlx.sh`.
- **Shed load + GPU tuning:** To free GPU/RAM and squeeze more from the MacBook, use the **shed-load** role (runs Enter Chump mode every 2 h) and tune vLLM env vars. See [GPU_TUNING.md](GPU_TUNING.md).
- **Heartbeats on 8000** use longer intervals and a shared lock; see `scripts/env-max_m4.sh`.

**Other models**  
- **7B:** `VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit ./serve-vllm-mlx.sh` — lightest.
- **20B:** `VLLM_MODEL=mlx-community/gpt-oss-20b-MXFP4-Q4 ./serve-vllm-mlx.sh` — different family; try if 14B is too small.

Set `OPENAI_MODEL` in `.env` to the same model name so Chump uses it.

## Troubleshooting

**Bot not working?** Run `./scripts/check-discord-preflight.sh` from repo root. It checks: `DISCORD_TOKEN` in `.env`, no duplicate bot running, and model server (Ollama at 11434 by default, or OPENAI_API_BASE port). Fix any FAIL, then `./run-discord.sh`. For Ollama: `ollama serve && ollama pull qwen2.5:14b`. If the bot starts but doesn’t reply: ensure the bot is invited, Message Content Intent is enabled in the Discord Developer Portal, and the model server is up.

- **Connection closed / 5xx:** Restart model server; check `CHUMP_FALLBACK_API_BASE` if using fallback.
- **When vLLM crashes (OOM):** Run `./scripts/capture-oom-context.sh` (and optionally `./scripts/list-heavy-processes.sh`) to capture context for the next crash; then see [GPU_TUNING.md](GPU_TUNING.md#5-investigating-oom--metal-crashes) for the full runbook.
- **Python crashed (Metal OOM), Mac stayed up:** Restart vLLM with Chump Menu → Start 8000 or `./scripts/restart-vllm-if-down.sh`. Schedule Oven Tender (launchd) so 8000 is restarted automatically when down.
- **Python keeps crashing or 14B never finishes loading:** If 14B exits during “Fetching 10 files” / load (e.g. “leaked semaphore” and restarts in `logs/vllm-mlx-8000.log`), kill all vLLM (`pkill -f "vllm-mlx serve"`), then start once by hand and watch: `./serve-vllm-mlx.sh`. If it still exits during load, try CPU fallback: `MLX_DEVICE=cpu ./serve-vllm-mlx.sh` (slower but avoids Metal init bugs). While debugging, unload Oven Tender so it doesn’t restart on top of you: `launchctl bootout gui/$(id -u)/ai.chump.oven-tender`. See [GPU_TUNING.md](GPU_TUNING.md#5-investigating-oom--metal-crashes) for the OOM investigation runbook.
- **Port in use but not responding (stale process):** Run `./scripts/farmer-brown.sh` — it will diagnose, kill stale processes on 11434/18765 if needed, then run keep-chump-online to bring services back up.
- **Memory:** Embed server can OOM with large models; use smaller main model or in-process embeddings (`--features inprocess-embed`, unset `CHUMP_EMBED_URL`).
- **SQLite missing:** Memory uses JSON fallback; state/episode/task/schedule need `sessions/` writable.
- **Pause:** Create `logs/pause` or set `CHUMP_PAUSED=1`; bot replies "I'm paused."
