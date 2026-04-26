# EVAL-043 — Ablation Suite: belief_state, surprisal EMA, neuromod each in isolation

**Gap:** EVAL-043
**Date filed:** 2026-04-19
**Status:** Infrastructure shipped — sweeps run via EVAL-048 (2026-04-20); direct-API noise floor confirmed; chump-binary isolation sweeps pending
**Owner:** chump-agent (EVAL-043 worktree)
**Priority:** P1 — required before any cognitive-architecture claims can be made

**EVAL-048 update (2026-04-20):** `scripts/ab-harness/run-ablation-sweep.py` implemented and
confirmed working via dry-run. Architecture caveat documented: bypass flags affect the chump
Rust binary only, not direct API calls. The direct-API harness establishes a noise floor
(A/A equivalent); actual module isolation requires running via the chump binary using the
harness commands below. See `docs/eval/EVAL-048-ablation-results.md` for full results and
methodology.

---

## Purpose

This gap implements independent A/B ablation cells for each of the three cognitive-architecture
modules that have not yet been individually validated:

1. **Belief state** (`crates/chump-belief-state`) — per-tool Beta reliability tracking + task-level uncertainty
2. **Surprisal EMA** (`src/surprise_tracker.rs`) — prediction-error exponential moving average
3. **Neuromodulation** (`src/neuromodulation.rs`) — dopamine/noradrenaline/serotonin proxy modulators

Per `docs/process/RESEARCH_INTEGRITY.md`: all three claims ("Surprisal EMA is a validated contribution",
"Belief state improves agent performance", "Chump's cognitive architecture is validated") are
**prohibited** until this gap ships with n≥100 per cell, cross-family judges, and A/A baselines
within ±0.03.

---

## Bypass flags implemented

| Component | Flag | Where wired |
|-----------|------|-------------|
| Belief state | `CHUMP_BYPASS_BELIEF_STATE=1` | `crates/chump-belief-state/src/lib.rs::belief_state_enabled()` (shipped in EVAL-035 infra) |
| Surprisal EMA | `CHUMP_BYPASS_SURPRISAL=1` | `src/surprise_tracker.rs::record_prediction()` (EVAL-043) |
| Neuromodulation | `CHUMP_BYPASS_NEUROMOD=1` | `src/neuromodulation.rs::neuromod_enabled()` (EVAL-043, alias for `CHUMP_NEUROMOD_ENABLED=0`) |

All three flags are also registered in `src/env_flags.rs` with tests following the
`CHUMP_BYPASS_PERCEPTION` pattern established by EVAL-032.

### What each bypass does

**`CHUMP_BYPASS_BELIEF_STATE=1`:**
- `update_tool_belief` → no-op (no Bayesian update)
- `decay_turn` → no-op
- `nudge_trajectory` → no-op
- `context_summary` → `""` (no belief-state block injected into system prompt)
- `should_escalate_epistemic` → always `false`

**`CHUMP_BYPASS_SURPRISAL=1`:**
- `record_prediction` → early return (no EMA update, no Welford variance, no blackboard post)
- `current_surprisal_ema()` returns `0.0` (initial value, "fully predictable" baseline)
- Downstream: `neuromodulation::reward_scaling()` receives EMA=0 → dopamine scaling unchanged

**`CHUMP_BYPASS_NEUROMOD=1`:**
- Equivalent to `CHUMP_NEUROMOD_ENABLED=0` (COG-006 legacy gate also still works)
- `update_from_turn` → no-op (modulators stay at 1.0/1.0/1.0 baseline forever)
- All downstream consumers (`modulated_exploit_threshold`, `tool_budget_multiplier`,
  `effective_tool_timeout_secs`, `adaptive_temperature`, `salience_modulation`) return
  their unmodulated baseline values

---

## Cell A/B: Belief state isolation

### Experimental design

| Cell | `CHUMP_BYPASS_BELIEF_STATE` | `CHUMP_BYPASS_SURPRISAL` | `CHUMP_BYPASS_NEUROMOD` | Description |
|------|-----------------------------|--------------------------|--------------------------|-------------|
| A (control) | `0` (default) | `0` | `0` | Belief state active; all other modules active |
| B (ablation) | `1` | `0` | `0` | Belief state bypassed; surprisal + neuromod unchanged |

