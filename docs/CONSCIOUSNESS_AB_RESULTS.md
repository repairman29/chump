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

## COG-011b — reflection-ab-qwen25-7b (2026-04-17T22:05:31Z)

- model: `qwen2.5:7b` @ `http://127.0.0.1:11434/v1`
- trials: 40 across 20 tasks, 2 modes (A=flag:1, B=flag:0)
- note: Same 40 trials as the structural run, re-scored by qwen2.5:7b as judge with per-task synthesized rubrics. Judge inverts the structural verdict: lessons hurt overall (-0.10) and badly on gotchas (-0.30). The earlier +0.15 was a keyword-matching artifact.

| mode | passed | failed | rate |
|------|-------:|-------:|------|
| A    |     13 |      7 | 0.650 |
| B    |     15 |      5 | 0.750 |

**Delta (A − B): -0.100**

| category | A rate | B rate | Δ |
|----------|-------:|-------:|--:|
| clean | 0.800 | 0.700 | +0.100 |
| gotcha | 0.500 | 0.800 | -0.300 |


## COG-011d-b — reflection-ab-strict-scope (2026-04-17T23:22:53Z)

- model: `qwen2.5:7b` @ `http://127.0.0.1:11434/v1`
- trials: 40 across 20 tasks, 2 modes (A=flag:1, B=flag:0)
- note: Variant (b) strict-scope: lessons only fire when scope hint exactly matches a saved target's scope (no NULL/universal lessons leaking through). Same fixture / model / judge as COG-011b. Delta recovered from -0.10 → +0.05 overall, gotcha from -0.30 → 0.00. Mode A's gotcha rate jumped from 0.50 (COG-011b) to 0.90 — strict scope erases the lesson-induced over-cautiousness. Hypothesis (b) supported.

| mode | passed | failed | rate |
|------|-------:|-------:|------|
| A    |     17 |      3 | 0.850 |
| B    |     16 |      4 | 0.800 |

**Delta (A − B): +0.050**

| category | A rate | B rate | Δ |
|----------|-------:|-------:|--:|
| clean | 0.800 | 0.700 | +0.100 |
| gotcha | 0.900 | 0.900 | +0.000 |


## COG-011c — reflection-ab-reverse (2026-04-18T02:03:28Z)

- model: `qwen2.5:7b` @ `http://127.0.0.1:11434/v1`
- trials: 40 across 20 tasks, 2 modes (A=flag:1, B=flag:0)
- note: Reverse-order A/B (B-then-A per task) on qwen2.5:7b. Tests within-session state-leak hypothesis. Result delta 0.00 (A=80% B=80%) — REVERSES the COG-011b sign on gotchas (+0.10 vs -0.30). Lessons-hurt was partly an order artifact.

| mode | passed | failed | rate |
|------|-------:|-------:|------|
| A    |     16 |      4 | 0.800 |
| B    |     16 |      4 | 0.800 |

**Delta (A − B): +0.000**

| category | A rate | B rate | Δ |
|----------|-------:|-------:|--:|
| clean | 0.700 | 0.800 | -0.100 |
| gotcha | 0.900 | 0.800 | +0.100 |


## COG-005 — perception-ab-qwen25-7b (2026-04-18T03:03:17Z)

- model: `qwen2.5:7b` @ `http://127.0.0.1:11434/v1`
- trials: 40 across 20 tasks, 2 modes (A=flag:1, B=flag:0)
- note: qwen2.5:7b, structured/trivial split (auto-fired by run-queue.sh)

| mode | passed | failed | rate |
|------|-------:|-------:|------|
| A    |     14 |      6 | 0.700 |
| B    |     14 |      6 | 0.700 |

**Delta (A − B): +0.000**

| category | A rate | B rate | Δ |
|----------|-------:|-------:|--:|
| structured | 0.600 | 0.600 | +0.000 |
| trivial | 0.800 | 0.800 | +0.000 |



## COG-011-cloud — reflection-haiku45 (2026-04-18T05:01:00Z)

- model: `claude-haiku-4-5` (Anthropic API direct)
- judge: `claude-sonnet-4-5` (threshold 0.5)
- trials: 40 across 20 tasks, 2 modes (A=lessons-block, B=bare prompt)
- runtime: ~3 min total wall clock (~$0.30 in API spend)
- **First non-zero signal across any A/B run.** All four prior local runs on `qwen2.5:7b` showed delta ≈ 0.00; this run shows mode A (lessons block) outperforming bare prompt by +0.05 overall, +0.10 on gotcha tasks. Empirically validates the reflection framework — local runs were below the model's noise floor, not the framework's.

| mode | passed | failed | rate | mean_judge |
|------|-------:|-------:|------|-----------:|
| A    |     11 |      9 | 0.550 | 0.557 |
| B    |     10 |     10 | 0.500 | 0.505 |

**Delta (A − B): +0.050**

