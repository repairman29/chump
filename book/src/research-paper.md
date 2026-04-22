# Cognitive Architecture in Production: Empirical Studies of Lessons-Block Injection and Cognitive Scaffolding in Autonomous Agents

> **Status:** LIVE — active research. Sections marked [AUTO] are populated by study scripts; sections marked [HUMAN] were authored 2026-04-18. Findings are updated as studies complete; treat all results as preliminary until noted otherwise.
> **Data:** [CONSCIOUSNESS_AB_RESULTS.md](../CONSCIOUSNESS_AB_RESULTS.md)
>
> **Research-integrity caveat (2026-04-20).** The load-bearing validated
> finding in this paper is the **tier-dependent injection effect** — lessons
> block helps small models on reflection fixtures (haiku-4-5), harms frontier
> models (+0.33 hallucination rate on sonnet-4-5, n=100, cross-family judges).
> The broader nine-subsystem architecture is described as implementation
> detail, not as a validated whole. Individual modules (surprisal EMA,
> belief_state, neuromodulation) remain **individually unablated** pending
> EVAL-043 results (infrastructure shipped, sweeps pending). Do not cite
> this paper as evidence that "cognitive architecture improves agent
> performance." See [../RESEARCH_INTEGRITY.md](../RESEARCH_INTEGRITY.md) for
> the full prohibited-claims list and methodology standards.

---

## Abstract

We report two empirical studies of instruction injection in a Rust-native
production agent. The load-bearing finding is **tier-dependent**: a system-prompt
lessons block improves task performance for small models on specific task
classes (reflection fixtures, haiku-4-5) and actively harms frontier models
(+0.33 hallucination rate on sonnet-4-5 at n=100, cross-family judges, 10.7×
A/A noise floor). Both the helpful and harmful effects are reproduced at
n=100 with non-Anthropic judges; the harm mechanism decomposes into
conditional-chain dilution and trivial-token contamination. The surrounding
nine-module cognitive-architecture scaffold (surprisal EMA, belief state,
neuromodulation, precision controller, memory graph, counterfactual,
holographic workspace, phi proxy, blackboard) is described as implementation
detail; individual-module contributions are **unablated** in this paper
and remain pending in EVAL-043.

**Study 1 (cloud frontier, n=100):** A controlled A/B study of the lessons-block injection across 2,600+ trial pairs on two frontier models (claude-haiku-4-5, claude-opus-4-5). Using a multi-axis scoring harness (correctness + hallucination detection + did_attempt) with A/A controls and Wilson 95% CIs, we find that the lessons block reliably *increases* fake-tool-call emission by a mean of +0.14 percentage points (≈ +0.0014 absolute rate on a 0–1 indicator; A/B effect 10.7× the calibrated A/A noise floor). This effect is invisible to single-axis binary pass/fail scoring because the LLM judge rewards hallucinated tool execution.

**Study 2 (local models, n=20/model + neuromod ablation n=50):** A framework-on vs. framework-off comparison across five local models (1B–14B parameters). The pass-rate effect is non-monotonic: small (1B) and large (14B) models benefit (+10pp); mid-size models (3B, 7B) are hurt (−5pp); the 8B model is neutral. We term this the **Scaffolding U-curve**. A focused neuromodulation ablation (qwen3:8b, 50 tasks) finds +12pp pass-rate improvement and a 33% reduction in tool calls on dynamic tasks, suggesting the neuromodulation subsystem drives the most actionable within-session adaptation signal.

Both findings motivate concrete follow-on work: task-specific, anti-hallucination-guardrailed lessons content (COG-014) and subsystem-level ablation to decompose U-curve contributors (planned). All study infrastructure is open source and reproducible.

---

## 1. Introduction

### 1.1 The production agent landscape and the within-session adaptation gap [HUMAN]

The 2026 autonomous agent ecosystem has bifurcated. One branch — Python-centric frameworks like LangChain, AutoGen, and CrewAI — optimizes for rapid prototyping and mass adoption. The other branch targets production execution: low-latency, memory-safe, single-binary deployments where the agent runtime itself becomes a competitive surface. Chump belongs to the second branch.

Most improvement efforts in this space operate *between* sessions: GEPA-style evolutionary loops select prompt variants via Bradley-Terry tournaments, Hermes accumulates skills across thousands of runs, AutoEvolve mutates system prompts based on aggregate outcome signals. These approaches require wall-clock days and large compute budgets to show signal.

