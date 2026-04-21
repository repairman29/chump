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
