# mistral.rs — path to higher-performance agents (measurement + modes)

This doc implements the **agent power** plan: define metrics, run comparable A/Bs across inference modes, tune with upstream `mistralrs tune` + Chump env, enable streaming where it helps, and track backlog (multimodal, structured output).

**Repo state (checklist):** The **measurement + scripts + web streaming default** slice is **Done** in [ROADMAP.md](ROADMAP.md) under *mistral.rs — higher-performance agents* (`MISTRALRS_AGENT_POWER_PATH.md`, `mistralrs-inference-ab-smoke.sh`, `env-mistralrs-power.sh`, `run-web-mistralrs-infer.sh`). **Still open** there: RFC multimodal decision/implementation, structured-output spike — scheduled as **S2 / S3** in [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md).

**Related:** [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b · [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) · [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md) · [RFC-inference-backends.md](rfcs/RFC-inference-backends.md)

---

## 1. Success metrics (pick 3–5 per run)

Record these in a spreadsheet or the template in §6 so A/B rows are comparable.

| Metric | How to measure | Notes |
|--------|-----------------|-------|
| **TTFT (warm)** | Time from “submit” to first token **after** one warmup completion on the same process | Excludes cold weight load; use web devtools, tracing, or `CHUMP_MISTRALRS_THROUGHPUT_LOGGING=1` / runner logs |
| **Turn latency** | Wall time for one full CLI `--chump` reply or one PWA turn | Includes tool loop if the fixed task uses tools |
| **Peak RSS** | `top` / Activity Monitor / `ps` max resident while inference runs | Compare across modes on the same machine |
| **Battle QA pass rate** | `BATTLE_QA_MAX=20 ./scripts/battle-qa.sh` (or your smoke N) | Same `BATTLE_QA_MAX` and timeout for each mode; see [CAPABILITY_CHECKLIST.md](CAPABILITY_CHECKLIST.md) |
| **Throughput (optional)** | Runner tok/s or Chump `mistralrs chat complete` `elapsed_ms` logs | [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md) §1–2 |

**Do not** compare cold-start mistral in-process to an already-warmed vLLM process without labeling the row “cold vs warm.”

---

## 2. Fixed prompts / tasks (canonical A/B set)

Use the **same** text and limits for every mode so differences are from inference, not prompt drift.

| ID | Kind | Command / action |
|----|------|------------------|
| **AB-1** | Micro (no full agent) | `./scripts/bench-mistralrs-chump.sh --model <HF_ID> --isq 8 --runs 2 --warmup --summary -o logs/ab-micro.csv` (in-process only) |
| **AB-2** | CLI single-shot | `time ./target/release/chump --chump "$CHUMP_AB_PROMPT"` — default prompt below |
| **AB-3** | Battle QA smoke | `BATTLE_QA_MAX=20 BATTLE_QA_TIMEOUT=120 ./scripts/battle-qa.sh` — align `OPENAI_MODEL` / mistral model to something that can complete small tasks |

**Default `CHUMP_AB_PROMPT`** (deterministic, no tools — isolates inference latency):

```text
Reply with exactly one line of text: AB_SMOKE_OK
```

Optional tool-using variant for end-to-end agent timing:

```text
Use read_file on Cargo.toml in the repo root. Reply with one line: AB_SMOKE_OK and the edition field value only.
```

Set `export CHUMP_AB_PROMPT='...'` to switch between them; keep the same prompt across modes A/B/C for a given experiment.

---

## 3. Three inference modes (one primary per machine)

Chump does not change behavior here — you change **env + processes**.

| Mode | Label | What you run | Chump config |
|------|-------|--------------|--------------|
| **A** | HTTP primary (status quo prod) | vLLM-MLX :8000, Ollama :11434, or any OpenAI-compatible server | `OPENAI_API_BASE`, `OPENAI_MODEL`; **unset** `CHUMP_INFERENCE_BACKEND=mistralrs` for chat via HTTP |
| **B** | **mistral.rs HTTP** | Upstream `mistralrs serve` (OpenAI API on localhost) | Same as A: `OPENAI_API_BASE` → that server; Chump unchanged |
| **C** | **In-process mistral.rs** | Only `chump` | `cargo build --release --features mistralrs-metal -p rust-agent` (or `mistralrs-infer`), `CHUMP_INFERENCE_BACKEND=mistralrs`, `CHUMP_MISTRALRS_MODEL`, **unset** `OPENAI_API_BASE` for chat-only mistral-primary |

**Scripted smoke:** [`scripts/mistralrs-inference-ab-smoke.sh`](../scripts/mistralrs-inference-ab-smoke.sh) — `print` shows env recipes; `http` / `inproc` runs AB-2 with `time`.

**Fleet (Pixel / Mabel):** stay on **HTTP** (e.g. `MABEL_HEAVY_MODEL_BASE`); in-process mistral is not the supported Android path ([INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b.6).

---

## 4. Tune with `mistralrs tune` → Chump env

1. Run upstream tuning (wrapper: `./scripts/bench-mistralrs-tune.sh <HF_MODEL>`) — see [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b.8 and [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md) §1.
2. Map bit-width recommendations to **`CHUMP_MISTRALRS_ISQ_BITS`** (2–8).
3. Add measurement / perf knobs from [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md):

   - `CHUMP_MISTRALRS_PREFIX_CACHE_N` (or `off` / `none` / `disable`)
   - `CHUMP_MISTRALRS_PAGED_ATTN=1` (when supported)
   - `CHUMP_MISTRALRS_THROUGHPUT_LOGGING=1`
   - `CHUMP_MISTRALRS_MOQE=1` (optional)

4. **Sourceable bundle:** `source ./scripts/env-mistralrs-power.sh` (web-oriented defaults + streaming).

Re-bench with `./scripts/bench-mistralrs-chump.sh` or AB-2/AB-3 after changes.

---

## 5. Streaming UX (web) vs Discord gap

- **PWA / `POST /api/chat` (SSE):** set **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1`** when using in-process mistral as primary — token chunks surface as `text_delta` events ([MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) streaming row).
- **`scripts/run-web-mistralrs-infer.sh`** exports this by default for web runs.
- **Discord:** only the **tool-approval** path uses `StreamingProvider`; **standard** Discord turns still show the final reply only (no live token stream). Closing that gap is backlog (**WP-1.6** extension), not a one-line env change.

---

## 6. Results template (copy to `logs/` or a spreadsheet)

| run_id | date | mode (A/B/C) | model | isq | paged | wall_AB2_s | battle_pass/N | peak_RSS_GB | notes |
|--------|------|--------------|-------|-----|-------|------------|---------------|-------------|-------|
| | | | | | | | | | |

---

## 7. Backlog — “power” beyond tok/s

| Item | Doc | Sprint |
|------|-----|--------|
| **Multimodal in-tree (WP-1.5)** | [RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) — accept/reject, then implement | [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) **S2** |
| **Structured output / grammar** | Not wired in `mistralrs_provider`; spike when tool JSON reliability is the bottleneck ([MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md)) | **S3** |
| **Streaming parity** (Discord standard turns, HTTP provider SSE) | [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) Next tier **B** | **S6** |

Tracked as unchecked items under **mistral.rs — higher-performance agents** in [ROADMAP.md](ROADMAP.md) (first two rows).

---

## 8. Consciousness toggle (utility pass)

For **agent-level** latency / quality tradeoffs that are independent of mistral vs HTTP mode, run the same short prompts with `CHUMP_CONSCIOUSNESS_ENABLED=1` vs `0`. Procedure and log table: [CONSCIOUSNESS_UTILITY_PASS.md](CONSCIOUSNESS_UTILITY_PASS.md). This complements §2’s fixed prompts (which focus on inference backends).
