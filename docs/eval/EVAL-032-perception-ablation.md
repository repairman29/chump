# EVAL-032 — Perception Layer Ablation A/B

**Gap:** EVAL-032
**Date filed:** 2026-04-19
**Status:** Flag implemented — sweep pending
**Owner:** chump-agent (claude/docs-sweep-pass4 worktree)

---

## Purpose

Isolate the contribution of the `chump-perception` layer to agent task quality.
The perception layer runs on every inbound turn and injects a structured
`[Perception] Task: … | Entities: … | Constraints: … | Risk: …` block into the
system prompt (via `src/agent_loop/prompt_assembler.rs`).  It has never been
ablated: we do not know whether it helps, hurts, or is noise for the agent models
we currently run.

**Research question:** Does injecting the perception summary improve or degrade
task correctness and hallucination rate, net of all other prompt blocks?

---

## Experimental design

### Cells

| Cell | `CHUMP_BYPASS_PERCEPTION` | Description |
|------|:---:|---|
| A — perception active | unset / `0` | Normal operation: perception summary injected when non-trivial |
| B — perception bypassed | `1` | Ablation: perception block suppressed; all other blocks unchanged |

### Harness command (reproducible)

```bash
# Cell A: perception ON (default)
CHUMP_BYPASS_PERCEPTION=0 \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/perception_tasks.json \
    --flag EVAL_032_CELL \
    --tag eval-032-perception-on \
    --limit 100 \
    --chump-bin ./target/release/chump

# Cell B: perception OFF (ablation)
CHUMP_BYPASS_PERCEPTION=1 \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/perception_tasks.json \
    --flag EVAL_032_CELL \
    --tag eval-032-perception-off \
    --limit 100 \
    --chump-bin ./target/release/chump
```

Or as a single A/B job using the existing `run-ablation-study.sh` idiom:

```bash
CHUMP_BYPASS_PERCEPTION=0 scripts/ab-harness/run.sh \
  --fixture scripts/ab-harness/fixtures/perception_tasks.json \
  --tag eval-032-A --limit 100 --chump-bin ./target/release/chump

CHUMP_BYPASS_PERCEPTION=1 scripts/ab-harness/run.sh \
  --fixture scripts/ab-harness/fixtures/perception_tasks.json \
  --tag eval-032-B --limit 100 --chump-bin ./target/release/chump
```

### Scoring

- Primary axis: `chump_hallucinated_tools` (hallucination rate, A/B delta with Wilson 95% CIs)
- Secondary axis: `is_correct` (binary task pass-rate)
- Judge panel: `claude-sonnet-4-5` + `meta-llama/Llama-3.3-70B-Instruct-Turbo` (median verdict) — required by RESEARCH_INTEGRITY.md methodology standards
- A/A control: run cell A vs cell A on a subset (n=30) to calibrate noise floor before citing results

### Sample size target

n=100 per cell (minimum for ship-or-cut decisions per `docs/process/RESEARCH_INTEGRITY.md`).

### Estimated cost

~$3 cloud at n=100 per cell with claude-haiku-4-5 as the agent under test.

---

## Implementation notes

### Flag location

`CHUMP_BYPASS_PERCEPTION` is implemented in:

- `src/env_flags.rs` — `chump_bypass_perception()` function with tests
- `src/agent_loop/prompt_assembler.rs` — gate wraps the `context_summary` injection block

When `CHUMP_BYPASS_PERCEPTION=1`, the assembler skips calling `crate::perception::context_summary`
and does not append the `[Perception]` block to the effective system prompt.  All other
blocks (spawn lessons, task planner, COG-016 lessons, blackboard) are unaffected.

### What the perception layer does (for context)

`crates/chump-perception/src/lib.rs` — pure rule-based extraction, no LLM calls:

- Classifies task type (Action / Question / Planning / Research / Meta / Unclear)
- Extracts quoted strings, capitalized nouns, and file paths as entities
- Detects constraint keywords (must/cannot/never/always/only/…)
- Detects risk indicators (delete/drop/production/sudo/…)
- Scores ambiguity (0.0–1.0)

`context_summary()` returns empty string for Unclear+no entities+no risk inputs, so the
perception block is already suppressed for trivial chat turns.  The ablation flag disables
it for *all* inputs including structured, entity-rich, risky ones — isolating the
contribution of the non-trivial summaries.

---

## Results

**Status: pending sweep — no numbers yet.**

Results will be recorded here after the sweep runs.  Per `docs/process/RESEARCH_INTEGRITY.md`,
all numbers must be marked "preliminary" until:
- n ≥ 100 per cell
- Non-Anthropic judge in the panel
- A/A control run to calibrate noise floor

### Correctness delta (A vs B)

TBD — sweep pending.

### Hallucination delta (A vs B)

TBD — sweep pending.

### Verdict

TBD — will be one of: "perception is net-positive", "perception is net-negative", "perception is noise".

---

## Cross-links

- Gap filed: `docs/gaps.yaml` (EVAL-032)
- Faculty map: `docs/architecture/CHUMP_FACULTY_MAP.md` row 1 (Perception)
- Results doc: `docs/research/CONSCIOUSNESS_AB_RESULTS.md` section "EVAL-032"
- Implementation: `src/env_flags.rs::chump_bypass_perception`, `src/agent_loop/prompt_assembler.rs`
- Prior neuromod ablation pattern: `docs/eval/EVAL-029-neuromod-task-drilldown.md`
