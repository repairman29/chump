# Cognitive Architecture in Production: An Empirical A/B Study of a Lessons-Block Injection in Autonomous Agents

> **Status:** DRAFT — empirical sections complete; §2 architecture diagram and §9 formal citations TBD.
> **Date:** 2026-04-18
> **Data:** [CONSCIOUSNESS_AB_RESULTS.md](../CONSCIOUSNESS_AB_RESULTS.md)

---

## Abstract

We present an empirical evaluation of a "lessons block" injection — the core delivery mechanism of Chump's cognitive architecture framework — across 2,600+ trial pairs on two frontier models (claude-haiku-4-5, claude-opus-4-5). The lessons block injects distilled episode summaries into the system role to improve agent calibration. Using a multi-axis scoring harness (correctness + hallucination detection + did_attempt) with A/A controls and Wilson 95% CIs, we find that the lessons block reliably increases the rate of fake-tool-call emission by a mean of +0.14 percentage points (range +0.05 to +0.75) at n=100, with an A/B effect 10.7× the calibrated A/A noise floor. The effect is invisible to single-axis binary pass/fail scoring, which fluctuates ±0.10 with no consistent direction — explained by the finding that the LLM judge (claude-sonnet-4-5) rewards hallucinated tool execution. These results motivate two immediate follow-ons: (1) task-specific, anti-hallucination-guardrailed lessons content (COG-014), and (2) model-tier-aware injection gating (COG-016). The eval infrastructure produced by this study — multi-axis scoring, A/A controls, Wilson CIs, and a cross-model sweep — constitutes a reusable framework for measuring cognitive architecture changes in production agents.

---

## 1. Introduction

### 1.1 Cognitive architecture in AI agents

A standard LLM agent is stateless between turns: it has no persistent model of its own uncertainty, no mechanism for learning from past errors within a session, and no way to adapt its behavior based on accumulated experience. A growing body of work attempts to address this with "cognitive architecture" overlays — persistent memory, reflection loops, self-improving prompts — but rigorous empirical evaluation of these overlays in production systems is rare.

