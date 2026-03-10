# Chump Menu Bar App

A small macOS menu bar app (top nav) to **start** and **stop** Chump and see **status** at a glance. v1.1 adds Start/Stop for MLX 8001, faster status updates after stop, embed server refreshes until warm, and single-instance guard for the Discord bot (no duplicate replies). The UI uses semantic colors, clearer spacing and hierarchy, list-style sections, and accessibility labels.

- **Icon:** Brain icon in the menu bar (macOS 13+).
- **Menu:** Chump online/offline; model ports 8000/8001 and embed 18765 (warm/cold) with Start/Stop for each; **Start Chump** / **Stop Chump**; **Start heartbeat (8h learning)** / **Stop heartbeat (learning)**; **Open logs**, **Open vLLM log (8000)**, **Open vLLM log (8001)**, **Open embed log**, **Open heartbeat log**; Quit.
- **Refresh:** Status refreshes every 10 seconds and when you open the menu.

## Build

From the **rust-agent** directory:

```bash
./scripts/build-chump-menu.sh
```

Requires Xcode Command Line Tools (or Xcode) and macOS 13+. Output: `ChumpMenu/ChumpMenu.app`.

## Install / Run

- **Run once:** Open `ChumpMenu.app` (double-click or from Finder). The app stays in the menu bar (no Dock icon).
- **Install in Applications:** Drag `ChumpMenu.app` into `/Applications` (or leave it in the repo).
- **Start at login:** System Settings → General → Login Items → add ChumpMenu.app.

## Repo path

The app assumes Chump (and `run-discord.sh`) lives at:

`~/Projects/Maclawd/rust-agent`

To use a different path:

```bash
defaults write ai.openclaw.chump-menu ChumpRepoPath /full/path/to/rust-agent
```

Then restart the menu app.

## Start / Stop

- **Start vLLM-MLX (8000):** Runs `./serve-vllm-mlx.sh` in the background. Logs: `/tmp/chump-vllm.log`. First run may download the model (~17GB). Port 8000 shows warm when ready (~1–2 min).
- **Stop vLLM-MLX (8000):** Stops the process listening on port 8000 (only).
- **Start vLLM-MLX (8001):** Runs `./scripts/serve-vllm-mlx-8001.sh` in the background. Logs: `/tmp/chump-vllm-8001.log`. Use for a second model (e.g. 7B) alongside 8000.
- **Stop vLLM-MLX (8001):** Stops the process listening on port 8001 (only).
- **Start embed server:** Runs `./scripts/start-embed-server.sh` via a login shell so `python3` is on PATH. Logs: `/tmp/chump-embed.log`. Requires `pip install -r scripts/requirements-embed.txt`. The menu refreshes at 3s, 12s, and 28s after start so "warm" appears once the model has loaded (first run can take 20–60s).
- **Stop embed server:** Stops the embed server process; "Start embed server" appears immediately.
- **Start Chump:** Runs `./run-discord.sh` from the repo path in the background. Chump (Discord bot) stays running until you click Stop or close the terminal that’s running it (if you started it from the script instead of the menu).
- **Stop Chump:** Runs `pkill -f "rust-agent.*--discord"` so the Discord bot process exits. Model servers (if any) are left running.
- **Start heartbeat (8h learning):** Runs `scripts/heartbeat-learn.sh` in the background (sources `.env` when present). Log: `logs/heartbeat-learn.log`. Requires model on 8000 and `TAVILY_API_KEY` in `.env`; run `cargo build --release` once for stable runs.
- **Stop heartbeat (learning):** Stops the heartbeat script (`pkill -f heartbeat-learn`).
- **Open vLLM log (8000)** / **Open vLLM log (8001):** Opens `/tmp/chump-vllm.log` or `/tmp/chump-vllm-8001.log`.
- **Open heartbeat log:** Opens `logs/heartbeat-learn.log` in the repo.

The menu bar app does not run Chump under launchd; it only starts the same `run-discord.sh` you’d run in a terminal. For “always on” across sleep/wake, use the launchd setup in [docs/CHUMP_SERVICE.md](../docs/CHUMP_SERVICE.md) and use the menu app to monitor and open logs.
