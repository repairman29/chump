# Scripts reference

Taxonomy of scripts: root `run-*.sh` entry points and `scripts/` with a one-line description per script. For detailed behavior see [OPERATIONS.md](OPERATIONS.md) and the docs referenced below.

## Root run scripts

These live at repo root (same directory as `Cargo.toml`). They set `CHUMP_HOME`/`CHUMP_REPO`, source `.env`, then invoke the binary.

| Script | Description |
|--------|-------------|
| `run-discord.sh` | Run Discord bot (default). |
| `run-local.sh` | Run CLI with local inference (Ollama); optional `--chump "message"`. |
| `run-web.sh` | Run PWA server (`rust-agent --web`); use for web UI. |
| `run-discord-ollama.sh` | Run Discord with Ollama preflight. |
| `run-discord-full.sh` | Run Discord with full preflight. |
| `run-best.sh` | Run with preferred/cascade config. |

## Setup (scripts/)

| Script | Description |
|--------|-------------|
| `setup-local.sh` | One-time local setup (env, deps). |
| `check-discord-preflight.sh` | Preflight check for Discord (token, intents). |
| `ensure-chump-repo.sh` | Ensure CHUMP_REPO is set and present. |
| `bootstrap-toolkit.sh` | Bootstrap toolkit / tooling. |
| `setup-termux-once.sh` | One-time Termux setup (Pixel). |
| `setup-and-run-termux.sh` | Setup and run Chump/Mabel in Termux. |
| `run-setup-via-ssh.sh` | Run setup on remote host via SSH. |
| `install-roles-launchd.sh` | Install launchd plists for roles (Farmer Brown, Sentinel, etc.). |
| `unload-roles-launchd.sh` | Unload role launchd jobs. |

## Run and serve (scripts/)

| Script | Description |
|--------|-------------|
| `restart-vllm-if-down.sh` | Restart vLLM-MLX if not responding. |
| `ollama-serve-fast.sh` | Start Ollama with fast/small context. |
| `ollama-restart.sh` | Restart Ollama. |
| `ollama-unload-models.sh` | Unload Ollama models to free memory. |
| `serve-multi-mlx.sh` | Serve multiple MLX models. |
| `serve-vllm-mlx-8001.sh` | Serve vLLM-MLX on port 8001. |
| `warm-the-ovens.sh` | Warm up inference (probe providers). |
| `bring-up-stack.sh` | Bring up full stack (model + Chump). |
| `download-mlx-models.sh` | Download MLX models. |

## Heartbeat (scripts/)

| Script | Description |
|--------|-------------|
| `heartbeat-ship.sh` | Product-shipping heartbeat (ship, review, research, maintain). |
| `heartbeat-self-improve.sh` | Self-improve heartbeat. |
| `heartbeat-learn.sh` | Learn heartbeat. |
| `heartbeat-mabel.sh` | Mabel heartbeat (on Pixel). |
| `heartbeat-cursor-improve-loop.sh` | Cursor improve loop heartbeat. |
| `heartbeat-cloud-only.sh` | Cloud-only heartbeat (cascade only). |
| `heartbeat-shepherd.sh` | Shepherd: coordinate heartbeats, next due. |
| `heartbeat-lock.sh` | Lock for single heartbeat runner. |
| `restart-chump-heartbeat.sh` | Restart Chump heartbeat (launchd). |
| `restart-mabel-heartbeat.sh` | Restart Mabel heartbeat on Pixel. |
| `check-heartbeat-preflight.sh` | Preflight before heartbeat. |
| `check-heartbeat-health.sh` | Check heartbeat health. |

## Fleet and deploy (scripts/)

| Script | Description |
|--------|-------------|
| `deploy-fleet.sh` | Deploy to full fleet (Mac + Pixel). |
| `deploy-mac.sh` | Deploy on Mac. |
| `deploy-mabel-to-pixel.sh` | Deploy Mabel binary to Pixel. |
| `deploy-all-to-pixel.sh` | Deploy all artifacts to Pixel. |
| `deploy-android-adb.sh` | Deploy Android build via ADB. |
| `build-android.sh` | Build Android binary. |
| `fleet-health.sh` | Fleet health check. |
| `verify-mutual-supervision.sh` | Verify mutual supervision (Chump–Mabel). |

## Mabel and Pixel (scripts/)

| Script | Description |
|--------|-------------|
| `mabel-explain.sh` | Explain Mabel setup/status. |
| `mabel-farmer.sh` | Mabel farmer role (e.g. due prompts). |
| `mabel-status.sh` | Mabel status. |
| `start-companion.sh` | Start companion (Mabel) on Pixel. |
| `ensure-mabel-bot-up.sh` | Ensure Mabel bot is running. |
| `restart-mabel-bot-on-pixel.sh` | Restart Mabel bot on Pixel. |
| `diagnose-mabel-model.sh` | Diagnose Mabel model (inference). |
| `apply-mabel-badass-env.sh` | Apply Mabel “badass” env. |
| `switch-mabel-to-qwen3-4b.sh` | Switch Mabel to Qwen3-4B. |
| `setup-llama-on-termux.sh` | Setup Llama on Termux. |
| `adb-connect.sh` | ADB connect to device. |
| `adb-pair.sh` | ADB pairing. |
| `capture-mabel-timing.sh` | Capture Mabel timing. |
| `parse-timing-log.sh` | Parse timing log. |