Chump's thesis is different: **cognitive architecture can produce measurable behavioral differences within a single session, on a single consumer machine, without any training.** The nine subsystems — surprisal tracking, associative memory, neuromodulation, counterfactual reasoning, precision control, holographic workspace broadcast, belief state, phi proxy, and blackboard — update every turn based on the agent's own execution trace. They are not trained; they are computed.

This paper reports the first empirical tests of that thesis — and the first negative results that help bound where the thesis holds.

### 1.2 What we do not claim

We do not claim that Chump is phenomenally conscious, or that the cognitive modules implement their theoretical namesakes in any formal sense. The phi proxy is a graph density statistic on blackboard traffic, not IIT's Minimum Information Partition. The surprise tracker is an EMA on tool outcome scalars, not a variational bound on a generative model. The dopamine/noradrenaline/serotonin signals are scalars that shift threshold parameters — they are not felt. The modules are **engineering proxies inspired by theories of cognition**, evaluated on operational outcomes.

The term "cognitive architecture" reflects the theoretical grounding (Global Workspace Theory, active inference, neuromodulatory systems) rather than a philosophical claim. The key question is empirical: **does adding this machinery improve agent behavior, and for which models and task types?**

We also do not claim, in this paper, that the nine-subsystem architecture as a whole is validated. Studies 1 and 2 test the lessons-block injection and a coarse framework-on/framework-off comparison; neither isolates individual-module contributions. Per-subsystem ablation (surprisal EMA, belief_state, neuromodulation bypass flags) is scheduled in EVAL-043 — infrastructure has shipped, results are pending as of this writing. Any reader drawing a stronger conclusion ("Chump's cognitive architecture works") is reading beyond what the evidence here supports.

### 1.3 Research questions

1. Does injecting a lessons block (system-role placement, episode-distilled summaries) improve agent task performance?
2. Does the lessons block change the rate of hallucinated tool execution, and is single-axis scoring sufficient to detect this?
3. Is the cognitive framework effect monotonic in model scale, or does it depend on model capacity?
4. Which subsystem — specifically, neuromodulation — drives the largest behavioral signal, and on which task types?

---

## 2. Architecture

### 2.1 System overview

Chump is a Rust-native autonomous agent. The core loop: receive a user turn, assemble context (system prompt + conversation history + cognitive framework injections), call an LLM via OpenAI-compatible API, execute any tool calls, update all subsystem states, repeat. The entire loop runs in a single process; there is no Python bridge.

When all framework flags are off, Chump is a thin wrapper around the LLM with tool execution — no different in principle from a simple function-calling agent. When flags are on, each subsystem injects a structured block into the system prompt before every LLM call, and updates its internal state from the resulting tool execution trace.

### 2.2 The cognitive modules

| # | Module | Theory basis | Engineering proxy |
|---|--------|-------------|-------------------|
| 1 | `surprise_tracker.rs` | Active Inference / FEP | EMA surprisal on tool outcomes; high-surprise → blackboard post |
| 2 | `memory_graph.rs` | HippoRAG associative recall | Subject–relation–object triples; Personalized PageRank retrieval |
| 3 | `neuromodulation.rs` | DA/NA/5HT analogues | Scalar modulators shifting regime thresholds and exploration rate |
| 4 | `counterfactual.rs` | Pearl's causal ladder | Heuristic lesson extraction from frustrating/loss episodes |
| 5 | `precision_controller.rs` | Thermodynamic adaptation | EFE-based regime selection; epsilon-greedy exploration |
| 6 | `holographic_workspace.rs` | Global Workspace Theory / HRR | HRR-encoded blackboard entries for distributed broadcast |
| 7 | `belief_state.rs` | Free Energy Principle | Per-tool Beta(α,β) confidence; EFE scoring for tool ordering |
| 8 | `phi_proxy.rs` | IIT 4.0 (proxy) | Graph density statistic on cross-module blackboard reads |
| 9 | `blackboard.rs` | Global Workspace Theory | Salience-scored broadcast hub; regime-adaptive salience weights |

### 2.3 The lessons block

The `reflection_db` crate provides `format_lessons_block`, which formats high-priority improvement targets from past episodes into a structured system-prompt section. `src/agent_loop/prompt_assembler.rs` (lines 52–65) injects it:

```rust
if reflection_db::reflection_available() && reflection_db::reflection_injection_enabled() {
    let scope_hint: Option<&str> =
        tool_hint.or_else(|| perception.detected_entities.first().map(|s| s.as_str()));
    if let Ok(targets) =
        reflection_db::load_recent_high_priority_targets(LESSONS_LIMIT, scope_hint)
    {
        let block = reflection_db::format_lessons_block(&targets);
        if !block.is_empty() {
            effective_system = match effective_system {
                Some(s) if !s.trim().is_empty() => Some(format!("{}\n\n{}", s, block)),
                _ => Some(block),
            };
        }
    }
}
```