Hold constant: `CHUMP_CONSCIOUSNESS_ENABLED=1`, `CHUMP_NEUROMOD_ENABLED=1`.

### Harness commands

```bash
cargo build --release --bin chump

# Cell A — belief_state active
CHUMP_EXPERIMENT_CHECKPOINT=eval043-belief-A-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_BYPASS_SURPRISAL=0 \
CHUMP_BYPASS_NEUROMOD=0 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
    --tag eval043-belief-A-qwen25 \
    --limit 100 --chump-bin ./target/release/chump

# Cell B — belief_state bypassed
CHUMP_EXPERIMENT_CHECKPOINT=eval043-belief-B-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=1 \
CHUMP_BYPASS_SURPRISAL=0 \
CHUMP_BYPASS_NEUROMOD=0 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
    --tag eval043-belief-B-qwen25 \
    --limit 100 --chump-bin ./target/release/chump

# Score (dual-judge)
scripts/ab-harness/score.py logs/ab/eval043-belief-A-*.jsonl \
  scripts/ab-harness/fixtures/warm_consciousness_tasks.json \
  --judge-claude claude-haiku-4-5 \
  --judge-together meta-llama/Llama-3.3-70B-Instruct-Turbo-Free
```

### Results

> **EVAL-048 status (2026-04-20):** Direct-API harness infrastructure confirmed working via dry-run.
> Delta = 0.0 for all cells (expected: bypass flags affect chump binary only, not direct API).
> Full module-isolation sweep via chump binary pending.
> See `docs/eval/EVAL-048-ablation-results.md` for noise-floor results and methodology.

| fixture | model | cell A (belief on) | cell B (belief off) | Δ correctness | Δ hallucination | Wilson 95% CI | inter-judge | n/cell | status |
|---------|-------|--------------------|---------------------|---------------|-----------------|---------------|-------------|--------|--------|
| warm_consciousness_tasks | qwen2.5:7b | TBD | TBD | TBD | TBD | TBD | TBD | — | pending (chump binary) |
| warm_consciousness_tasks | claude-haiku-4-5 | TBD | TBD | TBD | TBD | TBD | TBD | — | pending (chump binary) |

**Removal candidate flag:** If Δ < 0 or CI includes 0 on both fixtures and both models → belief_state flagged for removal.

---

## Cell A/B: Surprisal EMA isolation

### Experimental design

| Cell | `CHUMP_BYPASS_BELIEF_STATE` | `CHUMP_BYPASS_SURPRISAL` | `CHUMP_BYPASS_NEUROMOD` | Description |
|------|-----------------------------|--------------------------|--------------------------|-------------|
| A (control) | `0` | `0` (default) | `0` | Surprisal EMA active; all other modules active |
| B (ablation) | `0` | `1` | `0` | Surprisal EMA bypassed; belief_state + neuromod unchanged |

Note: neuromod uses EMA in `update_from_turn` (via `surprise_tracker::current_surprisal_ema()`).
With BYPASS_SURPRISAL=1, the EMA is frozen at 0.0 — neuromod sees "always fully predictable"
environment. This is the intended isolation: surprisal feeds neuromod, so bypassing surprisal
tests the full surprisal→neuromod→behavior chain minus just surprisal input.

### Harness commands

```bash
# Cell A — surprisal EMA active
CHUMP_EXPERIMENT_CHECKPOINT=eval043-surprisal-A-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_BYPASS_SURPRISAL=0 \
CHUMP_BYPASS_NEUROMOD=0 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
    --tag eval043-surprisal-A-qwen25 \
    --limit 100 --chump-bin ./target/release/chump

# Cell B — surprisal EMA bypassed
CHUMP_EXPERIMENT_CHECKPOINT=eval043-surprisal-B-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_BYPASS_SURPRISAL=1 \
CHUMP_BYPASS_NEUROMOD=0 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
    --tag eval043-surprisal-B-qwen25 \
    --limit 100 --chump-bin ./target/release/chump
```

### Results

> **EVAL-048 status (2026-04-20):** Direct-API harness infrastructure confirmed working via dry-run.
> Delta = 0.0 for all cells (expected: bypass flags affect chump binary only, not direct API).
> Full module-isolation sweep via chump binary pending.
> See `docs/eval/EVAL-048-ablation-results.md` for noise-floor results and methodology.

