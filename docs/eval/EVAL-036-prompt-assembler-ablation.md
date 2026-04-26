# EVAL-036 — Prompt-Assembler Ablation: Full Assembly vs Minimalist Baseline

**Gap:** EVAL-036
**Date filed:** 2026-04-19
**Status:** Design complete — sweep pending (see Infrastructure Gap section)
**Priority:** P3 (effort: s)
**Owner:** chump-agent (claude/eval-036 worktree)
**Depends on:** EVAL-032 (perception bypass), EVAL-043 (neuromod/surprisal/belief bypass)

---

## Research question

Does `src/agent_loop/prompt_assembler.rs` add measurable signal to agent task quality,
or is the full assembly overhead (lessons block + perception + belief state + surprisal +
neuromod) net noise compared to a bare system-prompt + user-prompt baseline?

Prior evals (EVAL-023 through EVAL-031) measured individual components. EVAL-036 is the
**full-bundle** ablation: does the *combination* of all Chump-added prompt context improve
the model's ability to do its job, or does the accumulated overhead dilute the task signal?

---

## Hypothesis

**H1 (assembly helps):** The assembled prompt steers the model toward safer, more
tool-reliable behavior by surfacing relevant prior-episode lessons, entity context, and
uncertainty cues. Predicted: +3–8 pp on `is_correct` relative to minimalist baseline,
with lower `hallucinated_tools` rate in Cell A.

**H0 (assembly is noise):** The model's base capability dominates; Chump-injected blocks
add token count without measurable benefit. The minimalist prompt is as good or better.
Evidence for H0 would be consistent with EVAL-025's finding that lessons backfire on
some model tiers (haiku-4-5 +0.14 pp hallucination under lessons injection).

**H2 (tier-dependent):** Assembly helps frontier-class models but hurts or is noise for
small/capable tiers. This would reproduce the COG-016/COG-023 tier-split finding at the
bundle level.

---

## Cell definitions

| Cell | Description | Env flags |
|------|-------------|-----------|
| **A — full assembly** | All Chump prompt components active: spawn lessons (MEM-006), task planner, COG-016 lessons, blackboard, perception summary, belief state, surprisal context, neuromod | All BYPASS flags unset (default) |
| **B — minimalist** | System prompt = base system prompt only (or None). No Chump-injected blocks. | `CHUMP_BYPASS_PERCEPTION=1` + `CHUMP_BYPASS_BELIEF_STATE=1` + `CHUMP_BYPASS_SURPRISAL=1` + `CHUMP_BYPASS_NEUROMOD=1` + `CHUMP_REFLECTION_INJECTION=0` + `CHUMP_LESSONS_AT_SPAWN_N=0` |

### What "minimalist" means precisely

Cell B suppresses every prompt block that `prompt_assembler.rs` adds beyond the
`base_system_prompt`:

1. **Spawn lessons** (MEM-006): `CHUMP_LESSONS_AT_SPAWN_N=0` → spawn block is skipped
2. **COG-016 per-iteration lessons**: `CHUMP_REFLECTION_INJECTION=0` → lessons gate returns false
3. **Task planner block**: no bypass flag exists yet (EVAL-036 infrastructure gap, see below)
4. **Blackboard entity prefetch**: no bypass flag exists yet (EVAL-036 infrastructure gap)
5. **Perception summary**: `CHUMP_BYPASS_PERCEPTION=1` (EVAL-032)
6. **Surprisal EMA context**: `CHUMP_BYPASS_SURPRISAL=1` (EVAL-043)
7. **Neuromod modulators**: `CHUMP_BYPASS_NEUROMOD=1` (EVAL-043)
8. **Belief state summary**: `CHUMP_BYPASS_BELIEF_STATE=1` (EVAL-035)

The minimalist cell result should be statistically indistinguishable from running the model
directly against the fixture with only its base system prompt — which is what the
`run-cloud-v2.py` harness already does in cell B (no-lessons).

---

## Fixture selection

### Primary: `reflection_tasks.json` (n=50 subset)