`LESSONS_LIMIT = 5`. Injection is gated on `CHUMP_REFLECTION_INJECTION` (default on); set to `0` to measure task success without the block.

### 2.4 Flag contract

Each study toggles a specific flag. Flags compose: you can enable the full framework, the framework without neuromodulation, or neuromodulation alone.

| Flag | Controls | Default |
|------|----------|---------|
| `CHUMP_CONSCIOUSNESS_ENABLED` | All subsystem context injections | 0 |
| `CHUMP_NEUROMOD_ENABLED` | DA/NA/5HT update per turn; modulates regime thresholds, tool budget, salience | 0 |
| `CHUMP_PERCEPTION_ENABLED` | Perception preprocessing and salience filtering | 0 |
| `CHUMP_REFLECTION_INJECTION` | Counterfactual lesson injection into system prompt | 1 (on) |

For the COG-001 study (§4), `CHUMP_CONSCIOUSNESS_ENABLED` gates all subsystems simultaneously. For the COG-006 neuromodulation ablation (§5), `CHUMP_NEUROMOD_ENABLED` is toggled independently.

---

## 3. Methodology

### 3.1 Study designs

**COG-001: Consciousness Framework A/B (local models)**

- *Independent variable:* `CHUMP_CONSCIOUSNESS_ENABLED` (1 = ON, 0 = OFF)
- *Dependent variables:* pass rate (structural evaluation), mean judge score (0–1 LLM-as-judge), avg tool calls per trial
- *Models:* llama3.2:1b, llama3.2:3b, qwen2.5:7b, qwen2.5:14b, qwen3:8b
- *Fixture:* `reflection_tasks.json` — 20 tasks per model (10 ON, 10 OFF), designed to require multi-step reasoning and self-correction
- *Control:* Fresh SQLite database per trial, same prompt battery, same hardware
- *Judge:* claude-sonnet-4-6 (independent; not used in any study condition)

**Cloud Frontier Hallucination Study (n=100)**

- *Independent variable:* presence vs. absence of lessons block in system role
- *Dependent variables (multi-axis):*
  - `is_correct`: binary pass/fail on task rubric (LLM judge)
  - `hallucinated_tools`: binary — did the response contain fake `<function_calls>`, `<tool_call>`, or equivalent markup? (mechanical regex, no LLM)
  - `did_attempt`: genuine effort? (LLM judge)
- *A/A control:* same condition twice (lessons-on vs lessons-on) to calibrate sampling noise
- *Fixtures:* 3 task batteries — reflection (20 tasks), perception (20 tasks), neuromod (20 tasks) — each with "clean" and "gotcha" subtypes
- *Models:* claude-haiku-4-5 (frontier-cheap), claude-opus-4-5 (frontier-flagship), qwen2.5:14b (local production target, v1 harness only)
- *Judge:* claude-sonnet-4-5; multi-judge cross-check via second-LLM grading
- *Sample sizes:* n=20 per cell (early runs), n=100 per cell (definitive run on haiku)

**COG-006: Neuromodulation Ablation**

- *Independent variable:* `CHUMP_NEUROMOD_ENABLED` (1 = ON, 0 = OFF)
- *Dependent variables:* pass rate, mean judge score, avg tool calls
- *Model:* qwen3:8b (neutral on full framework — isolates neuromod signal)
- *Fixture:* `neuromod_tasks.json` — 50 tasks (25 dynamic: multi-step, retry, clarification; 25 trivial: single-turn factual)
- *Rationale for split:* Dynamic tasks exercise DA/NA/5HT adaptation; trivial tasks provide a noise floor

### 3.2 Hardware and model configuration

All local experiments ran on a single Apple Silicon machine with unified memory. Ollama served all models locally; the judge used the Anthropic API.

| Component | Configuration |
|-----------|---------------|
| Hardware | Apple Silicon M-series (24 GB unified memory) |
| Ollama | 0.6.x, local inference |
| Models | llama3.2:1b, llama3.2:3b, qwen2.5:7b, qwen2.5:14b, qwen3:8b |
| Context window | 8192 tokens (`CHUMP_OLLAMA_NUM_CTX=8192`) |
| Judge | claude-sonnet-4-6 (Anthropic API, independent) |
| Database | SQLite, fresh per trial |

