# Latency envelope (daily driver proof)

**Purpose:** Satisfy [ROADMAP.md](ROADMAP.md) **Architecture vs proof → Latency envelope** with a **repeatable procedure** and a **dated table** of median / p90 wall times on the machine you actually use for green-path work.

**Not a substitute for your numbers:** Paste measured rows into this file or into [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) **Measured latency envelope** (append-only).

---

## Definitions

| Term | Meaning |
|------|---------|
| **N** | Number of independent runs per scenario (default **10**). |
| **Scenario A** | One **no-tool** chat turn: short user message, assistant completes without `tool_call_*` SSE events. |
| **Scenario B** | One turn that completes a **3-tool** sequence (or as close as your policy allows without manual approval blocking the script). Prefer a fixed prompt from [UI_WEEK_SMOKE_PROMPTS.md](UI_WEEK_SMOKE_PROMPTS.md) or an internal harness. |
| **Wall time** | Client-observed seconds from **Send** to **`turn_complete`** (browser DevTools network + Performance, or `CHUMP_LOG_TIMING=1` server logs for CLI). |

Record **model id**, **`OPENAI_API_BASE` profile** ([INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)), **`CHUMP_LIGHT_CONTEXT`**, and **`CHUMP_MAX_CONCURRENT_TURNS`** with every row.

---

## How to measure

1. **Warm the model** once: `./scripts/mlx-warmup-chat.sh` (MLX on :8000) or send a throwaway chat turn (Ollama).
2. **Optional build baseline:** `./scripts/golden-path-timing.sh` (cargo wall time only; does not replace chat latency).
3. For each scenario, run **N** times; discard the first run if it includes cold load; record milliseconds or seconds per run.
4. Compute **median** and **p90** (or use a small script / spreadsheet).
5. Append a row to the table below with **UTC date** and operator initials.

---

## Results table (append rows)

| Date (UTC) | Operator | Model | Scenario | N | Median (s) | p90 (s) | CHUMP_LIGHT_CONTEXT | Notes |
|------------|----------|-------|----------|---|------------|---------|----------------------|-------|
| _Example_ | _you_ | _qwen…_ | A | 10 | _—_ | _—_ | 0 | _fill after measuring_ |
| | | | B (3-tool) | 10 | | | | |

---

## Related

- [PERFORMANCE.md](PERFORMANCE.md) §8 — perceived latency framing.  
- [STEADY_RUN.md](STEADY_RUN.md) — concurrency and timeouts.  
- [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) — metrics hygiene.
