# Preregistration — EVAL-096

> **Status:** LOCKED at the commit of this file. Do not edit locked
> fields after data collection begins — add a Deviations entry instead.
> See [`README.md`](README.md) for the protocol.

## 1. Gap reference

- **Gap ID:** EVAL-096
- **Gap title:** n=100/cell + cross-judge replication of `CHUMP_BYPASS_NEUROMOD` on current binary
- **Source critique:** RESEARCH_INTEGRITY.md F3 (aggregate-magnitude retirement) + EVAL-095 contradiction signal
- **Author:** agent claude/eval-096-prereg
- **Preregistration date:** 2026-05-03

## 2. Hypothesis

**Primary hypothesis (H1) — must be falsifiable:**

> If `CHUMP_BYPASS_NEUROMOD=1` is set on the current chump binary, then
> the LLM-judged correctness rate on `reflection_tasks_formal_paired_v1.json`
> will differ from baseline (`CHUMP_BYPASS_NEUROMOD=0`) by **|Δ| ≥ 0.10**
> with Wilson 95% CIs **non-overlapping**, in either direction.

**Null hypothesis (H0):**

> |Δ| < 0.10 OR Wilson 95% CIs overlap zero. The earlier
> EVAL-095 (Δ=+0.150 directional) and EVAL-076 (Δ=−0.15 directional)
> were noise; F3 aggregate-magnitude retirement stands.

**Alternative explanations to rule out (specify which control addresses which):**

- *Judge-family bias.* Cross-judge audit per INFRA-079 (Anthropic
  `claude-haiku-4-5` as primary scorer + Together
  `meta-llama/Llama-3.3-70B-Instruct-Turbo` as audit scorer on the
  same trial JSONL). Cohen's kappa reported. If kappa < 0.6 the
  result is judge-dependent and a third family must adjudicate before
  closing the gap.
- *Binary-state confound.* EVAL-095 measured Δ=+0.150 on the current
  binary; EVAL-069 measured Δ=0.000 on an older binary (2026-04-21,
  pre-INFRA-X commits). This gap explicitly runs against current
  origin/main HEAD; the binary SHA is logged in every trial row so
  any future divergence is traceable.
- *Fixture-ordering effect.* Trials run in random order within each
  cell (seed logged); A/B cell assignment is per-trial, not per-batch.

## 3. Design

### Cells

| Cell | Intervention | Expected direction (per H1) |
|---|---|---|
| A | `CHUMP_BYPASS_NEUROMOD=0` (baseline — neuromod modules active) | reference |
| B | `CHUMP_BYPASS_NEUROMOD=1` (neuromod off) | direction not pre-stated; H1 is two-sided |

H1 is two-sided because the two prior underpowered replications
(EVAL-095 +0.150, EVAL-076 −0.15) point in opposite directions. Pre-
specifying a direction would bias which result counts as confirming.

### Sample size

- **n per cell:** **100**
- **Power analysis:** to detect Δ=0.10 at α=0.05 with power=0.80 on
  a binary outcome with baseline rate ≈ 0.50, n ≥ 96 per cell. n=100
  gives margin and matches the project's standard cell size for
  cross-judge studies.
- **Fixtures used:** `scripts/ab-harness/fixtures/reflection_tasks_formal_paired_v1.json`
  (same fixture as EVAL-095 + EVAL-069 + EVAL-076 to enable apples-to-apples
  comparison with the prior underpowered runs).

### Model & provider matrix

| Role | Model | Provider | Endpoint |
|---|---|---|---|
| Agent under test | `claude-haiku-4-5` | Anthropic | direct API (matches EVAL-095 binary stack) |
| Primary LLM judge | `claude-haiku-4-5` | Anthropic | direct API |
| Cross-judge auditor (INFRA-079) | `meta-llama/Llama-3.3-70B-Instruct-Turbo` | Together | Together API |