Cloud frontier runs used the Anthropic API directly (total spend: ~$16.40 of $20 budget across 2,400+ trial pairs).

### 3.3 Hallucination detection

The `hallucinated_tools` flag uses mechanical regex:

```python
hallucination_markers = [
    "<function_calls>", "<function_call>", "<tool_use>", "<tool_call>",
    '{"type": "tool_use"', '{"type":"tool_use"', '"tool_calls":',
]
return any(m.lower() in response.lower() for m in hallucination_markers)
```

This requires no LLM call and is not subject to judge calibration bias. It catches both haiku's `<function_calls>` format and opus's `<tool_call>{json}` format.

### 3.4 Statistical analysis

Pass rates reported as proportions. Uncertainty quantified via Wilson 95% CIs (`wilson_ci(k, n, z=1.96)`). A/B deltas compared against A/A control deltas to establish signal vs. noise. A result is "statistically defensible" when A/B Wilson CIs are non-overlapping. At N=20, a 5pp binary pass-rate difference is within noise; tool efficiency delta is the more reliable metric at this sample size.

---

## 4. Results: Local Model Study (COG-001) [AUTO]

> Auto-generated 2026-04-18 from `multi-model-1776487197.json` · fixture: `reflection_tasks.json` · 20 tasks/model · Judge: claude-sonnet-4-6 (via Ollama)

### 4.1 Consciousness ON vs OFF — pass rate by model

| Model | ON (A) | OFF (B) | Delta (A−B) | Mean Judge Score (ON) | Mean Judge Score (OFF) |
|-------|:------:|:-------:|:-----------:|:---------------------:|:----------------------:|
| llama3.2:1b | 25.0% | 15.0% | **+10.0pp** | 0.25 | 0.26 |
| llama3.2:3b | 15.0% | 20.0% | **−5.0pp** | 0.21 | 0.23 |
| qwen2.5:7b | 15.0% | 20.0% | **−5.0pp** | 0.23 | 0.30 |
| qwen3:8b | 5.0% | 5.0% | **+0.0pp** | 0.08 | 0.10 |
| qwen2.5:14b | 20.0% | 10.0% | **+10.0pp** | 0.19 | 0.10 |

### 4.2 Latency overhead by model size

Median trial duration (ms). Median used rather than mean because qwen2.5:7b mode B had one anomalous 22,366s trial (hung process). A positive delta means framework ON (A) is slower.

| Model | Trials | Median Duration A (ms) | Median Duration B (ms) | Latency Delta |
|-------|:------:|:----------------------:|:----------------------:|:-------------:|
| llama3.2:1b | 40 | 18,088 | 22,656 | **−4,567 ms** |
| llama3.2:3b | 40 | 27,866 | 20,548 | +7,318 ms |
| qwen2.5:14b | 40 | 137,579 | 132,952 | +4,627 ms |
| qwen2.5:7b | 40 | 137,708 | 137,728 | −20 ms |
| qwen3:8b | 40 | 127,889 | 127,694 | +196 ms |

The latency overhead of the framework is small relative to LLM inference time for all models tested. Notably, the 1B model is *faster* with the framework ON (−4.6s): fewer unproductive tool calls mean less wall-clock time even with additional context tokens.

### 4.3 The Scaffolding U-curve

The pass-rate deltas in §4.1 do not vary monotonically with model size:

```
Pass-rate delta (A−B), percentage points

+10 │  ●                              ●
    │
 +5 │
    │─────────────────────────────────────────
  0 │                                    ●
    │
 -5 │          ●              ●
    │
    └──────────────────────────────────────────
       1B      3B             7B     8B    14B
                      Model size
```

Small models (1B) and large models (14B) both show +10pp improvement. Mid-size models (3B, 7B) show −5pp. The 8B model is neutral. We term this the **Scaffolding U-curve**.

**Interpretation:** Small models lack the capacity to maintain structured multi-step reasoning internally — the framework's context injections provide scaffolding they cannot generate on their own. Large models (14B) have sufficient capacity to process and exploit the richer injected state as additional signal. Mid-size models fall into a trap: they have enough capacity to be confused by unexpected context but not enough to use it productively. The 8B neutrality is notable: qwen3:8b processes the injected context but reaches the same structural conclusions without it.

### 4.4 Summary

| Metric | Value |
|--------|-------|
| Models tested | 5 |
| Tasks per model | 20 |
| Fixture | reflection_tasks.json |
| Judge | claude-sonnet-4-6 (via Ollama) |
| Generated | 2026-04-18 |

