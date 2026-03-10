# Chump as a service: minimal always-on + warm the ovens

Run Chump (Discord bot) so it stays up across sleep/wake and **does not** keep the MLX model servers running. When you message Chump, the bot starts the servers on demand (“warm the ovens”), then replies.

## 1. Enable warm-the-ovens

In `.env` or your shell:

```bash
export CHUMP_WARM_SERVERS=1
export OPENAI_API_BASE=http://localhost:8000/v1
```

If you run the bot from a different working directory (e.g. a service), set the repo root:

```bash
export CHUMP_HOME=/Users/jeffadkins/Projects/Maclawd/rust-agent
```

Behavior:

- **First message after start:** Bot runs `scripts/warm-the-ovens.sh`, which starts `./serve-vllm-mlx.sh` if port 8000 is not up, waits until the server is ready (up to 90s), then runs the agent. If the script times out, Chump replies: “Ovens are warming up — give it a minute and try again.”
- **Later messages:** Port is already up, so the script exits immediately and the agent runs as usual.
- Servers stay running until you stop them or reboot; they are not shut down after each message.
- **Heartbeat:** This is the on-demand wake for the heavy model. For orchestrator–worker, the same pattern applies: warm-the-ovens runs when needed; an optional scout/cron can be added later (see [ORCHESTRATOR_WORKER.md](ORCHESTRATOR_WORKER.md)).

Optional second model on 8001: set `WARM_PORT_2=8001` (and optionally `WARM_MODEL_2=...`) in `.env` or before the script runs; warm-the-ovens will start 7B on 8001 as well. **For 30B only** (free ~4.5 GB for testing or embed server), leave `WARM_PORT_2` unset and do not start 8001; the delegate worker then uses 8000 when `CHUMP_WORKER_API_BASE` is unset. To use 7B for the worker, run 8001 and set `CHUMP_WORKER_API_BASE=http://localhost:8001/v1`.

## 2. Keep Chump running (macOS launchd)

To have Chump start at login and restart after sleep, run it as a user LaunchAgent.

1. Create the plist (replace `YOUR_USER` and the path if needed):

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/ai.openclaw.chump.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>bash</string>
    <string>-lc</string>
    <string>cd /Users/YOUR_USER/Projects/Maclawd/rust-agent && source .env 2>/dev/null; export CHUMP_WARM_SERVERS=1 OPENAI_API_BASE=http://localhost:8000/v1; exec ./run-discord.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump.err.log</string>
</dict>
</plist>
PLIST
```

Replace `YOUR_USER` with your macOS username. If your token is only in `.env`, ensure the `bash -lc` command runs from the repo dir so `source .env` finds it (or set `DISCORD_TOKEN` in the plist / a separate env file and load that). If `cargo` or `vllm-mlx` are not found when the agent runs, add `<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:YOUR_HOME/.cargo/bin:YOUR_HOME/.local/bin</string></dict>` to the plist (replace YOUR_HOME with your home path).

2. Load and start:

```bash
launchctl load ~/Library/LaunchAgents/ai.openclaw.chump.plist
```

3. To stop or unload:

```bash
launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump.plist
```

4. Logs:

```bash
tail -f /tmp/chump.out.log /tmp/chump.err.log
```

With this, Chump stays running with no MLX servers until you (or someone) send a message; then the ovens warm once and stay warm until you stop the servers or reboot.

## 3. Optional: semantic memory (embed server)

For recall by meaning (e.g. "the upgrades" → "30B model setup"), run the **local embed server** in addition to Chump. It can share the same machine; no API keys.

1. Install once: `pip install -r scripts/requirements-embed.txt`
2. Start in a separate terminal (or a second LaunchAgent): `./scripts/start-embed-server.sh`
3. Default URL is `http://127.0.0.1:18765`. If the Chump process sees this (same host), it will use semantic recall automatically. Override with `CHUMP_EMBED_URL` in the Chump env if needed.

If the embed server is not running, Chump falls back to keyword-only recall. For all degradation behavior (embed, SQLite, model server), see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)#degradation-and-fallbacks and [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md).

