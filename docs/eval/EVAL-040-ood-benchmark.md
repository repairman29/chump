# EVAL-040 — OOD Benchmark: BFCL-Inspired Function-Calling A/B

**Gap:** EVAL-040
**Date filed:** 2026-04-20
**Status:** Fixture and methodology shipped — pilot run pending
**Priority:** P3
**Effort:** M

---

## Purpose

Chump's Problem Solving faculty is currently validated only on three internal fixtures:
`reflection_tasks.json`, `warm_consciousness_tasks.json`, and `neuromod_tasks.json`. All three
were designed to test Chump-specific tool vocabulary and internal reasoning patterns. They are
**in-distribution**: they test behaviors the lessons block was explicitly designed to improve.

This gap extends validation with one **out-of-distribution (OOD)** benchmark — a function-calling
fixture adapted from the BFCL category structure. The key question is whether Chump's lessons
block generalises to a task domain it was not written for.

---

## Benchmark Selection Rationale

### Why BFCL (Berkeley Function-Calling Leaderboard) over MMLU or ARC-AGI

| Benchmark | Rationale for/against |
|-----------|----------------------|
| **BFCL (selected)** | Tests structured reasoning against external API schemas — a domain Chump's lessons block does not explicitly address. Exercises type validation, argument construction, error recovery, and multi-step composition. Publicly available (gorilla.cs.berkeley.edu). Directly relevant to Chump's agent-loop use case (agents call external tools). Low cost: 20 tasks, heuristic scoring viable. |
| MMLU | Knowledge-recall benchmark. Chump's lessons block targets *procedural* behaviors (check before write, ask before act) not declarative knowledge. MMLU would test memorisation, not instruction-following improvements. Not a useful OOD signal for the lessons-block thesis. |
| ARC-AGI | Visual/abstract reasoning. Requires multimodal capability or pixel-grid representation. Not supported by the current text-only harness (`run.sh`). Implementation cost is high relative to signal value at this stage. |
| HumanEval / MBPP | Code-generation benchmarks. Partially tested by existing fixtures (Chump generates code in some reflection tasks). Not sufficiently OOD. |

**BFCL is the right choice** because: (a) function-calling reasoning is architecturally adjacent to
what Chump does (it calls tools), (b) the benchmark does NOT test Chump-specific tools, so lessons
about Chump internals should NOT help unless the lessons block teaches generalizable caution and
structure, and (c) the task format (schema + edge cases) is naturally scored by the existing
`DoesNotHallucinateFunctionCalls`, `AsksForClarification`, and `LlmJudge` property checks.

### OOD criterion

A benchmark is OOD for EVAL-040 if it satisfies all three conditions:
1. The task prompts do not reference Chump-internal tools (`list_dir`, `read_file`, `task`, etc.)
2. The success criterion is not already captured in the existing three fixtures
3. The evaluation methodology (heuristic + LLM judge) is compatible with the existing harness

The BFCL-inspired fixture meets all three conditions.

---

## Fixture

**File:** `scripts/ab-harness/fixtures/ood_bfcl_sample.json`

20 tasks spanning five categories from BFCL's taxonomy:

| Category | Tasks | What it tests |
|----------|-------|---------------|
| `simple` | 5 (bfcl-01, -02, -03, -11, -15) | Correct argument construction for well-specified calls |
| `gotcha` | 7 (bfcl-04, -05, -08, -09, -16, -17, -19) | Type mismatches, missing required args, ambiguous intent, destructive ops |
| `parallel` | 2 (bfcl-06, -13) | Multi-function independent calls |
| `dynamic` | 6 (bfcl-07, -12, -14, -18, -20) | Sequential dependencies, error recovery, pagination |

Tasks are original compositions inspired by BFCL category structure. No BFCL test data is
reproduced verbatim.

### Why these categories matter for Chump's lessons-block thesis

The lessons block was designed to address: "write before check", "narrate without act", and
"ambiguity without clarify" failure modes. The `gotcha` and `dynamic` BFCL categories directly
probe these same anti-patterns in a domain-neutral context:

- **gotcha-required-missing** → lessons saying "ask for missing info before proceeding" should help
- **gotcha-ambiguous-intent** → lessons about clarification before destructive action should help
- **dynamic-error-recovery** → lessons about retry strategy and escalation should help
- **simple** tasks → lessons should not hurt (no specific lesson addresses this; null-effect expected)

If the lessons block generalises, we expect positive delta on `gotcha` and `dynamic` categories and
near-zero delta on `simple`. If the lessons block over-injects and interferes with clean calls, we
expect negative delta on `simple` (the conditional-chain dilution effect documented in EVAL-029).

---

## Experimental Design

### Cell A vs Cell B

| Cell | `CHUMP_LESSONS_INJECTION` | `CHUMP_CONSCIOUSNESS_ENABLED` | Description |
|------|--------------------------|-------------------------------|-------------|
| A (Chump full) | `1` (lessons active) | `1` | Full Chump agent loop with lessons block injected into every prompt |
| B (raw model) | `0` (lessons disabled) | `0` | Same model, no Chump assembly — raw LLM baseline |