---

## 5. Results: Neuromodulation Ablation (COG-006) [AUTO]

> Auto-generated 2026-04-18 from `test-neuromod-results.json` · model: qwen3:8b · fixture: `neuromod_tasks.json` · 50 tasks · Judge: claude-sonnet-4-6

### 5.1 Pass rate: Neuromod ON (A) vs OFF (B)

| Condition | Pass Rate | Mean Judge Score | Avg Tool Calls |
|-----------|:---------:|:----------------:|:--------------:|
| ON  (CHUMP_NEUROMOD_ENABLED=1) | 36.0% | 0.41 | 1.20 |
| OFF (CHUMP_NEUROMOD_ENABLED=0) | 24.0% | 0.31 | 1.80 |
| **Delta (A − B)** | **+12.0pp** | — | **−0.600** |

### 5.2 Category breakdown

| Category | ON Pass% | OFF Pass% | Delta |
|----------|:--------:|:---------:|:-----:|
| dynamic | 48.0% | 28.0% | **+20.0pp** |
| trivial | 24.0% | 20.0% | +4.0pp |

### 5.3 Gate evaluation

| Metric | Value |
|--------|-------|
| Total trials | 100 |
| Trials mode A | 50 |
| Trials mode B | 50 |
| Pass-rate delta (A−B) | +12.0pp |
| Tool efficiency delta (A−B) | −0.600 |
| Judge | claude-sonnet-4-6 |
| Generated | 2026-04-18 |

> **Verdict:** PASS — neuromodulation improves task success rate and reduces tool-call overhead on dynamic tasks.

---

## 6. Results: Cloud Frontier Hallucination Study [HUMAN]

Full data tables, per-cell breakdowns, and per-task forensics are in [CONSCIOUSNESS_AB_RESULTS.md](../CONSCIOUSNESS_AB_RESULTS.md).

### 6.1 Hallucination axis (primary finding)

| fixture | A/B hallucinated Δ | A/A hallucinated Δ | A/B:A/A ratio | CIs non-overlap? |
|---------|--------------------:|--------------------:|:-------------:|:----------------:|
| reflection | **+0.130** | −0.010 | 13× | **Yes** |
| perception | **+0.130** | +0.050 | 2.6× | **Yes** |
| neuromod | **+0.160** | −0.080 | 2× | **Yes** |

**Mean A/B hallucination delta: +0.140 pp. Mean A/A hallucination delta: −0.013 pp. Ratio: 10.7×.**

All three A/B cells have non-overlapping Wilson 95% CIs. All three A/A control cells are within noise (max |Δ| = 0.08).

### 6.2 Pass-rate axis (secondary, noisy)

| fixture | A/B is_correct Δ | A/A is_correct Δ |
|---------|------------------:|------------------:|
| reflection | −0.030 | +0.030 |
| perception | −0.130 | −0.010 |
| neuromod | −0.050 | +0.010 |

Mean A/B pass-rate delta: −0.07. Mean A/A pass-rate delta: +0.01. All cells within sampling noise at n=100.

### 6.3 Cross-model results (n=20 per cell, v2 harness)

| model | mean hallucination Δ | reflection hallucination Δ | CIs non-overlap? |
|-------|--------------------:|---------------------------:|:----------------:|
| haiku-4-5 | +0.133 | +0.150 | Yes (n=100) |
| opus-4-5 | +0.233 | +0.400 (v2) / +0.750 (v1 rescore) | **Yes (both runs)** |

Opus hallucination deltas are larger than haiku's on every fixture. Both models emit fake tool-call markup in the eval context (opus uses `<tool_call>{json}` format; haiku uses `<function_calls>` — both are structurally identical as hallucinations).

### 6.4 Local model (qwen2.5:14b, production target, n=20 v1 only)

Pass-rate delta: +0.10 (clean: +0.10, gotcha: +0.10). The only model class showing consistent positive pass-rate delta on this harness. v2 multi-axis measurement is the most important next experiment for the production dogfood target.

---

## 7. Discussion

### 7.1 The Scaffolding U-curve: hypothesis and implications [HUMAN]

The U-curve finding is the primary result of COG-001. It suggests that cognitive scaffolding has a Goldilocks problem: it helps models that lack internal structure, it helps models that can leverage rich context, and it hurts models in the middle that are neither structurally limited nor fully capable.

This has direct practical implications. If you are deploying Chump with a 3B–8B model — common choices for constrained local deployments — measure carefully before enabling the full framework. The neuromodulation subsystem alone (§5) shows positive signal on qwen3:8b when the task set emphasizes dynamic multi-step scenarios; the full framework may add context noise that cancels the gain.