## Roles (scripts/; keep-alive and scheduled)

| Script | Description |
|--------|-------------|
| `farmer-brown.sh` | Farmer Brown role (scheduled work). |
| `keep-chump-online.sh` | Keep Chump online (restart if down). |
| `sentinel.sh` | Sentinel: monitor and alert. |
| `memory-keeper.sh` | Memory keeper role. |
| `oven-tender.sh` | Oven tender (inference readiness). |
| `hourly-update-to-discord.sh` | Hourly status update to Discord. |
| `verify-mutual-supervision.sh` | Mac → Pixel + Chump restart checks (fleet mutual supervision gate). |
| `retire-mac-hourly-fleet-report.sh` | Unload Mac LaunchAgent `ai.chump.hourly-update-to-discord` when Mabel report is source of truth. |
| `morning-briefing-dm.sh` | `curl` `/api/briefing` + `chump --notify` for a short morning Discord DM (needs `CHUMP_WEB_TOKEN`, `jq`). |

## QA and tests (scripts/)

| Script | Description |
|--------|-------------|
| `battle-qa.sh` | Run battle QA (query set). |
| `run-battle-qa-full.sh` | Full battle QA run. |
| `battle-api-sim.sh` | Black-box HTTP scenarios against running `chump --web` (no LLM). |
| `battle-cli-no-llm.sh` | CLI smoke without model (`--chump-due`). |
| `run-battle-sim-suite.sh` | Orchestrate tests + optional web API sim + optional short LLM battle. |
| `qa/generate-battle-queries.sh` | Generate battle QA queries. |
| `qa/battle-fast-queries.txt` | ~50-line curated query file for fast LLM battle. |
| `run-autonomy-tests.sh` | Run autonomy test tiers. |
| `test-tier5-self-improve.sh` | Test tier-5 self-improve. |
| `test-heartbeat-learn.sh` | Test heartbeat-learn. |
| `test-cursor-cli-integration.sh` | Test Cursor CLI integration. |
| `cursor-cli-status-and-test.sh` | Cursor CLI status and test. |
| `test-research-cursor-round.sh` | Test research Cursor round. |
| `run-tests-with-config.sh` | Run tests with config. |
| `verify-toolkit.sh` | Verify toolkit. |

## Discovery / COS (scripts/)

| Script | Description |
|--------|-------------|
| `golden-path-timing.sh` | W3.4: time `cargo build` (optional health / test compile); JSONL log; exit 1 over `GOLDEN_MAX_CARGO_BUILD_SEC`; CI uploads artifact. |
| `github-triage-snapshot.sh` | W3.1: `gh issue list` → Markdown + `[COS]` stubs (`CHUMP_TRIAGE_REPO`). |
| `ci-failure-digest.sh` | W3.2: failure excerpts + `[COS]` stub; SHA dedupe TSV (`CI_FAILURE_DEDUPE_FILE`, `--no-dedupe`). |
| `repo-health-sweep.sh` | W3.3: git/disk/cargo sanity; `REPO_HEALTH_AUTOFIX=1` chmods top-level `scripts/*.sh` only; `REPO_HEALTH_JSONL` optional. |
| `generate-cos-weekly-snapshot.sh` | COS weekly task/episode Markdown from SQLite. |
| `quarterly-cos-memo.sh` | W4.4: tasks + episodes + `git log` → `logs/cos-quarterly-YYYY-Qn.md`. |
| `scaffold-side-repo.sh` | W4.2: copy `templates/side-repo` (LICENSE, CI, README, issue template); optional `--git`. |

## Utility (scripts/)

| Script | Description |
|--------|-------------|
| `check.sh` | Build, test, clippy. |
| `check-providers.sh` | Check cascade providers. |
| `check-inference-mesh.sh` | Check inference mesh. |
| `check-network-after-swap.sh` | Check network after swap. |
| `stop-chump-discord.sh` | Stop Chump Discord process. |
| `self-reboot.sh` | Self-reboot (push + restart). |
| `chump-explain.sh` | Explain Chump (status/setup). |
| `chump-focus-mode.sh` | Focus mode. |
| `enter-chump-mode.sh` | Enter Chump mode. |
| `build-chump-menu.sh` | Build ChumpMenu app. |
| `env-default.sh` | Default env snippet. |
| `env-max_m4.sh` | Env for M4 Mac. |
| `list-heavy-processes.sh` | List heavy processes. |
| `capture-oom-context.sh` | Capture OOM context. |
| `screen-ocr.sh` | Screen OCR. |
| `start-embed-server.sh` | Start embed server (optional). |
| `start-self-improve-cycles.sh` | Start self-improve cycles. |
| `run-stories.sh` | Run stories. |
| `research-cursor-only.sh` | Research Cursor only. |
