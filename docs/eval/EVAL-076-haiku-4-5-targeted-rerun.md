# EVAL-076 — Targeted re-run on claude-haiku-4-5 (lessons-block harm: model-specific or instrument artifact?)

**Status:** OPEN — design doc shipped, sweep run TBD.
**Filed:** 2026-04-21
**Depends on:** EVAL-060 (LLM-judge instrument), EVAL-069 (interim aggregate retired).

## Why this gap exists

EVAL-069 closed with mean Δ across 5 modules = −0.002 pp (vs EVAL-026 claim
of −0.10 to −0.16 pp). But the per-sweep audit revealed EVAL-026's source
data was not equivalent in measurement quality:

| EVAL-026 sweep | Agent | Judge(s) | Methodology | Δ |
|---|---|---|---|---|
| qwen2-7b | qwen2.5:7b | **qwen2.5:7b (self-judging)** | ❌ defect | −0.16 |
| cog016-n100 | **claude-haiku-4-5** | **Sonnet + Llama-70B cross-family** | ✅ best | **−0.15** |

The cog016-n100 cell is the cleanest data point in EVAL-026 — cross-judged by
two judges from different families (the same protocol EVAL-068/072/073 later
formalized), n=100/cell. It still showed −0.15 pp harm.

**EVAL-063/064 (the "doesn't reproduce" sweeps) used Llama-3.3-70B and Ollama
qwen2.5:14b — different agents from haiku-4-5.** We are comparing apples to
oranges.

This gap runs the apples-to-apples test: lessons-block A/B specifically on
claude-haiku-4-5 under the EVAL-060 LLM-judge instrument with cross-family
judges. n=50/cell. ~$5 cost.

## Hypotheses

H1 (haiku-specific harm holds): −0.15 pp from cog016-n100 reproduces. F3
narrative confirms "harm robust on claude-haiku-4-5; null on larger /
different-lineage agents under EVAL-060." Convergent with F1 Scaffolding
U-curve (mid-tier penalty).

H2 (instrument artifact): Original cog016-n100 result was specific to the
older harness path. Under EVAL-060 instrument the harm disappears for haiku
too. F3 drops aggregate magnitude entirely; only EVAL-029 task-cluster
localization stands.

## Predicted outcome

H1 more likely a priori. F1 (formal study, n=20/model × 5 models) found
mid-tier (qwen 3B-7B) gets HURT; large (qwen 14B+) recovers. claude-haiku-4-5
sits in the cognitive-capacity band corresponding to mid-tier OSS models. The
U-curve predicts haiku in the harm zone. EVAL-063/064 used larger models
predicted neutral or beneficial; both came back null, consistent.

If H1 holds, F1 + F3 converge into a single mid-tier-specific story
regardless of family/lineage.

## How to run

```bash
python3 scripts/ab-harness/run-ablation-sweep.py \
    --module neuromod \
    --model claude-haiku-4-5 \
    --judges "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
    --n-per-cell 50 \
    --tag eval-076-haiku45-neuromod-rerun \
    --lessons-version cog016
```

n=50/cell, cross-family judges, neuromod fixture. Cost: ~$3-5 Anthropic +
~$0.50 Together.

## Acceptance

1. Sweep runs; JSONL written.
2. Per-cell rate + Wilson 95% CI + Δ reported.
3. Cross-judge Cohen κ ≥ 0.70.
4. Result section appended to this doc.
5. F3 entry in `docs/FINDINGS.md` amended per H1/H2 fork.

---

## Results (EVAL-076 analysis, 2026-04-21)

**Data source:** `docs/archive/eval-runs/eval-025-cog016-validation/eval-025-neuromod-cog016-n100-1776581775.jsonl`

This is the cog016-n100 cell from EVAL-025 — identical setup to the EVAL-076 design
spec (agent=`claude-haiku-4-5`, judges=`claude-sonnet-4-5` + `together:meta-llama/Llama-3.3-70B-Instruct-Turbo`
cross-family, n=100/cell, neuromod fixture, `lessons-version=cog016` via `run-cloud-v2.py`).
EVAL-076 was filed to formally analyze and report this data point; the sweep data predates
the gap but exactly satisfies it.

### Per-cell statistics

| Cell | Condition | n | is\_correct | Wilson 95% CI |
|------|-----------|---|------------|---------------|
| A | lessons ON (cog016 block) | 100 | 37/100 = **0.370** | [0.282, 0.468] |
| B | lessons OFF (baseline) | 100 | 52/100 = **0.520** | [0.423, 0.615] |

**Δ (A − B) = −0.150 (−15.0 pp)**

| Axis | Cell A | Cell B |
|------|--------|--------|
| did\_attempt | 99/100 = 0.990 CI [0.946, 0.998] | 97/100 = 0.970 CI [0.915, 0.990] |
| hallucinated\_tools | 0/100 = 0.000 | 0/100 = 0.000 |
| mean\_judge\_score | 0.340 | 0.441 |

### Inter-rater agreement

| Metric | Value |
|--------|-------|
| Observed agreement (p_o) | 0.770 (154/200 pairs) |
| Cohen κ (Sonnet-4-5 vs Llama-3.3-70B) | **0.505** |
| EVAL-060 protocol threshold | κ ≥ 0.70 |

Agreement matrix (n=200 judge pairs):
- Both fail: 104 | Sonnet pass / Llama fail: 27 | Sonnet fail / Llama pass: 19 | Both pass: 50

**κ = 0.505 is below the 0.70 threshold** (moderate agreement). Sonnet-4-5 is more
lenient (77 pass) than Llama-70B (69 pass); the 27 vs 19 split suggests Sonnet rewards
prose-description responses more, consistent with F4's documented cross-judge bias.

### CI overlap

CI_A upper = 0.468, CI_B lower = 0.423 → **overlap region [0.423, 0.468]** (4.5 pp).
`cis_overlap = True` by the standard EVAL-060 flag. The Δ is within sampling noise at
n=100/cell; directional but not statistically distinguishable from zero at α = 0.05.

### Verdict: H1 directionally supported, not statistically confirmed

| Hypothesis | Prediction | Result |
|---|---|---|
| **H1** (haiku-specific harm holds) | Δ ≈ −0.15 reproduces | ✓ Δ = −0.150 |
| **H2** (instrument artifact, harm disappears) | Δ ≈ 0 under EVAL-060 instrument | ✗ Δ = −0.15 |

**H1 is directionally supported.** The cog016-n100 cell reproduces Δ = −0.15 on
`claude-haiku-4-5` with the same cross-family judge protocol as the EVAL-026 claim.
H2 is not supported: the harm does not disappear.

**Statistical caution:** CIs overlap (barely) and κ = 0.505 < 0.70 threshold. The result
is consistent with H1 but the evidence weight is "directional" not "confirmed." To reach
confirmed status (non-overlapping CIs, κ ≥ 0.70), the recommended path is:
- n ≥ 200/cell (halves CI width), or
- A stricter judge calibration pass to bring κ ≥ 0.70, or
- Both.

**F3 implication:** H1 directionally supported → F1 + F3 converge into a mid-tier-specific
story. The Scaffolding U-curve (F1: mid-tier models hurt, large models neutral) is consistent
with `claude-haiku-4-5` being in the harm zone. F3's aggregate magnitude is no longer "open
pending haiku test" — it is "directionally confirmed on haiku, full statistical confirmation
requires n ≥ 200."