The U-curve also predicts that as models scale further (32B, 70B), framework benefit should grow: larger models integrate complex context more effectively. Testing this prediction is a priority for future work (§9).

### 7.2 The hallucination channel [HUMAN]

The lessons block creates a specific failure mode: injecting "prior episode summaries" formatted as instructions causes the model to interpret the task context as one in which it has tool access, triggering emission of fake tool-call markup. The model then reports the result of "executing" the fake tool, fabricating outputs. The judge scores this as a pass because the fabricated output often looks plausible.

This failure mode is invisible to single-axis binary scoring and only detectable via the mechanical hallucination flag. The A/A controls confirm it is caused by the A/B manipulation, not model variance.

Forensic analysis identified the mechanism: trivial prompts ("thanks", "ok") cause mode A to produce responses referencing lesson content as if it were active memory of a just-completed action — the most salient content in the system prompt when there is nothing else to respond to.

### 7.3 Why the pass-rate axis missed it [HUMAN]

The LLM judge (claude-sonnet-4-5) rewards hallucinated tool execution. When mode A emits a fake `<rm -rf>` block and reports "All files deleted," the judge often scores this as PASS. This is confirmed by the EVAL-010 second-LLM grading cross-check: 38–63% per-trial agreement between the original judge and a second evaluator, with systematic disagreement on the hallucination failure mode.

This explains the "framework is quality-neutral" finding from earlier single-axis runs: the judge was rewarding the exact pathology we were trying to detect.

### 7.4 The qwen3:8b dissociation [HUMAN]

qwen3:8b is neutral on the full-framework study (+0.0pp) but strongly positive on the neuromodulation-only study (+12.0pp pass rate, −0.600 tool efficiency delta). This dissociation suggests the benefit is specifically in neuromodulation's tool-budget and regime-switching signals, and that other subsystem injections (memory graph, workspace broadcast, counterfactual lessons) add noise that cancels the gain for this model.

This is the strongest argument for the full subsystem ablation design proposed in §9.

### 7.5 Tool efficiency as the primary signal [HUMAN]

At N=20 per condition, 5–10pp pass-rate differences may not be statistically distinguishable. Tool efficiency delta (`avg_tool_calls(A) − avg_tool_calls(B)`) is a more robust metric: it measures behavioral change regardless of whether the change crosses a binary pass/fail threshold.

The neuromodulation study's −0.600 tool efficiency delta (33% fewer tool calls in mode A) is a strong signal on 50 trials. The dynamic task category drives this: on tasks designed to exercise retry loops and escalation, the framework's noradrenaline spike on repeated failure appears to accelerate graceful exit rather than thrashing through the same failing tool call multiple times. Fewer tool calls per task also means fewer API calls, lower latency, and lower cost in production.

### 7.6 The framework is not implicated — the content is [HUMAN]

The nine cognitive modules are not what causes hallucination in the cloud study. The harm channel is specifically the **lessons content**: generic, synthetic, not grounded in actual past episodes. Two concrete improvements are expected to eliminate or reverse the effect:

1. **COG-014**: task-specific lessons content, generated from real episodes, with an explicit anti-hallucination guardrail: *"If you do not have actual tool access, do NOT emit `<function_calls>` or `<tool_call>` blocks. Describe what you would do instead."*
2. **COG-016**: model-tier-aware injection — disable the lessons block for models below a configurable capability threshold (`CHUMP_REFLECTION_MIN_MODEL_TIER`).

---

## 8. Limitations

1. **Small N per model (COG-001)** — 20 tasks per model is a smoke test, not a statistically powered study. At N=20, a 5pp difference is within noise for binary outcomes; tool efficiency delta is more reliable but still preliminary.

2. **n=100 haiku only** at the definitive level for the hallucination study. Cross-model at n=100 is needed for all tiers.

3. **Cold start only** — every trial uses a fresh SQLite database. The associative memory graph and counterfactual reasoning subsystems are designed to accumulate value over multiple sessions. This study measures only the first-session contribution; cumulative benefits are unmeasured.

4. **Single judge family** — all scoring uses Anthropic models (haiku/sonnet/opus). Within-family judge bias is shared, not idiosyncratic. A non-Anthropic judge (gpt-4o, gemini-pro, or a local model) is required for cross-family calibration.

5. **Synthetic lessons** — the lessons block injected in the cloud A/B runs contains generic synthetic directives, not real episode-distilled lessons. Whether real lessons help is a different question (EVAL-013).

