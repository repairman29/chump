# Preregistration — RESEARCH-018

> **Status:** LOCKED at commit `<SHA-filled-at-merge>`. Do not edit locked
> fields after data collection begins — add a Deviations entry instead.

## 1. Gap reference

- **Gap ID:** RESEARCH-018
- **Gap title:** Length-matched scaffolding-as-noise control — rule out prompt-length confound in every lessons A/B
- **Source critique:** [`docs/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md) §1
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21

## 2. Hypothesis

**H1 (primary).** Injecting the **content** of the COG-016-versioned lessons
block into the system prompt produces a tier-dependent accuracy/hallucination
effect that is **not reproduced** by injecting a length-matched random-prose
placebo. Formally: `|Δ(A−B)| > |Δ(C−B)| + ε` where A = lessons block, B = no
injection, C = length-matched null prose, ε = 0.05.

**H0.** `|Δ(A−B)| ≤ |Δ(C−B)| + 0.05` — the "content" has no effect beyond
the "prompt length / ceremony" effect.

**Alternative explanations ruled out by this design:**
- *Prompt-length confound* — addressed by Cell C (length-matched placebo).
- *Formatting/structure confound* — partially addressed: Cell C will use
  the same markdown skeleton as the lessons block with headings/bullets,
  just with random-prose bullets. Explicitly **not** controlled: the
  presence-of-structure-at-all. Follow-up gap if needed.
- *Position confound* — not controlled in this study; the block goes in the
  same system-prompt position across cells.

## 3. Design

### Cells

| Cell | Intervention | System prompt contains | Expected H1 direction |
|---|---|---|---|
| A | Lessons block ON | real lessons block (~2000 chars) | haiku: +; sonnet: − (hallucination) |
| B | Lessons block OFF | no injection | neutral (baseline) |
| C | Length-matched placebo | random-prose block, same char count + same markdown skeleton | ≈ B (prediction: placebo is null) |

### Sample size

- **n per cell:** 100 trials per (cell × model-tier)
- **Total trials:** 3 cells × 2 tiers (haiku-4-5, sonnet-4-5) = **600 trials**
- **Power analysis:** for a binary outcome at baseline p=0.50 and target
  Δ=0.10, Wilson 95% CI non-overlap requires n≥96 per cell; n=100 gives a
  small margin. For the hallucination-rate outcome at baseline p=0.15,
  Δ=0.10 requires n≥75 per cell; n=100 is adequate.
- **Fixtures:** `scripts/ab-harness/fixtures/reflection_tasks.json` — same
  fixture used in EVAL-025, EVAL-027 so results compose.

### Model & provider matrix

| Role | Model | Provider | Endpoint |
|---|---|---|---|
| Agent | claude-haiku-4-5 | Anthropic | native API |
| Agent | claude-sonnet-4-5 | Anthropic | native API |
| Judge 1 | claude-sonnet-4-5 | Anthropic | native API |
| Judge 2 (required cross-family) | Llama-3.3-70B-Instruct-Turbo | Together | serverless |

### Randomization & order

- Trial order: random permutation per cell, seeded by `(cell_name, trial_idx)`
  hashed with SHA-256 for reproducibility.
- Cell assignment: within-subject per task — each task fixture is run in
  Cell A, B, and C to reduce variance.

## 4. Primary metric

**Definition:**
```
correctness_score = judge_returns_pass_on_rubric(agent_output, rubric, task)
# Per-cell mean of correctness_score across n=100 trials
# Pairwise delta: mean(A) - mean(B), mean(C) - mean(B)
# H1 test: |mean(A) - mean(B)| > |mean(C) - mean(B)| + 0.05
```

**Reporting:** per-cell mean + Wilson 95% CI + pairwise delta with
bootstrap 95% CI (10k resamples).

## 5. Secondary metrics

- `hallucinated_tool_call_rate` — per EVAL-041 regex, per cell, with CI.
  The sonnet-tier hallucination effect (+0.33 from EVAL-027c) is the
  strongest prior-published Chump delta; if it doesn't reproduce in Cell A
  but does in Cell C, the finding is invalid.
- `mean_tool_calls_per_trial` — per cell.
- `judge_inter_rater_kappa` — Judge 1 vs Judge 2 per cell; expect ≥0.70.
- `response_character_length` — to confirm the length-matched placebo
  didn't inadvertently shift output length.

## 6. Stopping rule

**Planned n:** 100 per cell.

**Early stop allowed?** No for primary hypothesis. Interim peek at n=50/cell
is permitted for smoke-gating (abort if exit_code ≠ 0 on >20% of trials) but
the decision rule only fires at n=100.

**Exhaustion stop:** If budget ($50 cloud cap) exceeded before n=100, report
at the actual n achieved and label as "underpowered relative to preregistration."

## 7. Analysis plan

**Primary (preregistered):**
1. Compute per-cell correctness and hallucination means with Wilson 95% CIs.
2. Compute pairwise deltas (A−B) and (C−B) with bootstrap 95% CIs.
3. Test H1: `|Δ(A−B)| − |Δ(C−B)| > 0.05` with CI from paired bootstrap.
4. Verify against A/A noise floor from EVAL-042 (±0.03); all reported
   deltas must be ≥3× A/A to be interpretable.

**Secondary (also preregistered):**
- Per-judge breakdown: rerun primary analysis using Judge 1 only and
  Judge 2 only; report both.
- Per-task-category: split by reflection-task subtype; report per-subtype
  delta with CIs.

**Exploratory (clearly labeled):**
- Does Cell C delta correlate with response length? (Tests whether *any*
  system-prompt content systematically shifts verbosity, not just length.)

## 8. Exclusion rules

A trial is excluded iff:
- Agent response is empty (exit_code ≠ 0 or output < 10 chars).
- Judge call returns HTTP error after 3 retries.
- OPENAI_API_BASE (or Anthropic endpoint) was unreachable per trial log.

All exclusions logged in JSONL with reason. Exclusion rate >10% invalidates
the sweep.

## 9. Decision rule

**If H1 supported** (|Δ(A−B)| − |Δ(C−B)| > 0.05 on correctness OR on
hallucination, CI excludes zero): the tier-dependent injection finding is
**content-driven**, not ceremony-driven. Ship as confirmed result in
`docs/FINDINGS.md`; eligible for Paper 1 without length-matched-confound
caveat.

**If H0 supported** (deltas equivalent within ε=0.05): the tier-dependent
finding **reframes** to "system-prompt content-or-ceremony shifts frontier
model behavior in a tier-dependent way." Publishable but narrower. Paper 1
outline rewrites to lead with the reframe.

**If ambiguous** (CIs wide): escalate to n=200 per cell. File follow-up
gap RESEARCH-027.

## 10. Budget

- **Cloud:** ~$50 (600 trials × ~$0.08 amortized Anthropic + judge)
- **Wall-clock:** ~6 hours end-to-end if sweep pipeline doesn't crash
- **Human time:** ~4 hours (harness flag addition, result-doc authoring)

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| vllm-mlx Metal crash (INFRA-006) | Not applicable — sweep is cloud-only (Anthropic + Together), not local. |
| python3 shebang foot-gun (INFRA-017) | Already fixed in PR #344; verify `scripts/ab-harness/run-cloud-v2.py` runs under python3.12 before start. |
| Judge-family monoculture (RESEARCH_INTEGRITY.md) | Addressed by Judge 2 (Llama-3.3-70B non-Anthropic). |
| Length-matched placebo leaks semantic content | Generation method: `scripts/ab-harness/gen-null-prose.py` (NEW) — uses frequency-matched random tokens from a large English corpus with the same markdown skeleton. No sentences that could match task rubrics. |
| Observer effect inflates all cells equally | Addressed separately in RESEARCH-026; not a threat to H1 (which is a *within-study* comparison). |

---

## Deviations (append-only)

*(none yet — locked at preregistration commit)*

---

## Result document

After data collection, results will be reported in `docs/eval/RESEARCH-018-length-matched.md`
with an explicit statement of whether H1 was supported, rejected, or ambiguous per §9.