Rationale: reflection tasks exercise tool-use, ambiguity handling, and policy gates — all
three areas where Chump lessons blocks have shown measurable signal in prior evals
(EVAL-023 through EVAL-027). The 100-task fixture is the established reference fixture;
using the first 50 by ordering gives us a fair sample while keeping cost reasonable.

```bash
# Preview: how many tasks in the fixture?
python3 -c "import json; d=json.load(open('scripts/ab-harness/fixtures/reflection_tasks.json')); print(len(d['tasks']), 'tasks')"
```

### Secondary: `warm_consciousness_tasks.json` (n=50 subset)

Rationale: designed for tool-cascade scenarios where belief state and surprisal context
should matter most. If assembly helps anywhere, it should be here.

### A/A calibration: `reflection_tasks.json` (n=20, cell-A vs cell-A)

Required by RESEARCH_INTEGRITY.md §5 before citing any delta. Must show noise floor
≤ ±0.03 before results are non-preliminary.

---

## Infrastructure gap: harness mismatch

**Critical finding:** The `run-cloud-v2.py` harness cannot run this experiment as-is.

The harness constructs the system prompt directly in Python as a static string (`LESSONS_BLOCK`
constant). It does **not** dispatch through `src/agent_loop/prompt_assembler.rs`. This means:

- Cell A ("full assembly") cannot be reproduced by the Python harness — the harness never
  calls `PromptAssembler::assemble()`, so task-planner blocks, entity prefetch, belief-state
  summaries, and neuromod context are never injected.
- Cell B ("minimalist") is exactly what the harness already does with `--mode ab` cell B
  (`system=None`), so that cell runs correctly today.

The same limitation was identified for EVAL-030 and documented in
`docs/research/CONSCIOUSNESS_AB_RESULTS.md` line 1483–1488 as "EVAL-030-VALIDATE".

**Three paths to execute EVAL-036:**

### Path 1 (recommended — low effort): Cloud harness approximation

Use the existing `run-cloud-v2.py` with:
- Cell A: full lessons block with `--lessons-version cog016` + perception context injected manually
- Cell B: `--mode ab` cell B (no system prompt, bare model)

This approximates but does not replicate the Rust assembly path. Valid for measuring
the **lessons block + perception** contribution as a bundle. Does not capture task-planner,
blackboard, or real-time belief state.

**Harness command (can be run today with API keys in `.env`):**

```bash
cd /Users/jeffadkins/Projects/Chump

# A/A calibration first (n=20, measure noise floor)
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag eval036-aa-calibration \
    --mode aa \
    --lessons-version cog016 \
    --model claude-haiku-4-5 \
    --judges claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 20

# Cell A vs Cell B (n=50)
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag eval036-ab-reflection-haiku45 \
    --mode ab \
    --lessons-version cog016 \
    --model claude-haiku-4-5 \
    --judges claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50

# Secondary fixture
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
    --tag eval036-ab-warm-haiku45 \
    --mode ab \
    --lessons-version cog016 \
    --model claude-haiku-4-5 \
    --judges claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50
```

**Estimated cost:** ~$2–4 USD (haiku-4-5 agent + sonnet-4-5 judge, n=100+20 trials × 2 cells).
**Prerequisites:** `ANTHROPIC_API_KEY` and `TOGETHER_API_KEY` in `.env` (both present as of
2026-04-19).

### Path 2 (exact — medium effort): Extend run-cloud-v2.py

Add a `--cell-a-mode assembler` flag that calls a thin Python wrapper around the Chump binary
to assemble the system prompt for each trial, then pass the assembled prompt to the Anthropic
API. Requires: (a) a `chump --assemble-prompt <fixture-task-json>` subcommand, or (b) piping
the task prompt through a minimal invocation that returns just the assembled system string.

Filed as infrastructure work in `docs/gaps.yaml` under EVAL-036 or a new `EVAL-036b` gap.

### Path 3 (exact — high effort): Rust-native harness

Port the Python harness logic into a Rust integration test or binary that calls
`PromptAssembler::assemble()` directly and then posts to the Anthropic API. Preserves all
assembly fidelity but requires significant scope expansion.