Cross-family judge per binding `RESEARCH_INTEGRITY.md` §"Required
Methodology Standard" — must include ≥1 non-Anthropic judge.

### Randomization & order

- **Trial order:** random per cell, seed logged in run header.
- **Cell assignment:** per-trial; trials interleaved A/B/A/B (not
  batched A-then-B) to immunize against drift in the underlying API
  service quality across the run window.
- **Seed discipline:** RNG seed logged in row 0 of the JSONL output;
  every trial row carries `(trial_idx, seed, cell, fixture_task_id,
  binary_sha)`.

### Run mechanics

- **Where:** `scripts/overnight/<NN>-eval-096-bypass-neuromod-n100.sh`
  per the gap's stated overnight-job intent.
- **Wall clock:** ~3-4h at the documented 90s/trial chump speed
  (200 trials × 90s ÷ 2 parallel slots = ~2.5h; allow 4h with
  cross-judge audit pass).
- **Cost estimate:** Anthropic primary scorer + Together free-tier
  audit. Anthropic spend ≈ \$5-15 (n=200 haiku trials @ ~3K
  tokens/trial). Together audit ≈ \$0 (free tier).

## 4. Primary metric

**Exact definition:**

```
correctness_rate(cell) =
    sum(row.judge_score == 1.0 for row in jsonl
        if row.cell == cell and row.scorer == "anthropic_haiku")
    /
    count(row for row in jsonl if row.cell == cell and row.scorer == "anthropic_haiku")

Δ = correctness_rate(B) − correctness_rate(A)
ci_low(cell), ci_high(cell) = Wilson 95% CI on the row count for that cell
```

Two analysts running this against the same JSONL must produce identical
numbers.

## 5. Decision rule (verbatim from gap description)

- **|Δ| ≥ 0.10 AND Wilson 95% CIs non-overlapping** → F3 aggregate-magnitude
  finding **reinstated**. Update `docs/process/RESEARCH_INTEGRITY.md` F3
  caveat to reflect direction + magnitude.
- **|Δ| < 0.10 AND Wilson 95% CIs non-overlapping** → F3 aggregate-magnitude
  retirement **confirmed**. Update RESEARCH_INTEGRITY.md to record the
  null-confirmation.
- **CIs overlap zero** (regardless of |Δ|) → file follow-up gap with
  larger n, document the indeterminacy in FINDINGS.md, do NOT close
  EVAL-096 to done. (Per binding integrity doc: "underpowered ≠ null".)
- **Cross-judge kappa < 0.6** → result is judge-dependent. Add a third
  judge family before closing. Do not report Δ as a project finding
  until kappa ≥ 0.6.

## 6. Prohibited claims (binding per RESEARCH_INTEGRITY.md)

Even if H1 confirms, the result MUST NOT be framed as:
- "Cognitive architecture improves agent performance"
- "Neuromodulation improves task performance" (the integrity doc
  explicitly notes EVAL-029 showed net-negative cross-architecture
  signal; reinstating F3 magnitude would update the *quantitative*
  caveat, not the architectural claim)
- "2000+ A/B trials validate Chump's cognitive architecture"

Acceptable framings: "On reflection_tasks_formal_paired_v1.json,
n=100/cell, the haiku-4-5 binary at SHA \<sha\> shows correctness Δ=\<x\>
between neuromod-on and neuromod-off cells (Wilson 95% CI \<lo,hi\>),
cross-judge kappa=\<k\>." Stick to the measured fixture / model / SHA.

## 7. A/A baseline reference

EVAL-013 (A/A on the same fixture, n=50) measured a noise floor of
approximately ±0.04. Any |Δ| < 0.10 is within twice the A/A noise
floor and should be treated as null-direction signal regardless of
how it compares to EVAL-095 / EVAL-076.

## 8. Deviations log

(Append entries here only after run begins. Locked design above does
not change without recording a deviation.)

(none yet — preregistration locked at commit time.)

Net-new-docs: +1