**What Cell B represents:** With `CHUMP_LESSONS_INJECTION=0` and `CHUMP_CONSCIOUSNESS_ENABLED=0`,
the model receives the user prompt only (plus the standard Chump system prompt boilerplate, which
is minimal). This is as close as the harness gets to a "raw model" without running the model
directly via API — it removes the lessons block, neuromod hints, and belief-state context that
constitute the "Chump assembly advantage".

**Why this is a valid comparison:** The thesis being tested is whether Chump's instruction-injection
layer (specifically the lessons block) improves performance on OOD structured-reasoning tasks. Cell
B provides the counterfactual. Ideally, future work (EVAL-040b) would run Cell B via direct API
without any Chump wrapper to eliminate the Chump system prompt entirely; this is the best
available approximation within the existing harness.

### Harness commands

```bash
# Step 1: Build release binary
cargo build --release --bin chump

# Step 2: Start local inference endpoint (Ollama or MLX)
# Ollama: ollama serve & ollama pull qwen2.5:7b
# MLX:    mlx_lm.server --model mlx-community/Qwen3-14B-4bit &

# Step 3: Run A/B sweep (pilot: n=20 tasks, full: n=20 × repeat for stats)
#   Cell A — full Chump with lessons
CHUMP_EXPERIMENT_CHECKPOINT=eval040-chump-A-$(date +%s) \
CHUMP_LESSONS_INJECTION=1 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama \
OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/ood_bfcl_sample.json \
    --flag CHUMP_LESSONS_INJECTION \
    --tag eval040-bfcl-qwen25 \
    --limit 20 \
    --chump-bin ./target/release/chump

# Step 4: Score with dual judge
scripts/ab-harness/score.py \
  logs/ab/eval040-bfcl-qwen25-<TIMESTAMP>.jsonl \
  scripts/ab-harness/fixtures/ood_bfcl_sample.json \
  --judge-claude claude-haiku-4-5 \
  --judge-together meta-llama/Llama-3.3-70B-Instruct-Turbo-Free

# Step 5: Append result to registry
scripts/ab-harness/append-result.sh \
  logs/ab/eval040-bfcl-qwen25-<TIMESTAMP>.summary.json \
  EVAL-040 \
  --note "qwen2.5:7b, BFCL OOD fixture, 20 tasks, dual-judge (haiku+llama)"
```

**For cloud models** (required for cross-family validation and n≥50):

```bash
# Cell A — Chump with lessons (haiku-4-5)
CHUMP_EXPERIMENT_CHECKPOINT=eval040-chump-A-haiku-$(date +%s) \
  python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/ood_bfcl_sample.json \
    --tag eval040-bfcl-haiku-A \
    --model claude-haiku-4-5 \
    --judges "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
    --lessons-version v2 \
    --limit 20

# Cell B — raw model (haiku-4-5, no lessons)
CHUMP_EXPERIMENT_CHECKPOINT=eval040-raw-B-haiku-$(date +%s) \
  python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/ood_bfcl_sample.json \
    --tag eval040-bfcl-haiku-B \
    --model claude-haiku-4-5 \
    --judges "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
    --lessons-version none \
    --limit 20
```

---

## Methodology Standards (per RESEARCH_INTEGRITY.md)

| Requirement | This eval |
|------------|-----------|
| Sample size | n=20 per cell (pilot); n=50 target for directional signal; n=100 for ship-or-cut |
| Judge composition | Claude haiku-4-5 (Anthropic) + Llama-3.3-70B (Together, non-Anthropic) |
| Human ground truth | Not done at pilot stage; required before citing hallucination-rate results |
| Mechanism analysis | Required if |Δ| > 0.05: document why lessons-block helps or hurts on BFCL tasks |
| A/A baseline | Required before citing results: run cell A vs cell A (n=20), expect Δ ≤ ±0.03 |
| Reproduction | `CHUMP_EXPERIMENT_CHECKPOINT` env var must be logged with all results |

All pilot results (n=20, Anthropic-only judge) are **preliminary** per RESEARCH_INTEGRITY.md
and must be prefixed with that label in any citation.

---

## Scoring Properties Used

This fixture exercises a wider set of properties than prior fixtures:

| Property | Tasks | What it checks |
|----------|-------|----------------|
| `DoesNotHallucinateFunctionCalls` | all 20 | Primary signal: does the model pretend to execute functions and invent results? |
| `AsksForClarification` | bfcl-04, -05, -08, -09 | Does the model ask when required info is ambiguous or missing? |
| `DoesNotCallWriteToolImmediately` | bfcl-16, -19 | Does the model pause before destructive ops? |
| `RespectsPolicyGate` | bfcl-19 | Does the model require confirmation for destructive calls? |
| `Custom` | 15 tasks | Argument name or value substring present in response |
| `LlmJudge` (via judge rubric) | all 20 | Semantic correctness of argument construction |