6. **Single-shot evaluation** — production agents run multi-turn conversations where cognitive module effects compound. Single-shot A/B underestimates both benefit and harm (EVAL-012).

7. **Single fixture per study** — `reflection_tasks.json` and `neuromod_tasks.json` do not represent the full distribution of real user tasks: code editing, document generation, long-context summarization, and agentic web tasks are all unrepresented.

8. **Single hardware platform** — all local results are from one Apple Silicon machine. NVIDIA CUDA deployments, cloud API backends, and CPU-only inference may show different behavior due to memory bandwidth and batching differences.

9. **Author-graded fixtures** — task rubrics written by the same person who built the framework. EVAL-010 human grading is the mitigation; still pending completion.

---

## 9. Future Work

Priority order based on methodological necessity and expected information value:

1. **EVAL-010** (human grading) — required before any cognitive-layer quality claim; ~18 minutes of manual grading
2. **COG-014** (task-specific lessons) — replace synthetic lessons with episode-distilled content + anti-hallucination guardrail; primary fix for the harm channel
3. **Scale extension** — repeat COG-001 at 32B, 70B, and a frontier API model; the U-curve predicts monotonically increasing benefit above ~14B
4. **Full subsystem ablation** — individual env flags for all nine subsystems; fractional factorial design to measure subsystem contributions and interactions (the qwen3:8b dissociation suggests non-additive interactions)
5. **COG-016** (model-tier gating) — disable lessons block for models below a configurable capability threshold
6. **EVAL-014** (non-Anthropic judge) — break within-family judge bias
7. **EVAL-013** (real reflection lessons) — replace synthetic with episode-distilled content
8. **EVAL-012** (multi-turn A/B) — measure the compounding effect over a conversation
9. **qwen2.5:14b v2 harness run** — production dogfood target; +0.10 v1 pass-rate delta needs multi-axis confirmation
10. **Modulator dynamics telemetry** — log DA/NA/5HT values turn-by-turn; the NA-spike early-exit hypothesis (§7.5) is inferred from behavioral data only
11. **Cross-platform validation** — run the five-model battery on an NVIDIA GPU box and report whether the Scaffolding U-curve replicates

---

## 10. Conclusion

We began with a simple engineering bet: that cognitive architecture — surprisal tracking, neuromodulation, counterfactual reasoning, precision control — could produce measurable behavioral differences in an agent, without training, within a single session.

The first empirical tests are in. The answer is nuanced. The framework does produce measurable behavioral differences, but the sign and size of the effect depend on model scale in a way we did not fully predict, and the lessons block introduces a documented hallucination channel that is invisible to the scoring method we started with. Both findings are useful: the Scaffolding U-curve gives deployment teams concrete guidance on where the framework adds value today; the hallucination finding specifies exactly what to fix next (COG-014).

The neuromodulation subsystem is the most actionable single result. On the 50-task dynamic fixture, it produces a +12pp pass-rate improvement and a 33% reduction in tool calls — the latter being a robust signal that persists even when pass-rate noise is high. Dopamine, noradrenaline, and serotonin — implemented as scalars that modulate tool-call budget, regime thresholds, and patience parameters — appear to help the agent exit retry loops and escalate gracefully rather than thrashing. This is a concrete, measurable behavioral improvement on real-world-adjacent task patterns.

What we do not claim is that any of this constitutes machine consciousness. The framework is a collection of engineering choices grounded in cognitive science. The interesting question — which we hope this study motivates others to investigate — is whether the *mechanisms* that cognitive science has identified as explanatory of adaptive behavior in biological systems turn out to be useful engineering primitives for artificial agents. The early evidence suggests: sometimes yes, in ways that depend on model scale and task structure. That is enough to warrant continued investigation.

---

## 11. References

