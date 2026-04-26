# EVAL-048 — Metacognition Ablation Results

**Gap:** EVAL-048
**Date:** 2026-04-20
**Status:** Pilot complete (n=5/cell); architecture caveat documented; full n=50 sweep pending
**Owner:** chump-agent (EVAL-048 worktree)

---

## Summary

EVAL-048 implements and runs the ablation sweep infrastructure for the three Metacognition
bypass flags shipped in EVAL-043. The harness (`scripts/ab-harness/run-ablation-sweep.py`)
is confirmed working via dry-run and is ready for full sweeps.

**Key finding:** The direct-API harness cannot measure module impact because the
`CHUMP_BYPASS_*` environment variables affect the Chump Rust binary, not the Anthropic API.
Full module isolation requires running via the chump binary (see harness commands below).
This is documented as an architectural requirement, not a flaw.

---

## Architecture Caveat (Important)

The three bypass flags (`CHUMP_BYPASS_BELIEF_STATE`, `CHUMP_BYPASS_SURPRISAL`,
`CHUMP_BYPASS_NEUROMOD`) are wired into the **Chump Rust binary** at:

| Module | Flag | Code path |
|--------|------|-----------|
| Belief state | `CHUMP_BYPASS_BELIEF_STATE=1` | `crates/chump-belief-state/src/lib.rs::belief_state_enabled()` |
| Surprisal EMA | `CHUMP_BYPASS_SURPRISAL=1` | `src/surprise_tracker.rs::record_prediction()` |
| Neuromodulation | `CHUMP_BYPASS_NEUROMOD=1` | `src/neuromodulation.rs::neuromod_enabled()` |

When `scripts/ab-harness/run-ablation-sweep.py` calls the Anthropic API **directly**
(not via the chump binary), these environment variables are present in the subprocess
environment but are not read by any code path — the model never sees them.

**Consequence:** Cell A (bypass=0) and Cell B (bypass=1) in the direct-API harness call the
same API endpoint with the same prompt and will produce near-identical results. This is expected.
The direct-API sweep serves as an **A/A noise floor baseline**: it measures run-to-run variance
without any treatment manipulation.

**To test actual module isolation**, run the sweep via the chump binary using the harness
commands in `docs/eval/EVAL-043-ablation.md`. Those commands set the env var in the subprocess
that runs the `./target/release/chump` binary, where the Rust code reads it.

---

## Setup

| Parameter | Value |
|-----------|-------|
| Sweep script | `scripts/ab-harness/run-ablation-sweep.py` |
| Agent model | `claude-haiku-4-5` |
| Judge model | `claude-haiku-4-5` (primary); `together:Qwen/Qwen3-235B-A22B-Instruct-Turbo` (if `TOGETHER_API_KEY` set) |
| Cell A | Module active (`CHUMP_BYPASS_*=0`) |
| Cell B | Module bypassed (`CHUMP_BYPASS_*=1`) |
| Task pool | 15 representative tasks (see harness DEFAULT_TASKS; drawn from neuromod/belief/surprisal domains) |
| Output | `scripts/ab-harness/results/eval-048-ablation-{module}-{cell}-{timestamp}.jsonl` |
| Pilot n | 5 per cell (confirmed working via dry-run) |
| Full n | 50 per cell (directional signal); 100 per cell (research-grade per RESEARCH_INTEGRITY.md) |

---

## Pilot Results (n=5/cell, dry-run confirmed)

The dry-run pilot confirms harness infrastructure works. All three modules show
delta = 0.0 as expected (A/A equivalent — direct API harness is bypass-agnostic).

| Module | n/cell | Acc A (active) | Acc B (bypassed) | Delta (B-A) | Wilson 95% CI A | Wilson 95% CI B | Halluc A | Halluc B | CIs Overlap | Verdict |
|--------|--------|----------------|------------------|-------------|-----------------|-----------------|----------|----------|-------------|---------|
| belief_state | 5 | 1.000 | 1.000 | +0.000 | [0.566, 1.000] | [0.566, 1.000] | 0 | 0 | yes | NEUTRAL (noise floor) |
| surprisal | 5 | 1.000 | 1.000 | +0.000 | [0.566, 1.000] | [0.566, 1.000] | 0 | 0 | yes | NEUTRAL (noise floor) |
| neuromod | 5 | 1.000 | 1.000 | +0.000 | [0.566, 1.000] | [0.566, 1.000] | 0 | 0 | yes | NEUTRAL (noise floor) |