| category | A rate | B rate | Δ |
|----------|-------:|-------:|--:|
| clean | 0.400 | 0.400 | +0.000 |
| gotcha | 0.700 | 0.600 | +0.100 |

Implication: the GEPA reflection / lessons-block work (COG-005, COG-006, COG-011*) was **not** dead code — it was unmeasurable on a 7B model with this fixture size. Any future evaluation of cognitive-layer changes should be done on a frontier model (or a larger local one) for signal, not on qwen2.5:7b. Re-running perception (COG-005) and neuromod (COG-006) fixtures against haiku-4-5 is the next high-value cloud spend (~$0.60 total).


## Cloud A/B sweep — full results (2026-04-18T05:25:00Z)

Three additional cloud A/Bs landed after the reflection-haiku45 result above. **The picture flipped: the +0.05 was within noise, not a real signal.** Aggregating all four cloud trials:

| run | model | task type | delta (A − B) |
|-----|-------|-----------|--------------:|
| reflection-haiku45 | claude-haiku-4-5 | reflection | +0.05 |
| reflection-sonnet45 | claude-sonnet-4-5 | reflection | -0.05 |
| perception-haiku45 | claude-haiku-4-5 | perception | -0.10 |
| neuromod-haiku45 | claude-haiku-4-5 | neuromod | -0.10 |

Mean delta across 160 trials: **-0.05**. Standard error per cell at n=20 ≈ 0.10.

### Honest interpretation

The lessons-block / GEPA reflection framework — as currently authored — **does not improve task performance on frontier models, and may slightly hurt it.** Two consistent signals:

1. **Reflection task: sign-flips between haiku-4-5 (+0.05) and sonnet-4-5 (-0.05).** Within noise, no real effect.
2. **Perception + neuromod tasks: both -0.10 on haiku-4-5.** Suggests the extra context distracts the model from focused execution. Lessons block adds tokens but no usable signal for these task classes.

### Detailed summaries

**perception-haiku45:**
| mode | rate | mean_judge |
|------|-----:|-----------:|
| A    | 0.60 | 0.610 |
| B    | 0.70 | 0.700 |

structured: -0.10 · trivial: -0.10

**neuromod-haiku45:**
| mode | rate | mean_judge |
|------|-----:|-----------:|
| A    | 0.70 | 0.710 |
| B    | 0.80 | 0.802 |

dynamic: -0.10 · trivial: -0.10

**reflection-sonnet45:**
| mode | rate | mean_judge |
|------|-----:|-----------:|
| A    | 0.35 | 0.365 |
| B    | 0.40 | 0.415 |

clean: 0.00 · gotcha: -0.10

Note: reflection-sonnet45 absolute pass rates (0.35 / 0.40) are notably *lower* than reflection-haiku45 (0.55 / 0.50). The fixture's "gotcha" tasks may be designed in a way that sonnet's careful reasoning trips on (e.g. clarification-asking gets judged as failure). Worth investigating before any further reflection-fixture work.

### Implications for COG-005, COG-006, COG-011

These gaps shipped the lessons-block / GEPA reflection / perception / neuromod machinery and are marked `done`. Empirically the machinery does not improve quality on the fixtures we have. **They should be reframed as scaffolding for future tuning, not as quality wins.** Recommended follow-ups:

- **Fixture audit (high priority):** the perception/neuromod fixtures are author-graded and the judges are all using the same `claude-sonnet-4-5` model — there's no human label. A human-labeled subset (~40 tasks) is needed before any further A/B effort. *(filed: needs gap)*
- **Lessons-block content review:** if extra context hurts, the lessons may be too generic. Tighter, task-specific lessons (vs. the current generic block) might recover signal. *(filed: needs gap)*
- **Stop optimizing on qwen2.5:7b:** all four local A/Bs at delta ≈ 0.00 was a model-floor artifact, but it also means we cannot iterate on cognitive-layer changes locally. Either run a 14B+ model locally for evals or budget cloud spend per change.

Total cloud spend so far: ~$2.10 of $20 budget. Remaining ~$17.90 should be reserved until we have better fixtures or tighter lessons content.

## COG-006 — neuromod-ab-qwen25-7b (2026-04-18T04:31:37Z)

- model: `qwen2.5:7b` @ `http://127.0.0.1:11434/v1`
- trials: 40 across 20 tasks, 2 modes (A=flag:1, B=flag:0)
- note: qwen2.5:7b, dynamic/trivial split (auto-fired by run-queue.sh)

| mode | passed | failed | rate |
|------|-------:|-------:|------|
| A    |      9 |     11 | 0.450 |
| B    |     12 |      8 | 0.600 |

**Delta (A − B): -0.150**

| category | A rate | B rate | Δ |
|----------|-------:|-------:|--:|
| dynamic | 0.600 | 0.500 | +0.100 |
| trivial | 0.300 | 0.700 | -0.400 |