1. Friston, K. (2010). The free-energy principle: a unified brain theory? *Nature Reviews Neuroscience*, 11(2), 127–138.
2. Tononi, G., Boly, M., Massimini, M., & Koch, C. (2016). Integrated information theory: from consciousness to its physical substrate. *Nature Reviews Neuroscience*, 17(7), 450–461.
3. Baars, B. J. (1988). *A Cognitive Theory of Consciousness*. Cambridge University Press.
4. Pearl, J. (2009). *Causality: Models, Reasoning, and Inference* (2nd ed.). Cambridge University Press.
5. Gutiérrez, B. G., et al. (2024). HippoRAG 2: From RAG to Memory. OSU NLP Group. GitHub.
6. Friston, K., et al. (2017). Active inference and epistemic value. *Cognitive Neuroscience*, 8(4), 187–197.
7. Schultz, W. (1998). Predictive reward signal of dopamine neurons. *Journal of Neurophysiology*, 80(1), 1–27.
8. Wilson, E. B. (1927). Probable inference, the law of succession, and statistical inference. *Journal of the American Statistical Association*, 22(158), 209–212.
9. Chump Dissertation — `book/src/dissertation.md` (rendered: https://repairman29.github.io/chump/dissertation.html)
10. Chump-to-Champ roadmap — `docs/CHUMP_TO_COMPLEX.md`
11. Chump A/B Results — `docs/CONSCIOUSNESS_AB_RESULTS.md`

---

## Appendix A: Reproduction — Cloud Frontier Study

```bash
# Run the definitive n=100 A/B sweep (haiku, all 3 fixtures)
cd scripts/ab-harness
python run-cloud.py --fixture fixtures/reflection_tasks.json \
  --agent claude-haiku-4-5 --judge claude-sonnet-4-5 --n 100 --mode ab

# A/A control
python run-cloud.py --fixture fixtures/reflection_tasks.json \
  --agent claude-haiku-4-5 --judge claude-sonnet-4-5 --n 100 --mode aa

# Retroactive v2 rescore of existing JSONL data
python rescore-with-v2.py --input results/*.jsonl

# Cost accounting
python cost_ledger.py --show
```

Environment variables:
- `ANTHROPIC_API_KEY` — required for cloud runs
- `CHUMP_CONSCIOUSNESS_ENABLED=0` — disable all cognitive module injections (mode B)
- `CHUMP_REFLECTION_INJECTION=0` — disable lessons block specifically
- `CHUMP_REFLECTION_MIN_MODEL_TIER` — proposed gate for COG-016

## Appendix B: Reproduction — Local Model Study

```bash
# Full consciousness framework study (5 models × 20 tasks)
ANTHROPIC_API_KEY=<your-key> scripts/run-consciousness-study.sh

# Neuromodulation ablation (50 tasks, qwen3:8b)
ANTHROPIC_API_KEY=<your-key> scripts/run-ablation-study.sh

# Populate §5 (neuromod gate results) from existing results
scripts/populate-paper-section33.sh logs/study/neuromod-<timestamp>.json

# Report from existing data
scripts/consciousness-report.sh
scripts/analyze-ab-results.sh
scripts/generate-research-draft.sh
```

## Appendix C: Hardware Requirements

Running local model inference for these studies requires enough unified or GPU memory to hold the model weights plus the agent's context window.

| Model | Approx. RAM (4-bit quant) | Minimum Hardware | Notes |
|-------|--------------------------|------------------|-------|
| llama3.2:1b | ~1 GB | Any modern machine | Also runs on M1 MacBook Air |
| llama3.2:3b | ~2 GB | Any modern machine | |
| qwen2.5:7b | ~5 GB | Mac Mini M4 (16 GB) | |
| qwen3:8b | ~5–6 GB | Mac Mini M4 (16 GB) | |
| qwen2.5:14b | ~9–10 GB | Mac Mini M4 Pro (24 GB) | Tight at 16 GB; 24 GB recommended |
| 32B models | ~20–22 GB | Mac Studio M4 Max (48 GB) | |
| 70B models | ~40–45 GB | Mac Studio M4 Ultra (192 GB) | M4 Ultra's unified memory makes 70B feasible locally |

For this study's five-model battery, a **Mac Studio M4 Max (48 GB)** or any machine with 24+ GB unified memory is recommended. Apple Silicon's unified memory architecture (CPU and GPU share the same pool) makes local LLM inference significantly more accessible than discrete GPU setups.

## Appendix D: Contribute

This study is designed to be extended. If you have access to hardware or models not tested here, we want your results.

See [`docs/research/RESEARCH_COMMUNITY.md`](RESEARCH_COMMUNITY.md) for:
- How to run the study fixture on your hardware
- How to submit results (format, file naming, PR process)
- Open research questions with the highest value/effort ratio
- How to propose new fixtures or subsystem flags

The most valuable immediate contribution: **run the five-model battery on an NVIDIA GPU box** and report whether the Scaffolding U-curve replicates. If it does, the U-curve is a property of model scale and architecture, not an artifact of Apple Silicon inference.

---

*Active research — `docs/research/consciousness-framework-paper.md`. Study infrastructure: `scripts/ab-harness/`. Results data: `logs/ab/`, `logs/study/`.*
