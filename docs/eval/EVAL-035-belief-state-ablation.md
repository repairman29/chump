# EVAL-035 — Belief-state ablation A/B

**Date created:** 2026-04-19
**Status:** Infrastructure shipped; sweep pending (disk full — ~117 MiB free as of 2026-04-19).
**Gap:** EVAL-035 (docs/gaps.yaml)
**Depends on:** EVAL-030 (task-class-aware neuromod gating — shipped)

---

## Research question

Does `belief_state.rs` (per-tool Beta reliability tracking + task-level
uncertainty) make a measurable positive contribution to agent task performance,
or is it noise-neutral / actively harmful?

Previously masked by the EVAL-029/030 neuromod harm signal. With EVAL-030
shipped, belief_state is now isolable.

---

## Hypothesis

**H1:** Belief-state context injection ("Belief state: Least certain: run_cli...")
steers the agent toward more reliable tools. Predicted: +2–8 pp on fixtures with
sequential tool calls and failure cascades.

**H0:** The summary adds cognitive load without grounding — agent already sees
tool errors directly. Risk of conditional-chain dilution per EVAL-029 mechanism.

---

## Methodology

### Experimental design

Two-cell A/B:

| Cell | Env | Description |
|------|-----|-------------|
| A (control) | `CHUMP_BYPASS_BELIEF_STATE=0` (default) | Belief state fully active |
| B (bypass) | `CHUMP_BYPASS_BELIEF_STATE=1` | All belief-state functions no-op |

**`CHUMP_BYPASS_BELIEF_STATE=1`** gates (added in this gap,
`crates/chump-belief-state/src/lib.rs`):
- `update_tool_belief` → no-op (no Bayesian update)
- `decay_turn` → no-op
- `nudge_trajectory` → no-op
- `context_summary` → `""` (no prompt injection)
- `should_escalate_epistemic` → always `false`

Hold constant in both cells: `CHUMP_CONSCIOUSNESS_ENABLED=1`,
`CHUMP_NEUROMOD_ENABLED=1`. Only belief_state is ablated.

### Fixtures

1. `warm_consciousness_tasks.json` — 3-fail + 2-succeed cascade; primary
2. `neuromod_tasks.json` — dynamic/adaptive/trivial; cross-fixture check
3. `reflection_tasks.json` — reflection fixture from EVAL-025; tertiary

### Sample size

n=50 per cell per fixture (n=300 total). n=100 per cell required for
ship-or-cut on Metacognition faculty graduation (RESEARCH_INTEGRITY.md §1).

### Models

- `qwen2.5:7b` (small tier, Ollama)
- `claude-haiku-4-5` (capable tier, Anthropic — requires ANTHROPIC_API_KEY)

### Judge composition (RESEARCH_INTEGRITY.md §2)

Dual-judge panel required:
- Anthropic: `claude-haiku-4-5`
- Non-Anthropic: `meta-llama/Llama-3.3-70B-Instruct-Turbo-Free` (Together free)

A/A baseline required: n=10 cell-A vs cell-A; delta must be within ±0.03
before citing results (RESEARCH_INTEGRITY.md §5).

---

## How to run

```bash
# Prerequisites
cargo build --release --bin chump
# Verify bypass wiring
CHUMP_BYPASS_BELIEF_STATE=1 ./target/release/chump --health 2>&1 | grep belief

# Cell A — belief_state active (control)
CHUMP_EXPERIMENT_CHECKPOINT=eval035-cell-A-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
CHUMP_NEUROMOD_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
    --flag BELIEF_STATE_ACTIVE \
    --tag eval035-cell-A-qwen25-7b \
    --limit 50 --chump-bin ./target/release/chump

# Cell B — belief_state bypassed
CHUMP_EXPERIMENT_CHECKPOINT=eval035-cell-B-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=1 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
CHUMP_NEUROMOD_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
    --flag BELIEF_STATE_BYPASSED \
    --tag eval035-cell-B-qwen25-7b \
    --limit 50 --chump-bin ./target/release/chump

# Score (dual-judge)
scripts/ab-harness/score.py logs/ab/eval035-cell-A-*.jsonl \
  scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
  --judge-claude claude-haiku-4-5 \
  --judge-together meta-llama/Llama-3.3-70B-Instruct-Turbo-Free

scripts/ab-harness/score.py logs/ab/eval035-cell-B-*.jsonl \
  scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
  --judge-claude claude-haiku-4-5 \
  --judge-together meta-llama/Llama-3.3-70B-Instruct-Turbo-Free
```

**Disk note:** Sweep requires ~2 GB free. Machine was at ~100% capacity
(117 MiB free) when this doc was written. Clear disk before running.

---

## Results

> **TBD** — sweep not run; disk full at time of infrastructure merge.

All results must be marked **preliminary (n < 100 or Anthropic-only judges)**
until they meet RESEARCH_INTEGRITY.md methodology standards.

Prohibited claim (RESEARCH_INTEGRITY.md): Do not write "belief_state improves
agent performance" until EVAL-035 + EVAL-043 both ship with n≥100, cross-family
judges, and A/A ±0.03.

### Results table

| fixture | model | cell A | cell B | delta | judge panel | n/cell | status |
|---------|-------|--------|--------|-------|-------------|--------|--------|
| warm_consciousness_tasks | qwen2.5:7b | TBD | TBD | TBD | TBD | TBD | pending |
| warm_consciousness_tasks | claude-haiku-4-5 | TBD | TBD | TBD | TBD | TBD | pending |
| neuromod_tasks | qwen2.5:7b | TBD | TBD | TBD | TBD | TBD | pending |
| reflection_tasks | qwen2.5:7b | TBD | TBD | TBD | TBD | TBD | pending |

### A/A variance baseline

| run | n | delta | verdict |
|-----|---|-------|---------|
| cell A vs cell A | TBD | TBD | TBD |

---

## Decision criteria

| Finding | Action |
|---------|--------|
| Cell A delta > +0.05 pp, consistent ≥2 fixtures and ≥2 models | Noise-neutral/positive → Metacognition faculty graduates (combined with EVAL-030) |
| Cell A delta within ±0.05 pp | Noise-neutral → same graduation, note low signal |
| Cell A delta < −0.05 pp consistent ≥2 fixtures | Decorative/negative → file followup to remove/redesign |
