# Performance review

Summary of performance-related settings, bottlenecks, and how to tune for a MacBook running Chump on vLLM-MLX (8000).

---

## 1. Model server (vLLM-MLX)

| Setting | Default | Effect |
|--------|---------|--------|
| `VLLM_MAX_NUM_SEQS` | 1 | Concurrent sequences; 2 can improve throughput if no OOM |
| `VLLM_MAX_TOKENS` | 8192 | Max tokens per response; 16384 if stable |
| `VLLM_CACHE_PERCENT` | 0.15 | KV cache memory; 0.18 if stable, 0.12 if OOM |
| `VLLM_WORKER_MULTIPROC_METHOD` | spawn | Fork safety on macOS (keep) |

**Bottleneck:** Single shared model (8000). Only one real “user” at a time; heartbeats and Discord share it. `CHUMP_MAX_CONCURRENT_TURNS=1` and `HEARTBEAT_LOCK` avoid overloading the server.

**Tuning:** See [GPU_TUNING.md](GPU_TUNING.md). After shed-load and stable runs, try raising seqs/tokens/cache in `.env` and restart vLLM.

---

## 2. Shed load (free GPU/RAM)

- **enter-chump-mode.sh** — Stops Ollama + embed (11434, 18765), quits every app in **chump-mode.conf** (browsers, Slack, Mail, etc.). Never kills rust-agent, vLLM, Python.
- **Shed-load role** — Runs Enter Chump mode every **2 h** (7200s) when installed via `install-roles-launchd.sh`.

**Bottleneck:** Other apps (Chrome, Cursor, Slack) compete for unified memory and GPU. Shed-load frees headroom; edit `chump-mode.conf` to keep apps you need (e.g. Cursor commented out).

**Tuning:** Run `./scripts/list-heavy-processes.sh` to see top RAM/GPU apps; add/remove names in `chump-mode.conf`. Change shed-load interval in `~/Library/LaunchAgents/ai.chump.shed-load.plist` (StartInterval) if 2 h is too aggressive or too rare.

---

## 3. Discord

| Setting | Default | Effect |
|--------|---------|--------|
| `CHUMP_MAX_CONCURRENT_TURNS` | 0 (no cap) | **Recommend 1** for autopilot: one turn at a time, messages queued when busy |
| `CHUMP_RATE_LIMIT_TURNS_PER_MIN` | 0 (off) | Per-channel cap; set if you want to throttle abuse |
| `CHUMP_MAX_MESSAGE_LEN` | 16384 | Max user message chars |
| `CHUMP_MAX_TOOL_ARGS_LEN` | 32768 | Max tool-call JSON size |

**Bottleneck:** With cap 0, multiple Discord turns can hit the model at once and contend with heartbeats. With cap 1, user messages are queued and processed when the current turn (or heartbeat) finishes.

**Tuning:** Set `CHUMP_MAX_CONCURRENT_TURNS=1` in `.env` for predictable autopilot. Queue file: `logs/discord-message-queue.jsonl`.

---

## 4. Heartbeats (self-improve, cursor-improve)

| Setting | Default (8000) | Default (Ollama) | Effect |
|--------|-----------------|------------------|--------|
| Self-improve interval | 15m | 8m | Time between rounds |
| Cursor-improve interval | 10m | 5m | Time between cursor_improve rounds |
| `CHUMP_CLI_TIMEOUT_SECS` | 120 | 120 | Per-command timeout in heartbeat |
| `HEARTBEAT_LOCK` | 1 (when on 8000) | 0 | Only one heartbeat round at a time |

**Bottleneck:** 8000 is single-model; lock prevents self-improve and cursor-improve from running at the same time (and from overlapping with a Discord turn). Intervals are already throttled for 8000 (15m / 10m).

**Tuning:** Run `./scripts/check-heartbeat-health.sh` (or schedule it every 20m). It suggests: back off if many failures; try shorter intervals (5m / 3m) if all recent rounds ok. Adjust `HEARTBEAT_INTERVAL` in `.env` and restart the heartbeat process.

