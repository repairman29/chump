# Docs index

| Doc | What it covers |
| --- | -------------- |
| [SETUP_QUICK.md](SETUP_QUICK.md) | One-time setup: setup script, Ollama, Discord, autonomy, ChumpMenu |
| [SETUP_AND_RUN.md](SETUP_AND_RUN.md) | Run from repo root, Ollama default, model selection, ChumpMenu |
| [OPERATIONS.md](OPERATIONS.md) | Run/serve, Discord, heartbeat, env reference, troubleshooting |
| [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md) | Message Content Intent, token, "errors in response", no such file |
| [DISCORD_CONFIG.md](DISCORD_CONFIG.md) | What’s configured for Discord (intents, env, scripts, ChumpMenu) |
| [OLLAMA_SPEED.md](OLLAMA_SPEED.md) | Ollama speed tuning: context, keep_alive, parallel, model choice |
| [PROJECT_PIXEL_TERMUX_COMPANION.md](PROJECT_PIXEL_TERMUX_COMPANION.md) | Chump's first project: Rust bot companion in Termux on the Pixel; build tools + agent; doc index for Chump |
| [ANDROID_COMPANION.md](ANDROID_COMPANION.md) | Mabel on Pixel: Termux, SSH (port 8022), cross-compile, deploy; SSH config and troubleshooting |
| [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) | Mabel on Pixel: perf spec, tunables, **timing diagnostics** (CHUMP_LOG_TIMING), **deploy-all-to-pixel** (single deploy), capture/parse, optimization loop |
| [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) | **Mabel takes over the farm:** migrate Farmer Brown, Sentinel, Heartbeat Shepherd to Pixel; mabel-farmer.sh, Tailscale, DM alerts |
| [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) | **Mabel as a driver:** autonomous heartbeat (patrol, research, report, intel, verify, peer_sync), unified reporting, Termux:Boot, ChumpMenu start/stop; **Sprints 6–10:** mutual supervision, OCR, shared brain, QA verify, hybrid inference. **Two-node setup:** [what's in place / what to bring in](ROADMAP_MABEL_DRIVER.md#two-node-setup-whats-in-place--what-to-bring-in) (brain repo, deploy key, optional Mac API bind). |
| [A2A_DISCORD.md](A2A_DISCORD.md) | **Agent-to-agent:** Mabel and Chump message each other over Discord (message_peer tool, CHUMP_A2A_PEER_USER_ID) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | What Chump is, tools, soul, brain, memory, resilience |
| [CHUMP_BRAIN.md](CHUMP_BRAIN.md) | State/episodes/tasks DB, ego/episode/memory_brain tools, self.md; **shared brain** repo [repairman29/chump-brain](https://github.com/repairman29/chump-brain), deploy key on Pixel, sync in heartbeats |
| [WISHLIST.md](WISHLIST.md) | Implemented + backlog |
