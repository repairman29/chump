# Preregistration — RESEARCH-024

> **Status:** LOCKED.

## 1. Gap reference

- **Gap ID:** RESEARCH-024
- **Gap title:** Multi-turn degradation curve run — ship the EVAL-044 fixture against belief_state on/off × haiku/sonnet
- **Source critique:** [`docs/research/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md) §7
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21

## 2. Hypothesis

**H1 (primary).** `belief_state` module reduces late-turn accuracy decay
on the EVAL-044 10-turn debug fixture. Formally: between turn 5 and turn
10, the slope of accuracy-vs-turn is less negative in Cell A (belief_state
ON) than Cell B (belief_state OFF). Operationalized: `slope_A > slope_B`
with bootstrap 95% CI excluding zero on the difference.

**H0.** Slopes equivalent (CI overlaps zero) — belief_state does not
improve late-turn accuracy.

**Tier-conditional secondary H1b.** The belief_state benefit is larger on
sonnet-4-5 than on haiku-4-5 (per the tier-dependent injection pattern
— frontier models may benefit from state-injection *more* in multi-turn
than small models do). This is the novel finding Paper 3 would lead with.

## 3. Design

### Cells

| Cell | belief_state | Agent |
|---|---|---|
| A1 | ON | claude-haiku-4-5 |
| A2 | ON | claude-sonnet-4-5 |
| B1 | OFF | claude-haiku-4-5 |
| B2 | OFF | claude-sonnet-4-5 |

### Sample size

- **n per cell:** 30 full 10-turn trajectories
- **Per-turn observations:** 30 × 10 turns = 300 per cell
- **Total trials:** 4 cells × 30 trajectories = **120 full conversations**
- **Per-turn rubric evaluations:** 1,200 per-turn accuracy judgments
- **Power:** for slope difference at effect size 0.15 (0.15 acc-per-turn
  steeper decay in Cell B), n=30 trajectories × 5 late-turn observations
  per trajectory = 150 per cell, adequate for α=0.05 power=0.80.

### Fixture

`scripts/ab-harness/fixtures/multiturn_debug_v1.json` (shipped in
PR #211, EVAL-044). 30 scenarios × 10 turns each. Scenarios: debugging
tasks that require maintaining context across turns (error reappears,
partial fix required, test-driven iteration).

### Judge

Per-turn rubric: claude-sonnet-4-5 + Llama-3.3-70B panel, majority vote.
The rubric scores whether turn N's agent response is consistent with
turn 1..N−1 context and advances the debug task.

### Secondary rubric

EVAL-044 ships a **belief-drift rubric** — measures whether the agent
has lost track of claims it made earlier. Scored same per-turn basis.

## 4. Primary metric

**`late_turn_slope`** = linear regression coefficient of per-turn
accuracy on turn number, fit over turns 5–10 per trial, averaged per
cell.

**Pairwise delta:** `slope_A − slope_B` per tier, bootstrap 95% CI
from re-sampling trials.

## 5. Secondary metrics

- **Accuracy at turn 10** per cell, point estimate + Wilson 95% CI.
- **Belief-drift rate** per cell (EVAL-044 rubric).
- **Reference rate** per RESEARCH-022 applied to turn-by-turn belief_state
  injections — confirms the agent *reads* the injected state.
- **Tier interaction:** `(slope_A2 − slope_B2) − (slope_A1 − slope_B1)` —
  is sonnet's benefit bigger than haiku's?

## 6. Stopping rule

Planned n=30 trajectories per cell. No early stop. Budget cap: $75.

## 7. Analysis plan

**Primary:**
1. Per-cell, per-turn accuracy with Wilson 95% CIs (line plot).
2. Per-cell late-turn slope (turns 5–10 linear regression), bootstrap CI.
3. Slope delta per tier; H1 test.
4. Tier interaction (H1b).

**Secondary:**
- Reference rate (RESEARCH-022) per turn — does it grow / decay?
- Belief-drift correlation with accuracy — is drift a mediator (RESEARCH-023)?
- Per-task subgroup — do certain scenario types benefit more?

**Exploratory:**
- Does the effect survive on conversational tasks outside the debug
  scenario? (Requires extension fixture — file follow-up if warranted.)

## 8. Exclusion rules

Trajectory excluded if:
- Any turn returns empty output.
- Judge returns HTTP error on any of the 10 turns.
- Agent emits a refusal on turn 1 that aborts the scenario.

Excluded trajectory rate >15% invalidates the sweep.

## 9. Decision rule

**H1 supported (slope_A > slope_B on at least one tier, CI excludes 0):**
multi-turn belief_state benefit confirmed. Paper 3 has its primary
finding.

**H1b supported in addition (tier interaction with sonnet > haiku):**
Paper 3 leads with "tier-conditional multi-turn belief_state benefit"
— strongest novel framing.

**H1 rejected on both tiers:** belief_state does not help multi-turn
tasks at this fixture. Publishable as negative result; Paper 3 becomes
a methodology contribution ("when memory modules fail to help") rather
than a positive architecture claim. Paper 3 still ships.

## 10. Budget

- **Cloud:** ~$75 (120 × 10 turns × judge panel × n=2 judges ≈ 2,400
  judge calls + 1,200 agent turns)
- **Wall-clock:** ~10 hours end-to-end
- **Human time:** ~25 hours (fixture vetting, rubric iteration, writeup)

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Agents drop context voluntarily (memory shrinks past a threshold) | All cells run with same context budget (max 32k tokens); measured as covariate. |
| Judge cannot score turn-8 without seeing turns 1–7 | Judge prompt includes full prior turn history; verify in smoke test. |
| belief_state injection at turn 10 is stale (injected from turn 9 agent state) | By-design; that's what the module does. Report staleness as a covariate (mean stale-turn-count). |
| Fixture scenarios are too easy or too hard uniformly | 10-task pilot before main sweep; per-scenario accuracy must span [0.2, 0.8] on at least Cell B trials. |
| Multi-turn ups the vllm-mlx Metal-crash exposure | Sweep is cloud-only — Anthropic native API. No local inference. |

---

## Deviations

*(none yet)*

---

## Result document

`docs/eval/RESEARCH-024-multiturn-belief-state.md` after sweep completes.