Per `docs/process/RESEARCH_INTEGRITY.md`: "Surprisal EMA is a validated contribution" is PROHIBITED
until this sweep completes with n≥100, cross-family judges, and A/A ±0.03.

| fixture | model | cell A (surprisal on) | cell B (surprisal off) | Δ correctness | Δ hallucination | Wilson 95% CI | inter-judge | n/cell | status |
|---------|-------|-----------------------|------------------------|---------------|-----------------|---------------|-------------|--------|--------|
| neuromod_tasks | qwen2.5:7b | TBD | TBD | TBD | TBD | TBD | TBD | — | pending (chump binary) |
| warm_consciousness_tasks | qwen2.5:7b | TBD | TBD | TBD | TBD | TBD | TBD | — | pending (chump binary) |

**Removal candidate flag:** If Δ < 0 or CI includes 0 on both fixtures → surprisal EMA flagged for removal/redesign.

---

## Cell A/B: Neuromodulation isolation

### Experimental design

| Cell | `CHUMP_BYPASS_BELIEF_STATE` | `CHUMP_BYPASS_SURPRISAL` | `CHUMP_BYPASS_NEUROMOD` | Description |
|------|-----------------------------|--------------------------|--------------------------|-------------|
| A (control) | `0` | `0` | `0` (default) | Neuromod active; all other modules active |
| B (ablation) | `0` | `0` | `1` | Neuromod bypassed; belief_state + surprisal unchanged |

Prior evidence: EVAL-029 showed −0.10 to −0.16 mean delta across four models for neuromod
(net-negative cross-architecture signal). EVAL-030 shipped task-class-aware gating but was not
cross-validated. This cell re-tests neuromod post-EVAL-030.

### Harness commands

```bash
# Cell A — neuromod active
CHUMP_EXPERIMENT_CHECKPOINT=eval043-neuromod-A-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_BYPASS_SURPRISAL=0 \
CHUMP_BYPASS_NEUROMOD=0 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
    --tag eval043-neuromod-A-qwen25 \
    --limit 100 --chump-bin ./target/release/chump

# Cell B — neuromod bypassed
CHUMP_EXPERIMENT_CHECKPOINT=eval043-neuromod-B-$(date +%s) \
CHUMP_BYPASS_BELIEF_STATE=0 \
CHUMP_BYPASS_SURPRISAL=0 \
CHUMP_BYPASS_NEUROMOD=1 \
CHUMP_CONSCIOUSNESS_ENABLED=1 \
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
    --tag eval043-neuromod-B-qwen25 \
    --limit 100 --chump-bin ./target/release/chump
```

### Results

> **EVAL-048 status (2026-04-20):** Direct-API harness infrastructure confirmed working via dry-run.
> Delta = 0.0 for all cells (expected: bypass flags affect chump binary only, not direct API).
> Full module-isolation sweep via chump binary pending.
> See `docs/eval/EVAL-048-ablation-results.md` for noise-floor results and methodology.

| fixture | model | cell A (neuromod on) | cell B (neuromod off) | Δ correctness | Δ hallucination | Wilson 95% CI | inter-judge | n/cell | status |
|---------|-------|-----------------------|-----------------------|---------------|-----------------|---------------|-------------|--------|--------|
| neuromod_tasks | qwen2.5:7b | TBD | TBD | TBD | TBD | TBD | TBD | — | pending (chump binary) |
| neuromod_tasks | claude-haiku-4-5 | TBD | TBD | TBD | TBD | TBD | TBD | — | pending (chump binary) |

**Removal candidate flag:** If Δ < 0 (neuromod hurts) or CI includes 0 consistently → neuromod
flagged as removal candidate. EVAL-029 prior evidence suggests net-negative; this sweep
confirms or rebuts that finding post-EVAL-030 gating.

---

## Scoring methodology

Per `docs/process/RESEARCH_INTEGRITY.md`:

- **Sample size:** n=100 per cell for ship-or-cut decisions (n=50 for directional signal only)
- **Judge panel:** `claude-haiku-4-5` (Anthropic) + `meta-llama/Llama-3.3-70B-Instruct-Turbo-Free`
  (Together, non-Anthropic) — median verdict; Anthropic-only judging is insufficient
