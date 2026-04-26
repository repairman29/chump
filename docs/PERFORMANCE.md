---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

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

- **enter-chump-mode.sh** — Stops Ollama + embed (11434, 18765), quits every app in **chump-mode.conf** (browsers, Slack, Mail, etc.). Never kills `chump`, vLLM, Python.
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
3. **`CHUMP_LIGHT_CONTEXT=1`** — Slimmer `assemble_context` for **web/CLI interactive** turns when you do not need full heartbeat context ([docs/CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md), [.env.example](../.env.example)); heartbeats unchanged. Light mode also applies **tool schema compaction** (see below).
4. **Measure before optimizing** — Run `./scripts/mlx-warmup-chat.sh` (local OpenAI base) and log **median wall time** for one chat + one short tool round; paste a dated row into [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) or [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) when you have numbers.

### Tool schema compaction (Ollama / light context)

Ollama's chat template wraps each tool definition in XML markup, inflating token counts far beyond the raw JSON size. With 12 tools and full descriptions, the prompt can saturate the entire `num_ctx` window (e.g. 4096 tokens) before the user's message is even processed.

When `CHUMP_LIGHT_CONTEXT=1`, `agent_loop::types::compact_tools_for_light()` (called from `orchestrator.rs`) applies:
- **Descriptions** truncated to the first sentence (~40–80 chars instead of 150–380).
- **Property-level `"description"` fields** stripped from JSON schemas (the tool description already explains usage).

### Tool-free fast path with auto-retry

For conversational messages that don't need tools, the agent skips sending tools entirely — dropping from ~776 to ~315 prompt tokens. The heuristic (`message_likely_needs_tools_neuromod()`) checks for action keywords (run, create, list, deploy, etc.) regardless of message length and defaults to **no tools**.

**Neuromodulation-aware (2026-04-14):** The question-mark length threshold is now modulated by serotonin (patience). Low serotonin (impulsive) widens the fast path (more messages skip tools for faster response). High serotonin (patient) narrows it (more messages get tools). This adds ~1 nanosecond (one mutex read) to the fast path decision.

If the model's tool-free response indicates it wanted tools (narrating "I'll list your tasks" instead of answering), `response_wanted_tools()` detects this and the agent **automatically retries with tools enabled** — the user never sees the failed narration.

### Cognitive loop overhead (2026-04-14)

The following operations run in the agent loop hot path after each tool execution. All are sub-millisecond except the SQLite write:

| Operation | Cost | Notes |
|---|---|---|
| `decay_turn()` | ~ns | 1 mutex + 2 float ops |
| `neuromodulation::levels()` | ~ns | 1 mutex + clone 3 floats |
| `epsilon_greedy_select()` | ~ns | hash + modulo |
| `update_tool_belief()` | ~µs | mutex + HashMap lookup per tool |
| `score_tools()` + `efe_order_tool_calls()` | ~µs | N HashMap lookups + sort |
| `check_regime_change()` | ~µs | mutex + comparison |
| `record_prediction()` | ~1ms | SQLite INSERT (1 per tool call) |

**Net PWA impact:** Zero perceptible. Tool calls themselves take 100ms–5000ms (LLM inference, file I/O); cognitive overhead is 3–4 orders of magnitude below.

### Ollama KV cache keep-alive

`keep_alive` is sent with every Ollama request (default `"30m"`, configurable via `CHUMP_OLLAMA_KEEP_ALIVE`). This keeps the model and its KV cache resident in memory between requests, eliminating the ~5s cold-start penalty on follow-up messages within the keep-alive window.

**Measured impact** (qwen2.5:7b on Ollama, `num_ctx=2048`):

| Configuration | Prompt tokens | Wall time |
|---|---|---|
| 40 tools, full descriptions | 4096 (saturated) | ~26s |
| 12 light tools, full descriptions | 4096 (saturated) | ~23s |
| 12 light tools, compacted | 776 | ~5.7s |
| Tool-free fast path (cold cache) | 315 | ~5.5s |
| Tool-free fast path (warm cache) | 315 | ~0.5s |
| No tools (baseline) | 30 | ~0.2s |

End-to-end: **26s → 0.5s** for conversational turns with warm cache — a **52× speedup**.

**PWA footnote:** SSE `turn_error` bubbles already append server-side hints via `user_error_hints`; the UI links preflight + `PERFORMANCE.md` for operators.