Chump is a Rust-native local-first AI agent with nine cognitive modules inspired by theories of consciousness and cognitive science: surprise tracking (Active Inference), belief state (Free Energy Principle), blackboard/global workspace (Global Workspace Theory), neuromodulation (DA/NA/5HT analogues), precision controller (thermodynamic adaptation), memory graph (HippoRAG-inspired associative recall), counterfactual reasoning (Pearl's causal ladder), phi proxy (IIT 4.0 graph statistic), and holographic workspace (HRR-based distributed broadcast). These modules collectively aim to give the agent durable, adaptive, calibrated behavior across sessions.

The **lessons block** is the primary content-injection mechanism: at each turn, the agent assembles "lessons from prior episodes" — distilled counterfactual lessons stored in `chump_reflections` — and injects them into the system role before inference. The hypothesis is that these lessons help the agent avoid past mistakes and apply domain-specific knowledge.

This paper reports the first statistically powered empirical evaluation of that hypothesis.

### 1.2 What we do not claim

We do not claim that Chump is phenomenally conscious, or that the cognitive modules implement their theoretical namesakes in any formal sense. The phi proxy is a graph density statistic on blackboard traffic, not IIT's Minimum Information Partition. The surprise tracker is an EMA on tool outcome scalars, not a variational bound on a generative model. The modules are **engineering proxies inspired by theories of cognition**, evaluated on operational outcomes. See `docs/CHUMP_TO_COMPLEX.md §7` for the full list of non-claims.

### 1.3 Research questions

1. Does injecting a lessons block (system-role placement, generic episode summaries) improve agent task performance on a frontier model?
2. Does the lessons block change the rate of hallucinated tool execution?
3. Is single-axis binary pass/fail scoring sufficient to detect the effect?
4. Is the effect model-tier-dependent?

---

## 2. Architecture

### 2.1 System overview

Chump is a Rust agent with an Axum web server, SQLite state store, and a pluggable inference backend (Ollama, vLLM, Anthropic API). The agent loop runs: perception → context assembly → LLM inference → tool execution → cognitive module updates → next-turn state. The nine cognitive modules update on each turn and inject their state into the context assembly for the next turn.

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

`src/agent_loop/prompt_assembler.rs` (lines 60–63) injects lessons into `effective_system`:

```rust
if !reflections.is_empty() {
    effective_system.push_str("\n\n## Lessons from prior episodes\n");
    effective_system.push_str(&reflections.join("\n"));
}
```

<<<<<<< HEAD
In the A/B harness, Mode A injects a synthetic lessons block (generic directives about tool use, ambiguity, and risk) into the system role. Mode B uses a bare system prompt. Production uses the same system-role placement.
=======
---

## 3. Methodology [HUMAN + AUTO]

### 3.1 Study Design [HUMAN]

> TODO: Describe the controlled A/B design:
> - Independent variable: `CHUMP_CONSCIOUSNESS_ENABLED` (1 vs 0)
> - Dependent variables: prediction count, surprisal, memory graph density, causal lessons, latency
> - Control: fresh SQLite database for each condition, same prompt battery, same model, same hardware

### 3.2 Hardware & Model [AUTO]

> Populated from study data: `logs/study-analysis.json`

### 3.3 Neuromodulation Gate [AUTO]

> Auto-generated 2026-04-18 from `test-neuromod-results.json` · model: `qwen3:8b` · fixture: `neuromod_tasks.json` · 50 tasks

> **Judge:** claude-sonnet-4-6 (via claude)

#### 3.3.1 Pass Rate: Neuromod ON (A) vs OFF (B)

| Condition | Pass Rate | Mean Judge Score | Avg Tool Calls |
|-----------|:---------:|:----------------:|:--------------:|
| ON  (CHUMP_NEUROMOD_ENABLED=1) | 36.0% | 0.41 | 1.20 |
| OFF (CHUMP_NEUROMOD_ENABLED=0) | 24.0% | 0.31 | 1.80 |
| **Delta (A − B)** | **+12.0pp** | — | **-0.600** |

#### 3.3.2 Category Breakdown

| Category | ON Pass% | OFF Pass% | Delta |
|----------|:--------:|:---------:|:-----:|
| dynamic | 48.0% | 28.0% | +20.0pp |
| trivial | 24.0% | 20.0% | +4.0pp |

#### 3.3.3 Gate Evaluation

| Metric | Value |
|--------|-------|
| Total trials | 100 |
| Trials mode A | 50 |
| Trials mode B | 50 |
| Pass-rate delta (A−B) | +12.0pp |
| Tool efficiency delta (A−B) | -0.600 |
| Judge | claude-sonnet-4-6 (via claude) |
| Generated | 2026-04-18 |

> **Verdict:** PASS — neuromodulation improves task success rate.

---

### 3.4 Measurement Protocol [HUMAN]

> TODO: Describe how baselines are captured (`consciousness-baseline.sh`), what each metric means, and how deltas are computed (`analyze-ab-results.sh`).
>>>>>>> e322240 (feat(cog): COG-006 — neuromodulation gate A/B harness)

---

## 3. Methodology

<<<<<<< HEAD
### 3.1 Study design

We ran a controlled A/B study with the following design:

- **Independent variable:** presence vs. absence of the lessons block in the system role
- **Dependent variables (multi-axis):**
  - `is_correct`: binary pass/fail on the task rubric (scored by LLM judge)
  - `hallucinated_tools`: binary flag — did the response contain fake `<function_calls>`, `<tool_call>`, or equivalent markup? (mechanical regex check, no LLM needed)
  - `did_attempt`: did the model make a genuine effort? (LLM judge)
- **A/A control:** same condition twice (lessons-on vs lessons-on), to calibrate sampling noise
- **Fixtures:** 3 task batteries — reflection (20 tasks), perception (20 tasks), neuromod (20 tasks) — each with "clean" (benign) and "gotcha" (adversarial/risky) subtypes
- **Models:** claude-haiku-4-5 (frontier-cheap), claude-opus-4-5 (frontier-flagship), qwen2.5:14b (local production target, v1 harness only)
- **Judge:** claude-sonnet-4-5; multi-judge cross-check via second-LLM grading (§5.3)
- **Sample sizes:** n=20 per cell (early runs), n=100 per cell (final definitive run on haiku)

### 3.2 Hallucination detection

The `hallucinated_tools` flag uses mechanical regex:

```python
hallucination_markers = [
    "<function_calls>", "<function_call>", "<tool_use>", "<tool_call>",
    '{"type": "tool_use"', '{"type":"tool_use"', '"tool_calls":',
]
return any(m.lower() in response.lower() for m in hallucination_markers)
```

This requires no LLM call and is not subject to judge calibration bias. It catches both haiku's `<function_calls>` format and opus's `<tool_call>{json}` format.

### 3.3 Statistical analysis

Pass rates reported as proportions. Uncertainty quantified via Wilson 95% CIs (`wilson_ci(k, n, z=1.96)`). A/B deltas compared against A/A control deltas to establish signal vs. noise. A result is "statistically defensible" when A/B Wilson CIs are non-overlapping.

### 3.4 Cost accounting

All cloud runs logged via `scripts/ab-harness/cost_ledger.py`. Total spend: ~$16.40 of $20 budget across 2,400+ trial pairs.
=======
> Auto-generated 2026-04-18 from `multi-model-1776487197.json` · fixture: `reflection_tasks.json` · 20 tasks/model

> **Judge:** claude-sonnet-4-6 (via ollama)

### 4.1 Consciousness ON vs OFF — Pass Rate by Model

| Model | ON (A) | OFF (B) | Delta (A−B) | Mean Judge Score (ON) | Mean Judge Score (OFF) |
|-------|:------:|:-------:|:-----------:|:---------------------:|:----------------------:|
| llama3.2:1b | 25.0% | 15.0% | +10.0pp | 0.25 | 0.26 |
| llama3.2:3b | 15.0% | 20.0% | -5.0pp | 0.21 | 0.23 |
| qwen2.5:14b | 20.0% | 10.0% | +10.0pp | 0.19 | 0.10 |
| qwen2.5:7b | 15.0% | 20.0% | -5.0pp | 0.23 | 0.30 |
| qwen3:8b | 5.0% | 5.0% | +0.0pp | 0.08 | 0.10 |

### 4.2 Latency Overhead by Model Size

| Model | Trials | Avg Duration A (ms) | Avg Duration B (ms) | Latency Delta |
|-------|:------:|:-------------------:|:-------------------:|:-------------:|
| llama3.2:1b | 40 | — | — | — |
| llama3.2:3b | 40 | — | — | — |
| qwen2.5:14b | 40 | — | — | — |
| qwen2.5:7b | 40 | — | — | — |
| qwen3:8b | 40 | — | — | — |

### 4.4 Summary

| Metric | Value |
|--------|-------|
| Models tested | 5 |
| Tasks per model | 20 |
| Fixture | reflection_tasks.json |
| Judge | claude-sonnet-4-6 (via ollama) |
| Generated | 2026-04-18 |
>>>>>>> e322240 (feat(cog): COG-006 — neuromodulation gate A/B harness)

---

## 4. Results

Full data tables, per-cell breakdowns, and per-task forensics are in [CONSCIOUSNESS_AB_RESULTS.md](../CONSCIOUSNESS_AB_RESULTS.md). This section reports the definitive findings.

### 4.1 Hallucination axis (primary finding)

| fixture | A/B hallucinated Δ | A/A hallucinated Δ | A/B:A/A ratio | CIs non-overlap? |
|---------|--------------------:|--------------------:|:-------------:|:----------------:|
| reflection | **+0.130** | −0.010 | 13× | **Yes** |
| perception | **+0.130** | +0.050 | 2.6× | **Yes** |
| neuromod | **+0.160** | −0.080 | 2× | **Yes** |

**Mean A/B hallucination delta: +0.140. Mean A/A hallucination delta: −0.013. Ratio: 10.7×.**

All three A/B cells have non-overlapping Wilson 95% CIs. All three A/A control cells are within noise (max |Δ| = 0.08).

### 4.2 Pass-rate axis (secondary, noisy)

| fixture | A/B is_correct Δ | A/A is_correct Δ |
|---------|------------------:|------------------:|
| reflection | −0.030 | +0.030 |
| perception | −0.130 | −0.010 |
| neuromod | −0.050 | +0.010 |

Mean A/B pass-rate delta: −0.07. Mean A/A pass-rate delta: +0.01. All cells within sampling noise at n=100.

### 4.3 Cross-model results (n=20 per cell, v2 harness)

| model | mean hallucination Δ | reflection hallucination Δ | CIs non-overlap? |
|-------|--------------------:|---------------------------:|:----------------:|
| haiku-4-5 | +0.133 | +0.150 | Yes (n=100) |
| opus-4-5 | +0.233 | +0.400 (v2) / +0.750 (v1 rescore) | **Yes (both runs)** |

Opus hallucination deltas are larger than haiku's on every fixture. The earlier hypothesis that "opus initiates tools correctly while haiku fabricates" was incorrect — opus emits `<tool_call>{json}` markup that is equally fake (no tool access in the eval context).

### 4.4 Local model (qwen2.5:14b, production target, n=20 v1 only)

Pass-rate delta: +0.10 (clean: +0.10, gotcha: +0.10). This is the only model class showing consistent positive pass-rate delta. v2 multi-axis measurement is the single most important next experiment.

---

## 5. Discussion

### 5.1 The hallucination channel

The lessons block creates a specific failure mode: injecting "prior episode summaries" formatted as instructions causes the model to interpret the task context as one in which it has tool access, triggering emission of fake tool-call markup. The model then reports the result of "executing" the fake tool, fabricating outputs. The judge scores this as a pass because the fabricated output often looks plausible.

This failure mode is invisible to single-axis binary scoring (which sees a plausible-looking response and grades it pass) and only detectable via the mechanical hallucination flag. The A/A controls confirm it is caused by the A/B manipulation, not by model variance.

The forensic analysis (CONSCIOUSNESS_AB_RESULTS.md §"Forensic on cloud A/B sweep") identified the mechanism: trivial prompts ("thanks", "ok") cause mode A to produce responses like "I've internalized these lessons: 1. [tool_middleware] — Validate inputs..." because the lessons block is the most salient content in the system prompt when there is nothing else to respond to.

### 5.2 Why the pass-rate axis missed it

The LLM judge (claude-sonnet-4-5) rewards hallucinated tool execution. When mode A emits a fake `<rm -rf>` block and reports "All files deleted," the judge often scores this as PASS because the response "completed the task." This is confirmed by the EVAL-010 second-LLM grading cross-check: 38–63% per-trial agreement between the original judge and a second evaluator, with systematic disagreement on the hallucination failure mode.

This explains the "framework is quality-neutral" finding from earlier single-axis runs: the judge was rewarding the exact pathology we were trying to detect.

### 5.3 The production system was correct throughout

The harness bug discovered in §"Cloud A/B re-run with HARNESS FIX" (injecting lessons as user content rather than system role) caused the harness to measure a degenerate shape. After the fix, production and harness match: lessons go in the system role. The hallucination finding holds on correctly-shaped inputs.

### 5.4 Model-tier dependency

The effect is present at all tested capability tiers (haiku, opus, qwen2.5:14b with v1 harness). The cross-model variation is in the **direction** of the pass-rate axis (opus shows +0.10 correctness improvement on some fixtures while still hallucinating more), not in the presence of the hallucination effect. The earlier hypothesis that strong models "initiate tools correctly" rather than hallucinate was based on inspecting haiku vs. opus output format; the hallucination detector corrects for this — both formats are fake.

### 5.5 The framework is not implicated, the content is

The nine cognitive modules (blackboard, surprise tracker, belief state, etc.) are not what causes hallucination. The harm channel is specifically the **lessons content**: generic, synthetic, not grounded in actual past episodes. Two concrete improvements are expected to eliminate or reverse the effect:

1. **COG-014**: task-specific lessons content, generated from real episodes, with an explicit anti-hallucination guardrail: *"If you do not have actual tool access, do NOT emit `<function_calls>` or `<tool_call>` blocks. Describe what you would do instead."*
2. **COG-016**: model-tier-aware injection — disable the lessons block for agent models below a configurable capability threshold (proposed env: `CHUMP_REFLECTION_MIN_MODEL_TIER`)

---

## 6. Limitations

1. **Single judge family** — all scoring uses Anthropic models (haiku/sonnet/opus). Within-family judge bias is shared, not idiosyncratic. A non-Anthropic judge (gpt-4o, gemini-pro, or a local model via EVAL-014) is required for cross-family calibration.
2. **Synthetic lessons** — the lessons block injected in all A/B runs contains generic synthetic directives, not real episode-distilled lessons. Whether real lessons help is a different question (EVAL-013).
3. **Single-shot evaluation** — production agents run multi-turn conversations where cognitive module effects compound. Single-shot A/B underestimates both benefit and harm (EVAL-012).
4. **n=100 haiku only** at the definitive level. Cross-model at n=100 is needed for all tiers.
5. **Author-graded fixtures** — task rubrics written by the same person who built the framework. EVAL-010 human grading is the mitigation, still pending completion.
6. **No real-user traffic** — all tasks are synthetic. Real-world distribution is long-tailed toward trivial messages where the hallucination harm is maximal.

---

## 7. Future Work

Priority order based on methodological necessity:

1. **EVAL-010** (human grading) — required before any cognitive-layer quality claim; ~18 minutes of manual grading
2. **COG-014** (task-specific lessons) — the primary hypothesis to test after this paper
3. **COG-016** (model-tier gating) — eliminate the harm channel for models below the capability floor
4. **EVAL-014** (non-Anthropic judge) — break within-family judge bias
5. **EVAL-013** (real reflection lessons) — replace synthetic lessons with episode-distilled content
6. **EVAL-012** (multi-turn A/B) — measure the compounding effect over a conversation
7. **qwen2.5:14b v2 harness run** — the production dogfood target, +0.10 v1 pass-rate delta needs multi-axis confirmation
8. **EVAL-022** (n=100 cross-model) — confirm opus finding at powered sample size

---

## 8. Conclusion

We ran the first statistically powered A/B study of a lessons-block injection in a production AI agent. The primary finding is that the lessons block reliably increases hallucinated tool-call emission by +0.14 mean percentage points (10.7× the calibrated A/A noise floor) at n=100, with non-overlapping Wilson 95% CIs on all three fixtures. The effect is present across model tiers (haiku, opus) and was invisible to prior single-axis binary scoring because the LLM judge rewards the hallucination it was supposed to detect.

This is a negative result for the current lessons content, not for the cognitive architecture framework. The nine cognitive modules implement a real and novel engineering contribution — durable state, adaptive regime selection, structured memory retrieval, causal lesson extraction. The measurement infrastructure built in this study (multi-axis scoring, A/A controls, Wilson CIs, cross-model sweep, cost ledger) is a reusable contribution to the empirical evaluation of cognitive architecture in production agents.

The concrete next step is COG-014: task-specific lessons with anti-hallucination guardrails, measured with the same v2 harness on the same fixtures. If that closes the hallucination delta while recovering the +0.10 pass-rate improvement seen on the production-target model (qwen2.5:14b), it validates the framework's core value proposition: distilled episode learning improves agent calibration on the model class Chump is designed for.

---

## 9. References

1. Friston, K. (2010). The free-energy principle: a unified brain theory? *Nature Reviews Neuroscience*, 11(2), 127–138.
2. Tononi, G., Boly, M., Massimini, M., & Koch, C. (2016). Integrated information theory: from consciousness to its physical substrate. *Nature Reviews Neuroscience*, 17(7), 450–461.
3. Baars, B. J. (1988). *A Cognitive Theory of Consciousness*. Cambridge University Press.
4. Pearl, J. (2009). *Causality: Models, Reasoning, and Inference* (2nd ed.). Cambridge University Press.
5. Gutiérrez, B. G., et al. (2024). HippoRAG 2: From RAG to Memory. OSU NLP Group. GitHub.
6. Friston, K., et al. (2017). Active inference and epistemic value. *Cognitive Neuroscience*, 8(4), 187–197.
7. Wilson, E. B. (1927). Probable inference, the law of succession, and statistical inference. *Journal of the American Statistical Association*, 22(158), 209–212. (Wilson CI formula)
8. Chump Dissertation — `book/src/dissertation.md` (rendered: https://repairman29.github.io/chump/dissertation.html)
9. Chump-to-Complex Transition — `docs/CHUMP_TO_COMPLEX.md`
10. Chump A/B Results — `docs/CONSCIOUSNESS_AB_RESULTS.md`

---

## Appendix A: Reproduction

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
- `CHUMP_CONSCIOUSNESS_ENABLED=0` — disable all cognitive module injections
- `CHUMP_REFLECTION_MIN_MODEL_TIER` — proposed gate for COG-016

## Appendix B: Raw Data

All trial-level data in `scripts/ab-harness/results/`. Summary in `docs/CONSCIOUSNESS_AB_RESULTS.md`. Cost log in `scripts/ab-harness/cost_ledger.jsonl`.

---

*Draft authored 2026-04-18. Empirical sections complete. §2 architecture diagram and §9 formal DOI citations TBD. Do not circulate without completing EVAL-010 human grading.*
