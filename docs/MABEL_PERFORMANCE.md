# Mabel on Pixel: Performance Spec and Tuning

Performance and capacity for Mabel (Chump + llama.cpp) on Pixel 8 Pro / Termux with Vulkan. Use this to tune for speed, lower latency, or to see if you have room for a larger model.

**Quick links:** [§7.5 Deploy all to Pixel](#75-deploy-and-restart-from-mac) (single script: binary + soul + restart) · [§7.1 Diagnosing delays](#71-diagnosing-delays-our-stack-vs-model) (what gets logged, how to interpret) · [§7.2 Capturing timing](#72-capturing-timing) (capture script, `--yes`) · [§7.6 Troubleshooting](#76-troubleshooting) · SSH config: [Android Companion — SSH config](ANDROID_COMPANION.md#ssh-config-mac-to-pixel).

---

## 1. Current spec (baseline)

| Item | Value | Notes |
|------|--------|------|
| **Device** | Pixel 8 Pro | 12 GB unified RAM, Tensor G3 (Adreno 750–class GPU) |
| **Stack** | Termux, llama.cpp (Vulkan), Chump binary | Single process for bot; llama-server separate |
| **Model** | Qwen3-4B Q4_K_M GGUF (default) | ~2.5 GB file; set `CHUMP_MODEL` to override |
| **Context** | 4096 (`CHUMP_CTX_SIZE`) | KV cache; larger = more RAM, slower first token |
| **GPU layers** | 99 (`CHUMP_GPU_LAYERS`) | Full offload to Vulkan |
| **Server** | llama-server, port 8000 | OpenAI-compatible API |

**Rough memory use (typical):**

- Android OS: 3–5 GB
- llama-server (3B Q4_K_M, ctx 4096, Vulkan): ~3–4 GB (weights + KV cache + Vulkan overhead)
- Chump: ~15–30 MB
- **Total for Mabel:** ~4–5 GB → **~7–8 GB free** on a 12 GB device under normal use

So there is headroom for a larger model or a larger context, as long as you don’t run many other heavy apps at the same time.

---

## 2. Tunables (what you can change)

All of these can be set in `~/chump/.env` on the Pixel (or in `start-companion.sh`). The script reads: `CHUMP_MODEL`, `CHUMP_CTX_SIZE`, `CHUMP_GPU_LAYERS`, `CHUMP_PORT`.

| Variable | Default | Effect | When to change |
|----------|---------|--------|----------------|
| **CHUMP_CTX_SIZE** | 4096 | KV context length | Lower (2048) = less RAM, faster first token; higher (8192) = longer threads, more RAM. |
| **CHUMP_GPU_LAYERS** | 99 | Layers on GPU | 99 = full Vulkan. Lower = more CPU, less VRAM, often slower. |
| **CHUMP_MODEL** | `~/models/Qwen3-4B-Q4_K_M.gguf` | Model path | Omit to use default; or point to 7B/other GGUF. Switch script: `scripts/switch-mabel-to-qwen3-4b.sh`. |
| **CHUMP_PORT** | 8000 | Server port | Change only if 8000 is in use. |

llama-server does not expose a separate “batch size” in the same way as some backends; concurrency is mostly “one request at a time” for a single Discord user. So tuning is mainly: **model size**, **context size**, and **GPU layers**.

---

## 3. Optimization options

### 3.1 Reduce latency (faster first reply)

- **Lower context:** e.g. `CHUMP_CTX_SIZE=2048`. Saves RAM and speeds up prefill; shorter conversation history.
- **Keep 3B:** 3B is already one of the faster options; going to 7B will be slower per token and use more RAM.
- **Vulkan:** Already best option on Tensor G3; CPU-only would be much slower (3–5× in typical setups).

### 3.2 Free RAM for other apps or for a bigger model

- **Lower context:** `CHUMP_CTX_SIZE=2048` (or 3072) frees a few hundred MB.
- **Close other apps** so Android doesn’t kill Termux when memory is tight.

### 3.3 Slightly better quality (same device)

- **Try 7B:** e.g. Qwen 2.5 7B Instruct Q4_K_M (~4.5 GB). Fits in ~6 GB with ctx 4096 if you have ~7–8 GB free. Download and set `CHUMP_MODEL` to the 7B GGUF path, then restart.
- **Keep ctx 4096** for 7B if RAM allows; lowering to 2048 also works if you hit OOM.

---

## 4. Bigger models: do we have room?

**Yes, with limits.**

- **7B Q4_K_M (e.g. Qwen 2.5 7B):**  
  - Weights ~4.5 GB, plus KV cache (e.g. 4096) and Vulkan overhead → **~6–7 GB** for llama-server.  
  - With 12 GB total and ~4 GB for Android + Chump, you’re at the edge; **close other apps** and try. If it’s stable, you have room for 7B.

- **Larger (e.g. 14B Q3, ~6 GB weights):**  
  - Would need ~8 GB+ for server; on 12 GB device that’s **tight** and may OOM or get killed. Not recommended unless you’re on a device with more RAM.

**Recommendation:**  
- Stay on **3B** for lowest latency and safest RAM.  
- If you want better quality and have **~7–8 GB free** (and few other apps), try **7B** and watch for OOM or Termux being killed; reduce `CHUMP_CTX_SIZE` if needed.

---

## 5. Quick reference: env for tuning

Add or edit in `~/chump/.env` on the Pixel:

```bash
# Optional: smaller context (faster, less RAM)
# CHUMP_CTX_SIZE=2048

# Optional: 7B model (better quality, more RAM)
# CHUMP_MODEL=$HOME/models/qwen2.5-7b-instruct-q4_k_m.gguf
```

Then restart: `pkill -f 'chump --discord'`; `pkill -f llama-server`; `cd ~/chump && ./start-companion.sh`.

---

## 6. Max Mabel on Pixel (all tools, lean device)

**Goal:** Mabel has every tool and capability that makes sense on the Pixel; the device stays fast. Only leave **unset** the env that is meaningless or dev-only there.

### Do not set (device-irrelevant or dev-only)

| Variable | Why |
|----------|-----|
| **CHUMP_REPO** / **CHUMP_HOME** | No codebase on the phone; avoids giant repo block in the system prompt. |
| **CHUMP_WARM_SERVERS** | Ollama warm-the-ovens — irrelevant on Pixel (you use llama-server). |
| **CHUMP_CURSOR_CLI** | Cursor is not on the Pixel. |
| **CHUMP_PROJECT_MODE** | Would override your custom soul with the Chump dev-buddy soul. |

Optionally omit **CHUMP_GITHUB_REPOS** / **GITHUB_TOKEN** if you don't need GitHub from the device; if you do, set them and Mabel gets GitHub tools.

### Do set (max capabilities)

- **Required:** `DISCORD_TOKEN`, `OPENAI_API_BASE`, `OPENAI_API_KEY`, `OPENAI_MODEL`, `CHUMP_SYSTEM_PROMPT` (e.g. badass soul from [MABEL_FRONTEND.md](MABEL_FRONTEND.md) or `apply-mabel-badass-env.sh`).
- **Companion routing:** Set **CHUMP_MABEL=1** so the system prompt gets the short "Tools (companion)" list instead of the full dev routing table. The apply script sets this automatically.
- **For full tool set:**  
  - **TAVILY_API_KEY** — web search; set if you have a key.  
  - **CHUMP_DELEGATE** + worker URL — summarize/extract; set if you have a delegate worker.  
  - **CHUMP_CLI_ALLOWLIST** (and optionally **CHUMP_CLI_BLOCKLIST**) — run_cli; use a sensible allowlist so she can run only safe commands (e.g. `date`, `uptime`); empty allowlist means any command is allowed (risky on Pixel).
- **Already available** from `~/chump`: memory, calculator, read_url, task, ego, episode, schedule, memory_brain, notify, read_file/list_dir/write_file/edit_file (paths under ~/chump). No extra env needed for these.
- **Optional:** `CHUMP_CTX_SIZE=4096` (default) or `2048` for slightly faster first token.

### Soul and tools

The soul (`CHUMP_SYSTEM_PROMPT`) should describe the tools Mabel actually has so she uses them correctly. The `apply-mabel-badass-env.sh` soul lists: memory, calculator, file tools (read_file, list_dir, write_file, edit_file under ~/chump), task, schedule, notify, ego, episode, memory_brain, read_url, web_search (when TAVILY set), and run_cli (only when allowed). With **CHUMP_MABEL=1**, the code appends a short "Tools (companion)" routing block; without it, the full dev routing table is appended (verbose and mostly irrelevant on Pixel). Recommend **CHUMP_CLI_ALLOWLIST** (e.g. comma-separated commands like `date,uptime`) so run_cli is restricted to safe commands.

### Android: keep the device lean and fast

- **Settings → Developer options** (or **Accessibility**): reduce or turn off **window/transition/animator scale** to reduce UI lag.
- **Settings → Apps**: limit or disable background apps you don't need so more RAM and CPU stay for Termux.
- **Termux → Battery**: set to **Unrestricted** (or "Don't optimize") so Android doesn't kill the bot or sshd in the background.

See also: [Chump Android Companion](ANDROID_COMPANION.md) for deploy and one-time setup.

### Apply on the Pixel (badass soul + lean env)

**Option A — run the script (after deploy):**  
From Termux on the Pixel (or from Mac via SSH):

```bash
# After deploy: script is in ~/chump or ~/storage/downloads/chump
bash ~/chump/apply-mabel-badass-env.sh
# or
bash ~/storage/downloads/chump/apply-mabel-badass-env.sh
```

The script backs up `~/chump/.env`, strips the "do not set" vars, sets `CHUMP_SYSTEM_PROMPT` to the badass soul, and restarts the bot (llama-server is left running).

**Option B — by hand:**  
Edit `~/chump/.env`: remove any lines for `CHUMP_REPO`, `CHUMP_HOME`, `CHUMP_WARM_SERVERS`, `CHUMP_CURSOR_CLI`, `CHUMP_PROJECT_MODE`. Set `CHUMP_SYSTEM_PROMPT` to the badass line from [MABEL_FRONTEND.md](MABEL_FRONTEND.md). Then: `pkill -f 'chump --discord'`; `cd ~/chump && nohup ./start-companion.sh --bot >> ~/chump/logs/companion.log 2>&1 &`.

---

## 7. Measuring (if you want numbers)

- **Token throughput:** In Termux, watch llama-server stdout or logs while Mabel replies; many builds print tokens/sec or you can infer from timestamps.
- **RAM:** `top` or `procrank` (if available) in Termux; or Android Settings → Apps → Termux → Memory.
- **Stability:** If Termux or the bot is killed in the background, try lowering `CHUMP_CTX_SIZE` or switching back to 3B.

### 7.1 Diagnosing delays (our stack vs model)

**What gets logged:** With `CHUMP_LOG_TIMING=1` in `~/chump/.env` on the Pixel (and the bot restarted), each Discord turn produces one **turn line** and zero or more **API lines**:

- **Turn line:** `[timing] request_id=… turn_ms=… ovens_ms=… memory_ms=… build_agent_ms=… agent_run_ms=… strip_ms=…`
- **API line (per LLM request):** `[timing] api_request_ms=… status=…` and, when the server returns it, `prompt_tokens=… completion_tokens=…`

Logs go to stderr; when you start with `start-companion.sh --bot >> ~/chump/logs/companion.log 2>&1`, they end up in `~/chump/logs/companion.log`. The code flushes stderr after each timing line so lines appear in the log immediately (no buffering). The sum of all `api_request_ms` lines between two turn lines is the “time in the model API” for that turn; the rest of `agent_run_ms` is agent loop and tool execution.

**How to interpret:**

| Observation | Likely cause |
| ----------- | ------------- |
| `agent_run_ms` ≈ sum of `api_request_ms` for that turn | Time is in the model (inference + network). Our loop/tools add little. |
| `agent_run_ms` >> sum of `api_request_ms` | Tool execution or extra rounds in the agent loop is adding delay. |
| `build_agent_ms` or `memory_ms` large | Prep (agent build, memory recall) is significant; consider caching or optimizing. |
| First message after restart much slower than the next | llama-server first-request cold start (model/GPU init). |
| `api_request_ms` large (e.g. 5–30s) for 3B on Pixel | Inference-bound; reduce context, use smaller model, or accept device limits. |

### 7.2 Capturing timing

**On the Pixel:** After enabling timing and restarting, run 5–10 representative turns (short reply, one that may use memory, one that may use tools). Then:

```bash
grep '[timing]' ~/chump/logs/companion.log | tail -n 100
```

Save that output (or the full log) and copy it to your Mac if you want to parse it there.

**From the Mac (SSH):** When the Pixel is reachable via SSH (same Wi‑Fi or Tailscale), you can capture and parse in one go. See [Android Companion — SSH config](ANDROID_COMPANION.md#ssh-config-mac-to-pixel) for `~/.ssh/config`. From the Chump repo root:

```bash
./scripts/capture-mabel-timing.sh [--yes] termux 90
```

- **Without `--yes`:** The script asks “Is the bot already running with timing enabled? (y/n)”. Answer **y** if the bot is running with `CHUMP_LOG_TIMING=1`; answer **n** to exit, then restart the bot on the Pixel and run the script again.
- **With `--yes`:** Skips the prompt (for non-interactive or scripted runs).

The script: (1) SSHs to the host `termux`, (2) ensures `CHUMP_LOG_TIMING=1` is in `~/chump/.env`, (3) prompts unless `--yes`, (4) captures `[timing]` lines for 90 seconds and prints **“Send 5–7 messages to Mabel in Discord now”**, (5) when the capture ends, parses and prints per-turn summary and min/max/avg. Raw lines are written to `docs/mabel-timing-capture.txt` (gitignored). Use a different SSH host or duration: `./scripts/capture-mabel-timing.sh --yes user@192.168.1.x 120`.

### 7.3 Parsing and baseline

**Parse a log (on the Mac):** To turn raw `[timing]` lines into per-turn stats (turn_ms, agent_run_ms, api_sum_ms, overhead_ms) without eyeballing:

```bash
./scripts/parse-timing-log.sh [--summary] [path/to/companion.log]
```

With `--summary`, the script also prints min/max/avg turn_ms and agent_run_ms over the parsed segment. If you omit the file path, it reads stdin (e.g. `cat docs/mabel-timing-capture.txt | ./scripts/parse-timing-log.sh --summary`).

**Baseline:** Keep a snapshot of `[timing]` lines for your current config so you can compare before/after tuning. See [mabel-timing-baseline.txt](mabel-timing-baseline.txt) for how to capture; optionally copy a capture into that file or into `docs/mabel-timing-capture.txt`.

### 7.4 Optimization loop

1. Enable timing (`CHUMP_LOG_TIMING=1`), restart the bot.
2. Capture 5–10 representative turns (on-Pixel or from Mac with `capture-mabel-timing.sh`).
3. Parse and interpret using the table in §7.1.
4. Change **one** lever (e.g. `CHUMP_CTX_SIZE`, model size), restart, re-capture and re-parse to compare.

### 7.5 Deploy and restart from Mac

**Single deploy all (fast path):** Build, push binary + scripts, apply Mabel env (soul, CHUMP_MABEL=1), and restart in one command:

```bash
./scripts/deploy-all-to-pixel.sh [termux]
```

Use this when you want the Pixel to have the latest binary **and** latest soul/env in one go.

**Binary-only deploy:** To only push the built binary and restart (no env/soul refresh):

```bash
./scripts/deploy-mabel-to-pixel.sh [termux]
```

- **What it does:** (1) Runs `build-android.sh` (requires Android NDK). (2) Stops the bot on the Pixel via SSH. (3) Uploads the new binary as `~/chump/chump.new` (so the running binary isn’t overwritten in place). (4) Replaces `~/chump/chump` with `chump.new`, updates `start-companion.sh` if present, starts the bot. (5) Prints the last few log lines.
- **Default host:** `termux` (from `~/.ssh/config`). Override with the first argument. Port 8022 unless `DEPLOY_PORT` is set.
- **After running:** Send a Discord message to Mabel; then `ssh termux 'grep "[timing]" ~/chump/logs/companion.log | tail -5'` to confirm timing lines appear.

Use `deploy-all-to-pixel.sh` after code or soul/env changes so the Pixel gets the new binary and .env in one run.

**Script-only deploy (no Android build):** When you only changed `start-companion.sh` or other scripts (e.g. model-not-loaded fix), push the script and optionally restart the bot:

```bash
# From Chump repo root
scp -P "${DEPLOY_PORT:-8022}" scripts/start-companion.sh termux:~/chump/
ssh -p "${DEPLOY_PORT:-8022}" termux "chmod +x ~/chump/start-companion.sh"
# Optional: restart bot so next full start uses the new script
./scripts/restart-mabel-bot-on-pixel.sh
```

The updated `start-companion.sh` is used the next time you run a full companion start (server + bot) on the Pixel; it waits for the model to be ready (POST /v1/chat/completions 200) before starting the bot.

**Bulletproof deployment:** All deploy/restart scripts use retries and robust SSH/SCP options (keepalives, longer timeouts) so transient failures don't kill the deploy. Restart: up to 3 attempts with 5s backoff; single SSH with keepalives so the connection doesn't drop during pkill/start/check. Deploy: SCP and final SSH each retry up to 3 times. Optional env: `RESTART_MABEL_MAX_ATTEMPTS`, `RESTART_MABEL_RETRY_SLEEP`, `DEPLOY_SCP_MAX_ATTEMPTS`, `DEPLOY_SSH_MAX_ATTEMPTS`, `DEPLOY_RETRY_SLEEP`, `DEPLOY_ALL_SSH_MAX_ATTEMPTS`. **Run full deploy from a terminal** so the Android build (5–10 min) isn't killed by a runner timeout.

**Good to go:** Mabel on the Pixel is ready when the model is loaded and the API accepts requests. From the Mac run:

```bash
./scripts/diagnose-mabel-model.sh
```

You're good when the output shows: model file present, llama-server process running, **GET /v1/models** HTTP 200, and **POST /v1/chat/completions** HTTP 200. If you see 503 or "model not loaded", use the updated `start-companion.sh` (script-only deploy above) and restart; the client also retries once after 15s when it sees "model not loaded".

### 7.6 Troubleshooting

| Issue | What to do |
| ----- | ---------- |
| **No `[timing]` lines in the log** | The Pixel must be running a binary that includes the timing code and has `CHUMP_LOG_TIMING=1` in `~/chump/.env`. Run [§7.5](#75-deploy-and-restart-from-mac) to build, deploy, and restart. After deploying, send at least one Discord message so a turn completes. |
| **Timing lines appear only after the process exits** | Old builds didn’t flush stderr; lines were buffered. Current code flushes after each timing line. Redeploy with `deploy-mabel-to-pixel.sh`. |
| **`scp` to `~/chump/chump` fails (e.g. “dest open … Failure”)** | The running process holds the file open. Use `deploy-mabel-to-pixel.sh`, which stops the bot, uploads to `chump.new`, then replaces `chump` and restarts. |
| **llama-server not running (Error: error sending request for url … 8000)** | Timing lines are still written for each turn (turn_ms, build_agent_ms, etc.); API lines may show errors. Start llama-server on the Pixel (e.g. `./start-companion.sh` without `--bot`, or start the server in another session) so Mabel can complete model calls and you get full api_request_ms data. |
| **"model not loaded" (503 or in error body)** | llama-server can return 200 on `/v1/models` before the model finishes loading; `/v1/chat/completions` then returns 503 with "model not loaded". **Fix:** Use the updated `start-companion.sh` (it now waits for a successful chat completion, not just `/v1/models`). From Mac run `./scripts/diagnose-mabel-model.sh` to confirm model file, llama-server process, and API responses. The client retries and waits 15s once when it sees "model not loaded". |
| **Mabel replies "model temporarily unavailable (circuit open for 30s)"** | The client circuit breaker opened after 3 failures (often timeouts). On Pixel, turns can be 5+ min; the default request timeout is 300s. In `~/chump/.env` set **`CHUMP_MODEL_REQUEST_TIMEOUT_SECS=420`** (or 600) so long turns don't timeout. Optionally **`CHUMP_CIRCUIT_FAILURE_THRESHOLD=5`** so the circuit is less sensitive. Restart the bot to clear the circuit: from the Mac run **`./scripts/restart-mabel-bot-on-pixel.sh`**, or on the Pixel: `pkill -f 'chump.*--discord'` then `./start-companion.sh --bot`. |
| **SSH connection timed out or permission denied** | See [Android Companion — SSH config](ANDROID_COMPANION.md#ssh-config-mac-to-pixel): correct `User` (Termux `whoami`), same network or Tailscale, sshd running in Termux. |

**Scripts reference (run from Chump repo root):**

| Script | Purpose |
| ------ | ------- |
| `./scripts/deploy-all-to-pixel.sh [host]` | **Single deploy all:** build, push binary + start-companion + apply-mabel-badass-env, run apply script (soul, CHUMP_MABEL=1), restart. Use this to move fast. |
| `./scripts/deploy-mabel-to-pixel.sh [host]` | Build for Android, push binary + start-companion to Pixel, stop bot, replace binary, start bot. Binary-only deploy. |
| `./scripts/restart-mabel-bot-on-pixel.sh` | From Mac: restart Mabel on Pixel. **When Pixel is on USB:** uses ADB to forward port 8022, then SSH over the cable (no WiFi). Otherwise SSH to `PIXEL_SSH_HOST` (termux). Set `PIXEL_USE_ADB=1` to force ADB. Requires Termux sshd on 8022. |
| `./scripts/diagnose-mabel-model.sh [host]` | From Mac: SSH to Pixel, print model file, llama-server process, last log lines, GET /v1/models and POST /v1/chat/completions. Use when you see "model not loaded" or want to confirm the model is ready. |
| `./scripts/capture-mabel-timing.sh [--yes] [host] [sec]` | SSH to Pixel, ensure timing env, capture `[timing]` lines for N seconds while you send Discord messages, then parse and print summary. |
| `./scripts/parse-timing-log.sh [--summary] [file]` | Parse raw `[timing]` lines from a log or stdin; print per-turn turn_ms, agent_run_ms, api_sum_ms, overhead_ms; `--summary` adds min/max/avg. |

See also: [Chump Android Companion](ANDROID_COMPANION.md) (model table, RAM budget, Vulkan build).

---

## 8. System capacity on the Pixel (for additional improvements)

What you have in place on the Pixel and where there’s room to grow:

**Stack**
- **Termux** with persistent **sshd** (port 8022), so you can deploy and run commands from the Mac.
- **llama-server** (llama.cpp + Vulkan) on port 8000, OpenAI-compatible; **Chump** (Mabel) as the Discord bot.
- **Sessions and memory** under `~/chump/sessions` (SQLite, FTS5); logs under `~/chump/logs`.
- **Scripts** in `~/chump` or `~/storage/downloads/chump`: setup-termux-once, setup-llama-on-termux, setup-and-run, start-companion, **apply-mabel-badass-env**; deploy from Mac via ADB or SSH.

**Resource headroom (12 GB Pixel 8 Pro)**
- Typical use: Android ~3–5 GB, llama-server (3B + Vulkan) ~3–4 GB, Chump ~15–30 MB → **~7–8 GB free**.
- So you have capacity for: **7B model** (if you close other apps), **larger context** (e.g. 8192 with 3B), or keeping 3B and using the free RAM for other services (e.g. a small web UI or bridge).

**Levers for improvement**
- **Model:** Switch to 7B (see §4) for better quality; stay on 3B for lowest latency.
- **Context:** `CHUMP_CTX_SIZE` (e.g. 2048 vs 4096) trades RAM and first-token speed for conversation length.
- **Tools:** Set **TAVILY_API_KEY** for web search, **CHUMP_DELEGATE** for summarize/extract, **CHUMP_CLI_ALLOWLIST** for run_cli; see §6.
- **Device:** Reduce animations, limit background apps, Termux battery Unrestricted (§6) so the bot and SSH stay reliable.
- **Future:** Custom chat UI can talk to Mabel via Discord (Option A in [MABEL_FRONTEND.md](MABEL_FRONTEND.md)) or, if you add an HTTP/WebSocket chat API to Chump, directly to the Pixel.