---

## Scoring

Following RESEARCH_INTEGRITY.md §2 methodology standards:

| Axis | Measurement |
|------|-------------|
| Primary | `is_correct` (binary task pass rate, judge-scored) |
| Secondary | `hallucinated_tools` (rate of fake tool-call emission) |
| Tertiary | `did_attempt` (engagement rate) |
| Latency | `agent_duration_ms` (assembly overhead cost signal) |

**Judge panel (required):**
- Anthropic judge: `claude-sonnet-4-5`
- Non-Anthropic judge: `together:meta-llama/Llama-3.3-70B-Instruct-Turbo`
- Verdict: median of both judges per trial

**Sample size:** n=50 per cell (minimum for preliminary findings). n=100 per cell required
for ship-or-cut decisions per RESEARCH_INTEGRITY.md §1.

**A/A noise floor:** Must be within ±0.03 before any delta is cited as a finding.

---

## Expected sample sizes and cost estimate

| Run | Fixture | n/cell | Model | Approx. cost |
|-----|---------|--------|-------|-------------|
| A/A calibration | reflection_tasks | 20 | haiku-4-5 + sonnet judge | ~$0.50 |
| Cell A vs B | reflection_tasks | 50 | haiku-4-5 + sonnet + llama judges | ~$2.00 |
| Cell A vs B | warm_consciousness | 50 | haiku-4-5 + sonnet + llama judges | ~$2.00 |
| **Total** | | | | **~$4.50** |

Extend to n=100 per cell if A/A noise floor > 0.05 (requires re-run at ~$9 total).

---

## Decision criteria

| Finding | Action |
|---------|--------|
| Cell A delta ≥ +0.05 pp `is_correct`, consistent ≥2 fixtures, CIs non-overlapping | Assembly is net-positive → ship as default, no architecture change |
| Delta within ±0.05 pp or CIs overlapping | Assembly is noise → file gap to audit each block cost vs benefit individually (EVAL-043 per-module ablation is the right vehicle) |
| Cell A delta ≤ −0.05 pp `is_correct` OR cell A `hallucinated_tools` > cell B | Assembly is net-negative → file architectural review gap; flag individual modules for removal |
| Cell A `hallucinated_tools` rate > 0.15 | Reproduce EVAL-025 haiku-4-5 hallucination harm → apply COG-023 tier gate (block assembly on haiku tier) |

---

## Connection to EVAL-043 ablation suite

EVAL-043 ablates each module independently (surprisal, belief state, neuromod). EVAL-036
is the **whole-bundle** test. The relationship:

- If EVAL-036 shows net-positive: each module may still be individually noise (EVAL-043 needed)
- If EVAL-036 shows noise/negative: EVAL-043 can identify which module(s) to cut
- EVAL-036 result + EVAL-043 results together compose a full module-attribution picture

EVAL-036 should be cited together with EVAL-043 in any architectural decision about the
`prompt_assembler.rs` assembly pipeline.

---

## Cross-links

- Gap: `docs/gaps.yaml` (EVAL-036)
- Results section: `docs/research/CONSCIOUSNESS_AB_RESULTS.md` section "EVAL-036"
- Bypass flags: `src/env_flags.rs` — `CHUMP_BYPASS_PERCEPTION`, `CHUMP_BYPASS_BELIEF_STATE`,
  `CHUMP_BYPASS_SURPRISAL`, `CHUMP_BYPASS_NEUROMOD`
- Lessons gate: `src/reflection_db.rs::reflection_injection_enabled()`
- Assembly code: `src/agent_loop/prompt_assembler.rs`
- EVAL-032 (perception only): `docs/eval/EVAL-032-perception-ablation.md`
- EVAL-035 (belief state): `docs/eval/EVAL-035-belief-state-ablation.md`
- EVAL-043 (per-module): `docs/eval/EVAL-043-ablation.md`
- Prior harness mismatch note: `docs/research/CONSCIOUSNESS_AB_RESULTS.md` lines 1479–1488
