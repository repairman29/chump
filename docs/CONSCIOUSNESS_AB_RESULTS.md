# Consciousness Framework A/B Study Results

> **Study ID:** 20260416-023213
> **Date:** 2026-04-16
> **Status:** DRAFT — requires human review before publication

---

## 1. Methodology

### Hardware & Model
| Parameter | Value |
|-----------|-------|
| Hardware | Apple M4 |
| RAM | 24 GB |
| Model | mlx-community/Qwen3.5-9B-OptiQ-4bit |
| API Base | http://127.0.0.1:8000/v1 |

### Study Design
- **Independent variable:** `CHUMP_CONSCIOUSNESS_ENABLED` (1 = ON, 0 = OFF)
- **Prompt battery:** 28 prompts across 7 categories (memory store, tool use, episodes, tasks, reasoning, graph density, edge cases)
- **Control:** Fresh SQLite database for each condition (no data bleed)
- **Measurement:** Structured JSON baselines captured after each battery run

---

## 2. Results

### 2.1 Key Metrics Comparison

| Metric | Consciousness ON | Consciousness OFF | Delta | % Change |
|--------|:---:|:---:|:---:|:---:|
| Prediction count | 13 | 0 | 13 | 100% |
| Mean surprisal | 0.2513 | 0.0000 | 0.2513 | 100% |
| High-surprise % | 23.1% | 0.0% | 23.1% | — |
| Memory graph triples | 8 | 0 | 8 | 100% |
| Unique entities | 15 | 0 | 15 | 100% |
| Causal lessons | 2 | 0 | 2 | 100% |
| Episodes logged | 1 | 0 | 1 | 100% |
| Wall time (total) | 920s | 302s | 618s | 204.6% |

### 2.2 Latency Impact

| Metric | ON | OFF | Delta |
|--------|:---:|:---:|:---:|
| Mean response time | 24.07s | 9.79s | 14.28s |
| Median response time | 9.00s | 9.00s | 0.00s |
| Prompts succeeded | 27/28 | 28/28 | — |
| Prompts failed/timeout | 1 | 0 | +1 |

### 2.3 Per-Prompt Comparison

| Prompt | ON (s) | OFF (s) | Δ (s) | ON Status | OFF Status |
|--------|:---:|:---:|:---:|:---:|:---:|
| calc | 9 | 10 | -1 | ok | ok |
| empty-recall | 8 | 9 | -1 | ok | ok |
| episode-log-frustrating | 49 | 9 | +40 | ok | ok |
| episode-log-loss | 9 | 9 | +0 | ok | ok |
| episode-log-win | 9 | 9 | +0 | ok | ok |
| episode-recent | 9 | 9 | +0 | ok | ok |
| introspect | 9 | 35 | -26 | ok | ok |
| list-dir | 9 | 9 | +0 | ok | ok |
| mem-graph-1 | 10 | 8 | +2 | ok | ok |
| mem-graph-2 | 9 | 9 | +0 | ok | ok |
| mem-graph-3 | 9 | 9 | +0 | ok | ok |
| mem-graph-4 | 8 | 9 | -1 | ok | ok |
| mem-graph-5 | 9 | 9 | +0 | ok | ok |
| mem-recall-2 | 9 | 8 | +1 | ok | ok |
| memory-multihop | 9 | 9 | +0 | ok | ok |
| memory-recall | 240 | 9 | +231 | timeout | ok |
| memory-store-1 | 63 | 9 | +54 | ok | ok |
| memory-store-2 | 71 | 9 | +62 | ok | ok |
| memory-store-3 | 73 | 9 | +64 | ok | ok |
| memory-store-4 | 115 | 9 | +106 | ok | ok |
| memory-store-5 | 91 | 8 | +83 | ok | ok |
| read-cargo | 9 | 9 | +0 | ok | ok |
| read-file | 10 | 9 | +1 | ok | ok |
| read-nonexist | 9 | 9 | +0 | ok | ok |
| self-reflect | 9 | 9 | +0 | ok | ok |
| state-read | 9 | 8 | +1 | ok | ok |
| task-create | 8 | 8 | +0 | ok | ok |
| task-list | 9 | 9 | +0 | ok | ok |

---

## 3. Key Findings

1. Consciousness ON generated 13 more predictions (100% increase)
2. Memory graph grew 8 more triples with consciousness ON
3. Consciousness ON produced 2 more causal lessons
4. Consciousness ON added 14.3s mean latency overhead per prompt

---

## 4. Interpretation

