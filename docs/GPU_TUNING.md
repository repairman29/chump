# GPU and memory tuning (MacBook / Apple Silicon)

To get the most out of vLLM-MLX and Chump on a MacBook: free GPU/RAM by shutting down unneeded processes, then tune vLLM-MLX env vars. This keeps the 14B model stable and responsive.

## 1. Shed load: quit apps that compete for GPU/RAM

**Manual (one-off):** Run **Enter Chump mode** before heavy AI use:

```bash
./scripts/enter-chump-mode.sh
```

This stops Ollama and the embed server (ports 11434, 18765), then quits every app listed in **scripts/chump-mode.conf**. Protected: rust-agent, vLLM, Python, Window Server, etc. are never killed.

**Scheduled (role):** Install the **shed-load** launchd job so Chump mode runs automatically (e.g. every 2 hours):

```bash
./scripts/install-roles-launchd.sh   # includes shed-load
```

Shed-load uses **StartInterval 7200** (2 h). To change the interval, edit `~/Library/LaunchAgents/ai.chump.shed-load.plist` and set a different `StartInterval`, then `launchctl unload` / `launchctl load` the plist.

**Configure what gets quit:** Edit **scripts/chump-mode.conf**. Each uncommented line is a process name (killed with `killall`) or `bundle:BUNDLE_ID` (graceful quit via AppleScript). Comment out any app you want to keep (e.g. Cursor, Safari). To see heavy processes and add candidates:

```bash
./scripts/list-heavy-processes.sh    # top RAM + known GPU-heavy apps → logs/heavy-processes.log
```

Logs: **logs/chump-mode.log**.

## 2. vLLM-MLX: squeeze the GPU

These env vars control how much GPU/memory vLLM-MLX uses. Set them in `.env` or before running `./serve-vllm-mlx.sh`.

| Variable | Default (serve-vllm-mlx.sh) | Purpose | Squeeze more | If OOM / crash |
|----------|----------------------------|---------|--------------|----------------|
| `VLLM_MAX_NUM_SEQS` | 1 | Max concurrent sequences | 2 if stable | Keep 1 |
| `VLLM_MAX_TOKENS` | 8192 | Max tokens per response | 16384 if stable | 4096 |
| `VLLM_CACHE_PERCENT` | 0.15 | Fraction of memory for KV cache | 0.18 if stable | 0.12 |
| `VLLM_WORKER_MULTIPROC_METHOD` | spawn | Fork safety on macOS | — | — |
| `MLX_DEVICE` | (GPU) | Device | — | `cpu` (slower, no Metal) |

**Conservative (default):** Safe for 14B on typical Apple Silicon; avoids Metal OOM.

**Squeeze more (if stable):** After shed-load and no crashes for a while, try in `.env`:

```bash
VLLM_MAX_NUM_SEQS=2
VLLM_MAX_TOKENS=16384
VLLM_CACHE_PERCENT=0.18
```

Restart vLLM after changing. If Python/Metal crashes again, revert to defaults or lower values.

**If OOM or Python crash:** Lower memory use:

```bash
VLLM_MAX_TOKENS=4096
VLLM_CACHE_PERCENT=0.12
```

Or use a smaller model: `VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit`. As a last resort, `MLX_DEVICE=cpu ./serve-vllm-mlx.sh` (no GPU, slower).

## 3. Order of operations

1. **Shed load** (manual or role) so browsers, Slack, etc. are not using GPU/RAM.
2. **Start vLLM-MLX** with the chosen env (default or tuned).
3. Run Chump (Discord, heartbeats) so they get maximum headroom.

## 4. Suppressing macOS bloat

On a 24GB machine running a large model, every MB matters. Beyond quitting apps (shed-load / chump-mode), you can reduce macOS background load.

**Focus-mode script (run before heavy Chump sessions):**

```bash
./scripts/chump-focus-mode.sh
```

This kills Safari, Chrome, Cursor, Mail, Messages, Music, News, Stocks, and the daemons below (if running); optionally pauses Spotlight indexing; then prints top memory users and port 8000 status. Use before overnight heartbeat or when you need max headroom.

**One-time: disable macOS background agents** (run these yourself; they persist across reboots until you re-enable):

```bash
# Spotlight indexing — big CPU/memory consumer
sudo mdutil -a -i off
# Turn back on later: sudo mdutil -a -i on

# Siri / assistant
launchctl disable user/$(id -u)/com.apple.assistantd
launchctl disable user/$(id -u)/com.apple.Siri.agent

# Photos analysis (face recognition, ML — uses GPU)
launchctl disable user/$(id -u)/com.apple.photoanalysisd

# Spotlight suggestions / knowledge
launchctl disable user/$(id -u)/com.apple.knowledge-agent
launchctl disable user/$(id -u)/com.apple.suggestd

# Game Center, Sharing (AirDrop)
launchctl disable user/$(id -u)/com.apple.gamed
launchctl disable user/$(id -u)/com.apple.sharingd   # omit if you use AirDrop
```