- **Axes:** `chump_hallucinated_tools` (hallucination rate) + `is_correct` (binary pass-rate)
- **Wilson 95% CI:** report lower and upper bound; if CI includes 0 → no signal detected
- **Inter-judge agreement:** Cohen's kappa or simple agreement rate; target ≥ 0.70
- **A/A baseline:** run cell A vs cell A (n=20) before citing results; delta must be ≤ ±0.03
- **Mechanism analysis:** if |Δ| > 0.05, document a hypothesis per EVAL-029 pattern

### A/A baseline (required before citing any result)

| run | n | delta | verdict |
|-----|---|-------|---------|
| belief-A vs belief-A | TBD | TBD | TBD |
| surprisal-A vs surprisal-A | TBD | TBD | TBD |
| neuromod-A vs neuromod-A | TBD | TBD | TBD |

---

## Decision criteria

| Finding | Action |
|---------|--------|
| Component Δ > +0.05 consistently across ≥2 fixtures and models | Net-positive → Metacognition faculty can cite component as validated |
| Component Δ within ±0.05 (CI includes 0) | Noise-neutral → document as "no detectable signal", candidate for removal |
| Component Δ < −0.05 consistently | Net-negative → file removal gap; do NOT ship further features dependent on this component |

---

## Estimated cost

| Sweep | Runs | Cost estimate |
|-------|------|---------------|
| Belief state A/B (n=100 × 2 cells × 2 models) | 400 | ~$4 |
| Surprisal EMA A/B (n=100 × 2 cells × 2 models) | 400 | ~$4 |
| Neuromod A/B (n=100 × 2 cells × 2 models) | 400 | ~$4 |
| A/A baselines (n=20 × 3 cells) | 60 | ~$1 |
| **Total** | | **~$13 cloud** |

---

## Binary-mode harness (EVAL-049)

> **IMPORTANT:** The bypass flags described in this document only fire when
> the chump **binary** is invoked as a subprocess. Direct API harnesses
> (`run-cloud-v2.py`, `run-ablation-sweep.py`) never execute the Rust binary
> and therefore **do not activate any bypass flag**. EVAL-048 documented this
> architectural caveat.

To measure real module impact, use the binary-mode harness:

```bash
cargo build --release --bin chump
python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 30
```

The script (`scripts/ab-harness/run-binary-ablation.py`) invokes
`./target/release/chump --chump "<task>"` in a subprocess with
`CHUMP_BYPASS_<MODULE>=1` set in the Cell B environment, isolating each
module independently.

Use `--dry-run` to verify the subprocess commands are correct without
requiring a built binary or API keys:

```bash
python3 scripts/ab-harness/run-binary-ablation.py --dry-run
```

Full methodology and results (pending n=30 sweep):
`docs/eval/EVAL-049-binary-ablation.md`

---

## Cross-links

- Gap filed: `docs/gaps.yaml` (EVAL-043)
- **EVAL-048 sweep results:** `docs/eval/EVAL-048-ablation-results.md` — noise floor confirmed, chump-binary sweeps pending
- **EVAL-048 sweep script:** `scripts/ab-harness/run-ablation-sweep.py`
- Faculty map: `docs/architecture/CHUMP_FACULTY_MAP.md` row 7 (Metacognition)
- Research integrity: `docs/process/RESEARCH_INTEGRITY.md` (Prohibited Claims table)
- Binary-mode harness: `docs/eval/EVAL-049-binary-ablation.md` (EVAL-049)
- Architectural caveat (why binary mode is necessary): `docs/eval/EVAL-048-ablation-results.md`
- Prior neuromod drilldown: `docs/eval/EVAL-029-neuromod-task-drilldown.md`
- Belief state infra: `docs/eval/EVAL-035-belief-state-ablation.md`
- Perception ablation pattern: `docs/eval/EVAL-032-perception-ablation.md`
- Implementation:
  - `src/env_flags.rs` — `chump_bypass_surprisal()`, `chump_bypass_neuromod()` (EVAL-043)
  - `src/surprise_tracker.rs::record_prediction` — EVAL-043 bypass gate
  - `src/neuromodulation.rs::neuromod_enabled` — EVAL-043 bypass alias
  - `crates/chump-belief-state/src/lib.rs::belief_state_enabled` — EVAL-035 bypass (pre-existing)
