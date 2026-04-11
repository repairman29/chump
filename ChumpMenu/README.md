# Chump Menu Bar App

A small macOS menu bar app (top nav) to **start** and **stop** Chump and see **status** at a glance. The UI uses semantic colors, clearer spacing and hierarchy, list-style sections, and accessibility labels.

**Product direction (chief of staff, waves, 60 stories):** [../docs/PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](../docs/PRODUCT_ROADMAP_CHIEF_OF_STAFF.md).

- **Icon:** Brain icon in the menu bar (macOS 13+).
- **Menu:** Chump online/offline (web + optional Discord); **Chat** tab (native UI → `POST /api/chat`); Ollama (11434) warm/cold with Start/Stop; **Start Chump (web)** / **Stop Chump**; **Start heartbeat (8h learning)** / **Stop heartbeat (learning)**; **Open logs**, **Open Ollama log**, **Open embed log**, **Open heartbeat log**; Quit.
- **Refresh:** Status refreshes every 10 seconds and when you open the menu.

## Build

From the **Chump repo root** (e.g. `~/Projects/Chump`):

```bash
./scripts/build-chump-menu.sh
```

Requires Xcode Command Line Tools (or Xcode) and macOS 14+. Output: `ChumpMenu/ChumpMenu.app`.

## Install / Run

- **Run once:** Open `ChumpMenu.app`. The app stays in the menu bar (no Dock icon).
- **Install in Applications:** Drag `ChumpMenu.app` into `/Applications` (or leave it in the repo).
- **Start at login:** System Settings → General → Login Items → add ChumpMenu.app.

## Repo path

Default: **`~/Projects/Chump`**. The app runs `run-web.sh` for **Chump web** (PWA + API) and looks for logs under that path. Discord is optional; use `./run-discord.sh` from a terminal if you still want the bot.

To use a different path: use **Set Chump repo path…** in the menu (or `defaults write ai.openclaw.chump-menu ChumpRepoPath /full/path/to/Chump` then restart the app).

## Start / Stop

- **Start Ollama:** Runs `ollama serve` in the background. Logs: `/tmp/chump-ollama.log`. Pull a model first: `ollama pull qwen2.5:14b`. Port 11434 shows warm when ready.
- **Stop Ollama:** Stops the Ollama process (port 11434).
- **Start embed server:** Runs `./scripts/start-embed-server.sh` via a login shell so `python3` is on PATH. Logs: `/tmp/chump-embed.log`. Requires `pip install -r scripts/requirements-embed.txt`. The menu refreshes at 3s, 12s, and 28s after start so "warm" appears once the model has loaded (first run can take 20–60s).
- **Stop embed server:** Stops the embed server process; "Start embed server" appears immediately.
- **Chat tab:** Talk to Chump via the local web server (`POST /api/chat`, SSE). Requires **Chump web** running (`./run-web.sh` or **Start Chump (web)**). Uses `CHUMP_WEB_HOST` / `CHUMP_WEB_PORT` and optional `CHUMP_WEB_TOKEN` from `.env` like the PWA.
- **Start Chump (web):** Runs `./run-web.sh` in the background. Log: `logs/chump-web.log`. Stays running until **Stop Chump** (or you kill the process).
- **Stop Chump:** Stops Chump **web** (`chump` / `rust-agent` with `--web`) and **Discord** bot processes if present. Ollama (if started from the menu) is left running.
- **Roles tab:** Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender. These roles **should be running in the background** to keep the stack healthy; **Run once** runs that script now. For 24/7 help, schedule them with launchd or cron (see docs/OPERATIONS.md). Green dot = script running or log updated in last 30s. "Not found" → set Chump repo path to the folder that contains `scripts/` (e.g. `~/Projects/Chump`); run `./scripts/setup-local.sh` so scripts are executable.
- **Start heartbeat (8h learning):** Runs `scripts/heartbeat-learn.sh` in the background (sources `.env` when present). Log: `logs/heartbeat-learn.log`. Requires Ollama running and `TAVILY_API_KEY` in `.env`; run `cargo build --release` once for stable runs.
- **Stop heartbeat (learning):** Stops the heartbeat script (`pkill -f heartbeat-learn`).
- **Start cursor-improve loop (8h)** / **Cursor-improve loop (quick 2m):** Runs `heartbeat-cursor-improve-loop.sh` — cursor_improve rounds one after another (20m between rounds by default). **Stop cursor-improve loop** stops it. Requires TAVILY_API_KEY, CHUMP_CURSOR_CLI, Cursor CLI in PATH.
- **Pause self-improve:** Creates `logs/pause`; the self-improve heartbeat and cursor-improve loop skip rounds until you **Resume self-improve** (removes `logs/pause`).
- **Open Ollama log:** Opens `/tmp/chump-ollama.log`.
- **Open heartbeat log:** Opens `logs/heartbeat-learn.log` in the repo.

The menu bar app does not run Chump under launchd; it starts the same `./run-web.sh` you would run in a terminal. For "always on" across sleep/wake, use the launchd setup in [docs/CHUMP_SERVICE.md](../docs/CHUMP_SERVICE.md) and use the menu app to monitor and open logs.