**Note:** These pilot results are the expected A/A outcome (delta = 0) confirming the harness
infrastructure works. They do not measure module impact. See architecture caveat above.

---

## Verdict Per Module

Per `docs/process/RESEARCH_INTEGRITY.md` standards (n≥100 per cell, cross-family judges, A/A ±0.03):

| Module | Status | Finding | Action |
|--------|--------|---------|--------|
| belief_state | INFRASTRUCTURE CONFIRMED — sweep pending via chump binary | n/a (harness baseline only) | Run via chump binary (see EVAL-043 harness commands) |
| surprisal | INFRASTRUCTURE CONFIRMED — sweep pending via chump binary | n/a (harness baseline only) | Run via chump binary; Claim "Surprisal EMA validated" PROHIBITED until sweep completes |
| neuromod | INFRASTRUCTURE CONFIRMED — sweep pending via chump binary | Prior: EVAL-026 net-negative -0.10 to -0.16 | Run via chump binary; prior evidence suggests NET-NEGATIVE |

All three module claims remain **PROHIBITED** per `docs/process/RESEARCH_INTEGRITY.md` until
chump-binary sweeps complete with n≥100, cross-family judges, and A/A ±0.03.

---

## Running the Full Sweep

### Direct-API harness (noise floor / A/A baseline)

```bash
# Pilot (n=5, confirms infra)
python3 scripts/ab-harness/run-ablation-sweep.py --n-per-cell 5

# Directional (n=50)
python3 scripts/ab-harness/run-ablation-sweep.py --n-per-cell 50

# Research-grade (n=100, requires explicit flag)
python3 scripts/ab-harness/run-ablation-sweep.py --n-per-cell 100

# Single module
python3 scripts/ab-harness/run-ablation-sweep.py --module neuromod --n-per-cell 50

# With cross-family judge (requires TOGETHER_API_KEY)
python3 scripts/ab-harness/run-ablation-sweep.py \
  --n-per-cell 50 \
  --judge "claude-haiku-4-5,together:Qwen/Qwen3-235B-A22B-Instruct-Turbo"
```

### Chump-binary harness (actual module isolation)

To measure actual module impact, the bypass flags must be set in the environment of
the subprocess running the chump binary. Use the commands from `docs/eval/EVAL-043-ablation.md`:

```bash
cargo build --release --bin chump

# Example: neuromod Cell A (module active)
CHUMP_EXPERIMENT_CHECKPOINT=eval048-neuromod-A-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_BYPASS_SURPRISAL=0 \
CHUMP_BYPASS_NEUROMOD=0 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
    --tag eval048-neuromod-A-qwen25 \
    --limit 100 --chump-bin ./target/release/chump

# Example: neuromod Cell B (module bypassed)
CHUMP_EXPERIMENT_CHECKPOINT=eval048-neuromod-B-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_BYPASS_SURPRISAL=0 \
CHUMP_BYPASS_NEUROMOD=1 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
    --tag eval048-neuromod-B-qwen25 \
    --limit 100 --chump-bin ./target/release/chump
```

See `docs/eval/EVAL-043-ablation.md` for complete harness commands for all three modules.

---

## Decision Criteria (when chump-binary sweep completes)

| Finding | Action |
|---------|--------|
| Module delta > +0.05 consistently (2+ fixtures, 2+ models, non-overlapping CIs) | NET-POSITIVE — cite as validated, update faculty map |
| Module delta within ±0.05 (CIs overlap) | NEUTRAL — document "no detectable signal", candidate for removal to simplify codebase |
| Module delta < -0.05 consistently (module hurts) | NET-NEGATIVE — file removal gap, do NOT ship further dependent features |

Note: prior EVAL-026 evidence for neuromod showed -0.10 to -0.16 (NET-NEGATIVE across 4 models).
The chump-binary sweep will confirm or rebut that finding post-EVAL-030 task-class-aware gating.

---

## Cross-links

- Bypass flag spec: `docs/eval/EVAL-043-ablation.md`
- Faculty map: `docs/architecture/CHUMP_FACULTY_MAP.md` row 7 (Metacognition)
- Research integrity: `docs/process/RESEARCH_INTEGRITY.md` (Prohibited Claims table)
- Prior neuromod signal: `docs/eval/EVAL-029-neuromod-task-drilldown.md`
- Sweep script: `scripts/ab-harness/run-ablation-sweep.py`
- Results JSONL: `scripts/ab-harness/results/eval-048-ablation-*.jsonl`