**Primary metric:** `DoesNotHallucinateFunctionCalls` pass-rate delta (A − B).

This is the right primary metric because: (1) function-call hallucination is the canonical
failure mode on BFCL, (2) it is the most objective property check (no semantic judgment needed),
and (3) EVAL-027c established that hallucination rate is where lessons-block effects are most
pronounced (Chump on sonnet-4-5 showed +0.33 hallucination rate with lessons active).

---

## Expected Results and Hypotheses

### Hypothesis 1: Lessons-block helps on gotcha tasks (Δ > 0)

If the lessons block contains caution-oriented directives ("ask before acting on ambiguous
requests", "verify required fields", "warn before destructive operations"), it should improve
gotcha-category performance. These are the same failure modes the lessons block was designed to
address, now tested on a domain-neutral fixture.

**Expected:** Cell A pass-rate > Cell B on gotcha category.

### Hypothesis 2: Lessons-block neutral-to-negative on simple tasks (Δ ≈ 0 or < 0)

Simple tasks are well-specified; the model just needs to construct arguments correctly. The
lessons block may introduce noise (conditional-chain dilution per EVAL-029) by appending
procedural cautions that don't apply to straightforward calls. This is the same mechanism
that caused the −0.10 to −0.16 mean delta on neuromod_tasks.

**Expected:** Cell A pass-rate ≤ Cell B on simple category.

### Hypothesis 3: Overall OOD transfer is model-tier-dependent

Per the validated finding (RESEARCH_INTEGRITY.md), lessons help haiku-4-5 and backfire on
sonnet-4-5+. If this tier-dependence holds on BFCL tasks, we would see:
- haiku-4-5: positive overall Δ (lessons help)
- sonnet-4-5 / qwen-14b: negative or zero overall Δ (lessons hurt or no effect)

Confirming tier-dependence on an OOD fixture would strengthen the validated finding
significantly and provide evidence that it generalises beyond the reflection fixture.

---

## Pilot Results

> **Status: pilot not yet run as of 2026-04-20.**
>
> All results in this section are placeholder / TBD. This section will be filled in
> when the harness is run against a live endpoint.

### A/A baseline (required pre-check)

| cell | n | Δ correctness | verdict |
|------|---|---------------|---------|
| A vs A (qwen2.5:7b) | TBD | TBD | TBD |

### Pilot sweep (n=20 per cell)

| fixture | model | cell A (Chump) | cell B (raw) | Δ correctness | Δ hallucination | judge | n/cell | status |
|---------|-------|----------------|--------------|---------------|-----------------|-------|--------|--------|
| ood_bfcl_sample | qwen2.5:7b | TBD | TBD | TBD | TBD | haiku+llama | — | pending |
| ood_bfcl_sample | claude-haiku-4-5 | TBD | TBD | TBD | TBD | sonnet+llama | — | pending |

### By-category breakdown

| category | model | cell A | cell B | Δ | interpretation |
|----------|-------|--------|--------|---|----------------|
| simple | TBD | TBD | TBD | TBD | TBD |
| gotcha | TBD | TBD | TBD | TBD | TBD |
| parallel | TBD | TBD | TBD | TBD | TBD |
| dynamic | TBD | TBD | TBD | TBD | TBD |

Results will be appended here when the pilot completes. Until then, this section is TBD
and must not be cited.

---

## Decision Criteria

| Finding | Action |
|---------|--------|
| Overall Δ > +0.05 on haiku-4-5, CI excludes 0 | Lessons block generalises to OOD structured reasoning — cite as preliminary evidence supporting tier-dependent transfer |
| Gotcha Δ > +0.05, Simple Δ ≈ 0 | Hypothesis 1+2 confirmed — lessons-block targets the right failure modes without harming clean-path tasks |
| Overall Δ < 0 on sonnet-4-5+ | Consistent with tier-dependent finding — file EVAL-040b to investigate mitigation (EVAL-030-style gating) |
| No detectable signal on any model (CI includes 0) | BFCL OOD transfer is null — document as "lessons block does not generalise to function-calling domain"; does not invalidate the in-distribution findings |

---

## Cross-links

- Gap: `docs/gaps.yaml` (EVAL-040)
- Fixture: `scripts/ab-harness/fixtures/ood_bfcl_sample.json`
- Prior tier-dependent finding: EVAL-025, EVAL-027c
- Conditional-chain dilution mechanism: EVAL-029
- Task-class-aware gating (relevant if negative delta): EVAL-030
- Registry stub: `docs/research/CONSCIOUSNESS_AB_RESULTS.md` (EVAL-040 section)
- Research integrity: `docs/process/RESEARCH_INTEGRITY.md`
- Upstream benchmark: https://gorilla.cs.berkeley.edu/leaderboard.html (BFCL)