## 4. Optional: overnight heartbeat (learn / self-improve)

Run Chump in short learning rounds for a set duration (e.g. 8 hours). Each round sends a self-improvement prompt; Chump uses **web_search** (Tavily) and stores learnings in **memory**. Builds skills and context over time.

**Requirements:** `TAVILY_API_KEY` in `.env` (get a key at tavily.com). Model server on 8000 (start manually or set `CHUMP_WARM_SERVERS=1` so the script warms the ovens once at start).

**Run (default 8h, one round every 45 min):**

```bash
cd rust-agent
./scripts/heartbeat-learn.sh
```

**Options (env):**

- `HEARTBEAT_DURATION` — e.g. `8h`, `4h`, `30m` (default `8h`)
- `HEARTBEAT_INTERVAL` — time between rounds, e.g. `45m`, `30m` (default `45m`)
- `CHUMP_WARM_SERVERS=1` — run warm-the-ovens once at start so port 8000 (and optionally 8001) are up

**Log:** `logs/heartbeat-learn.log` (append). Prompts rotate through topics: Rust, LLM agents, macOS automation, debugging, Discord bots, prompt engineering, semantic memory, security. Never commit `TAVILY_API_KEY`; keep it in `.env` only.

**Stable overnight runs:** Build the release binary once from a normal terminal (not inside Cursor’s sandbox): `cargo build --release`. The script then uses `target/release/rust-agent` and does not run `cargo run`, avoiding recompiles and sandbox-related build failures (e.g. libsqlite3-sys).

**Preflight (8000/8001):** The script checks 8000 first, then tries to start it via warm-the-ovens, then falls back to 8001. To see which port would be used without running a round: `./scripts/check-heartbeat-preflight.sh` (prints the port or exits 1).

**Testing the heartbeat:**

- **Quick run (2m, 15s interval):** `HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-learn.sh` — two rounds for fast validation.
- **Smoke test:** `./scripts/test-heartbeat-learn.sh` — runs 1m/20s and asserts preflight, one round, and completion in the log (passes even if the round exits non-zero, e.g. model busy).
- **Retry on failure:** `HEARTBEAT_RETRY=1 ./scripts/heartbeat-learn.sh` — retries each failed round once before sleeping (helps with transient connection errors).

**When Chump is paused** (see Kill switch below), the heartbeat script can skip rounds: check for `logs/pause` or `CHUMP_PAUSED=1` before each round and exit or sleep if set.

## 5. Kill switch (pause)

To stop Chump from running the agent **without killing the process** (e.g. for maintenance or to avoid processing messages while you fix the model server):

- **File:** Create `logs/pause` in the Chump working directory (e.g. `touch rust-agent/logs/pause`). The Discord handler will respond to every message with “I’m paused.” and will not call the model or tools.
- **Env:** Set `CHUMP_PAUSED=1` (or `true`) in the Chump process environment. Same behavior as the file.

Remove the file or unset the env and the next message will run the agent again. Useful with launchd: leave the process running but paused, then unpause without restarting.

## 6. Health endpoint and structured logging

- **Health:** If `CHUMP_HEALTH_PORT` is set (e.g. `18766`), Chump starts a minimal HTTP server on that port. `GET http://localhost:18766/health` returns 200 and JSON `{ "model": "ok"|"down"|"n/a", "embed": "ok"|"down"|"n/a", "memory": "ok"|"down" }` by probing the model server (OPENAI_API_BASE), embed server, and SQLite. Chump Menu or scripts can call it to show “ready” or “degraded.”
- **Structured logs:** Set `CHUMP_LOG_STRUCTURED=1` so each line in `logs/chump.log` is JSON (e.g. `ts`, `event`, `channel_id`, `request_id`, `reply_len`). Default remains plain text.
- **Request ID:** Each Discord turn gets a short `request_id`; it is included in every log line for that turn so you can `grep` one conversation.

For **secrets redaction**, **input caps** (message and tool-args length), and **optional rate limit**, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)#security-and-limits.