---

## 5. Roles cadence (launchd)

| Role | Interval | Purpose |
|------|----------|--------|
| Farmer Brown | 2 min | Diagnose + keep-chump-online |
| Restart vLLM if down | 3 min | Restart 8000 if Python/Metal crashed |
| Sentinel | 5 min | Light checks |
| Heartbeat Shepherd | 15 min | Start/restart self-improve if needed |
| Memory Keeper | 15 min | Memory maintenance |
| Oven Tender | 1 h | Warm/restart model (8000 or Ollama) |
| Hourly update to Discord | 1 h | DM summary to CHUMP_READY_DM_USER_ID |
| Shed load | 2 h | Enter Chump mode (quit blocklisted apps) |

**Bottleneck:** None; these are background maintenance. Restart-vllm (3 min) and Oven Tender (1 h) both can start vLLM; restart-vllm is the fast path when 8000 is down.

---

## 6. Limits (agent)

- **Message length:** 16384 chars (configurable via `CHUMP_MAX_MESSAGE_LEN`).
- **Tool args:** 32768 bytes JSON (configurable via `CHUMP_MAX_TOOL_ARGS_LEN`).
- **Executive mode** (if enabled): `CHUMP_EXECUTIVE_TIMEOUT_SECS=300`, `CHUMP_EXECUTIVE_MAX_OUTPUT_CHARS=50000`.
- **Hourly update script:** 300s timeout for the single agent run (if `timeout` command available).

---

## 7. Recommendations

1. **Autopilot (8000 only):** Set `CHUMP_MAX_CONCURRENT_TURNS=1` so Discord and heartbeats don’t contend; user messages are queued.
2. **GPU headroom:** Use shed-load (role or manual) and tune `chump-mode.conf`; see [GPU_TUNING.md](GPU_TUNING.md).
3. **vLLM throughput:** After stable runs, try `VLLM_MAX_NUM_SEQS=2`, `VLLM_MAX_TOKENS=16384`, `VLLM_CACHE_PERCENT=0.18` in `.env`; restart vLLM.
4. **Heartbeat pace:** Use `check-heartbeat-health.sh` and adjust `HEARTBEAT_INTERVAL`; on 8000 keep intervals ≥ 10m/5m unless health is consistently ok with shorter.
5. **OOM / crashes:** Lower vLLM tokens/cache or use 7B model; last resort `MLX_DEVICE=cpu`. See [OPERATIONS.md](OPERATIONS.md) troubleshooting.

See also: [OPERATIONS.md](OPERATIONS.md), [GPU_TUNING.md](GPU_TUNING.md), [.env.example](../.env.example).

---

## 8. Perceived latency (PWA / multi-tool turns)

**Reality:** Wall time is dominated by **model inference** (especially 14B local) and **one round trip per tool batch**, not by Rust overhead. Reviews that cite multi-minute “5-tool” turns are usually describing **sequential LLM work**, not a single slow HTTP handler.

**What actually helps (in order):**

1. **Hardware / model tier** — Smaller quant, faster GPU, or cloud slot with acceptable privacy ([PROVIDER_CASCADE.md](PROVIDER_CASCADE.md)).
2. **`CHUMP_MAX_CONCURRENT_TURNS=1`** — Prevents Discord + web from dogpiling the same server (§3 above).
3. **`CHUMP_LIGHT_CONTEXT=1`** — Slimmer `assemble_context` for **web/CLI interactive** turns when you do not need full heartbeat context ([docs/CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md), [.env.example](../.env.example)); heartbeats unchanged.
4. **Measure before optimizing** — Run `./scripts/mlx-warmup-chat.sh` (local OpenAI base) and log **median wall time** for one chat + one short tool round; paste a dated row into [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) or [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) when you have numbers.

**PWA footnote:** SSE `turn_error` bubbles already append server-side hints via `user_error_hints`; the UI links preflight + `PERFORMANCE.md` for operators.