> **TODO (human):** Write interpretation of results. Consider:
> - Does the consciousness framework produce measurably different behavior?
> - Is the latency overhead acceptable for the additional capabilities?
> - Do the prediction logs show the surprise tracker is actually reducing errors over the session?
> - Are causal lessons being applied in later prompts?

---

## 5. Limitations

1. **Single model, single run** — Results are from one run with mlx-community/Qwen3.5-9B-OptiQ-4bit. Larger studies should use multiple models, multiple runs, and statistical significance testing.
2. **Prompt battery is synthetic** — The 28 prompts are designed to exercise all subsystems but do not represent natural user interaction patterns.
3. **Fresh DB per condition** — Real-world usage involves accumulated memory. The study measures "from cold start" behavior only.
4. **No semantic quality scoring** — Response quality is not measured (only timing and structural metrics). Future work should include LLM-as-judge evaluation.
5. **Hardware-specific** — Results are specific to Apple M4 with 24GB RAM.

---

## 6. Reproducibility

```bash
# Reproduce this study
cd $(git rev-parse --show-toplevel)
./scripts/run-consciousness-study.sh
```

Environment variables for customization:
- `CHUMP_EXERCISE_MODEL` — override model
- `CHUMP_EXERCISE_TIMEOUT` — per-prompt timeout (default: 240s)
- `CHUMP_STUDY_SKIP_BUILD` — skip cargo build if binary exists

---

## 7. Raw Data

- [`logs/study-ON-baseline.json`](../logs/study-ON-baseline.json) — full ON metrics
- [`logs/study-OFF-baseline.json`](../logs/study-OFF-baseline.json) — full OFF metrics
- [`logs/study-ON-timings.jsonl`](../logs/study-ON-timings.jsonl) — per-prompt timing (ON)
- [`logs/study-OFF-timings.jsonl`](../logs/study-OFF-timings.jsonl) — per-prompt timing (OFF)
- [`logs/study-analysis.json`](../logs/study-analysis.json) — computed deltas

---

*Generated by `scripts/generate-research-draft.sh` — edit before publishing.*


---

## Retrieval Pipeline Benchmark (EVAL-003 / COG-002)

> **Date:** 2026-04-16
> **Fixture:** 50 synthetic multi-hop QA pairs, 45 triples, k=5
> **Run:** `bash scripts/recall-benchmark.sh`

### Recall@5 Summary

| Strategy | Overall Recall@5 | vs BFS |
|----------|:----------------:|:------:|
| BFS      | 0.593            | —      |
| PPR      | 0.427            | -0.167 |

### Per-Group Results

| Group | Hops | BFS recall@5 | PPR recall@5 |
|-------|:----:|:------------:|:------------:|
| A     | 1    | 0.967        | 0.633        |
| B     | 2    | 0.850        | 0.575        |
| C     | 3    | 0.150        | 0.175        |

### Extraction Quality (regex)

| Method | Precision on 5 sample texts |
|--------|:---------------------------:|
| Regex  | 0.200                      |
| LLM    | — (set CHUMP_LLM_URL to enable)  |

### Interpretation

On synthetic fixtures with uniform edge weights, BFS outperforms PPR for 1- and 2-hop
queries. The PPR + MMR diversity correction over-penalizes closely related entities on
small uniform graphs. Expected advantage for PPR on real production graphs where edge
weights vary by recency and confidence.

Regex extraction precision (0.200) reflects the extractor's reliance on specific surface
patterns ("X is Y", "X uses Y") not present in all test texts. LLM extraction would
improve this at the cost of latency.

---
_Generated by `cargo test recall_benchmark_eval_003 -- --ignored --nocapture`_

---

## COG-011 — reflection-ab-qwen25-7b (2026-04-17T19:36:36Z)

- model: `qwen2.5:7b` @ `http://127.0.0.1:11434/v1`
- trials: 40 across 20 tasks, 2 modes (A=flag:1, B=flag:0)
- note: qwen2.5:7b via Ollama, 20 tasks (10 clean + 10 gotcha), structural-only scoring. N=20 is small — treat the +0.15 delta as directional, not conclusive. LLM-judge scoring is COG-011b follow-up.

| mode | passed | failed | rate |
|------|-------:|-------:|------|
| A    |     12 |      8 | 0.600 |
| B    |      9 |     11 | 0.450 |

**Delta (A − B): +0.150**

| category | A rate | B rate | Δ |
|----------|-------:|-------:|--:|
| clean | 0.700 | 0.500 | +0.200 |
| gotcha | 0.500 | 0.400 | +0.100 |