Then kill running instances so they don’t restart until next login:

```bash
killall -9 assistantd photoanalysisd suggestd knowledge-agent gamed 2>/dev/null || true
```

Re-enable any service with `launchctl enable user/$(id -u)/com.apple.<name>`.

**System Settings (once):** Turn off Siri, AirDrop/Handoff if unused, iPhone Widgets on desktop, Stage Manager if on. Under General → AirDrop & Handoff disable what you don’t need. Under Privacy & Security → Analytics uncheck everything to reduce diagnostic daemons.

**Browser discipline:** Safari and Chrome use the most memory after the model. If you need a browser while Chump runs, use Safari with few tabs (better under memory pressure than Chrome), or close browsers entirely for heavy workloads.

**See what’s using memory now:**

```bash
ps -eo pid,rss,comm | sort -k2 -rn | head -20
```

## 5. Investigating OOM / Metal crashes

When vLLM-MLX keeps crashing (Python exits with Metal OOM, NSException, or SIGSEGV), use this runbook. **When vLLM crashes (OOM):** run `./scripts/capture-oom-context.sh` to snapshot context (and optionally `./scripts/list-heavy-processes.sh` for a fuller process list); then follow the steps below. See also [OPERATIONS.md](OPERATIONS.md) (restart-if-down, Oven Tender).

### 5.1 Capture context

After a crash, run:

```bash
./scripts/capture-oom-context.sh        # default: last 200 lines of vLLM log
./scripts/capture-oom-context.sh 300   # or more lines if needed
```

Optionally: `./scripts/list-heavy-processes.sh` for a fuller process list. Open `logs/oom-context-<timestamp>.txt` and `logs/vllm-mlx-8000.log` and look for:

- Metal allocation errors, "leaked semaphore", NSException, SIGSEGV.
- Whether the crash was during **model load** (e.g. "Fetching 10 files") vs **during inference** (first suggests not enough free memory at startup; second suggests cache/sequence length or a burst of requests).

### 5.2 Verify mitigations

- **Concurrency:** `CHUMP_MAX_CONCURRENT_TURNS=1` in `.env`; heartbeats on 8000 use HEARTBEAT_LOCK (see [env-max_m4.sh](../scripts/env-max_m4.sh) and heartbeat scripts).
- **Before heavy runs:** Run `./scripts/chump-focus-mode.sh` and/or `./scripts/enter-chump-mode.sh`; consider one-time macOS bloat steps (Spotlight off, disable Siri/photoanalysisd, etc.) in section 4 above.
- **Server params:** In `.env` or environment, do not *raise* `VLLM_MAX_NUM_SEQS` / `VLLM_MAX_TOKENS` / `VLLM_CACHE_PERCENT` until stable. If already at defaults and still OOM, **lower** them (e.g. `VLLM_MAX_TOKENS=4096`, `VLLM_CACHE_PERCENT=0.12`) or switch to 7B.

### 5.3 If OOM during load

Free memory (focus mode + enter-chump-mode), kill any stale vLLM (`pkill -f "vllm-mlx serve"`), then start once by hand: `./serve-vllm-mlx.sh`. If it still exits during "Fetching 10 files" / load, try `MLX_DEVICE=cpu ./serve-vllm-mlx.sh` to rule out Metal init bugs.

### 5.4 If OOM during inference

Reduce `VLLM_MAX_TOKENS` and `VLLM_CACHE_PERCENT`; keep `VLLM_MAX_NUM_SEQS=1`; ensure no concurrent Discord + heartbeat (both caps above). If crashes persist, try 7B or CPU fallback.

### 5.5 Optional: capture before restart

If you use `restart-vllm-if-down.sh` or Oven Tender, they can call `./scripts/capture-oom-context.sh` once *before* starting vLLM so the log tail reflects the crashed run. See the script comments and [OPERATIONS.md](OPERATIONS.md).

### 5.6 Client-side context (informational)

The client caps conversation to `CHUMP_MAX_CONTEXT_MESSAGES` (default 20); the server's `--max-tokens` (e.g. 8192) caps response length. No code change needed for investigation; this is for future tuners.

---

See also: [OPERATIONS.md](OPERATIONS.md) (vLLM-MLX on 8000, Oven Tender, restart-if-down), [serve-vllm-mlx.sh](../serve-vllm-mlx.sh) (defaults and comments).
