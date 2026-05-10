# EVAL-101 Result — Cognition A/B: structural scoring (Qwen 2.5 14b)

> **Preregistration:** [`docs/eval/preregistered/EVAL-101.md`](../preregistered/EVAL-101.md)
> **Sweep date:** 2026-05-10
> **Model:** Qwen 2.5 14b via Ollama (local)
> **Judge:** Structural property checks (`scripts/ab-harness/score.py`)
> **Cells run:** A (cognition OFF), B (cognition ON) — Cell C (padding) skipped due to Ollama timeout

## Result: H1 rejected

The cognition stack (reflections + neuromodulation + semantic lessons) does **not** produce a measurable improvement in structural task-completion score when running on Qwen 2.5 14b with this fixture.

### Quantitative summary

| Metric | Cell A (OFF) | Cell B (ON) | Delta (B−A) | Threshold |
|---|---|---|---|---|
| **Overall pass rate** | 0.500 | 0.525 | **+0.025** | ≥0.10 |
| **Clean tasks** | 0.700 | 0.650 | −0.050 | — |
| **Gotcha tasks** | 0.300 | 0.400 | +0.100 | — |
| **Avg tool calls** | 0.825 | 0.625 | −0.200 | — |

### Per the decision rule

> **If H1 rejected** (CI overlaps zero or delta < 0.10): Ship as null result.

The cognition stack does not measurably improve outcomes on this fixture with structural scoring and Qwen 2.5 14b.

### Caveats & next steps

1. **Structural scoring is crude** — keyword matching misses semantic quality. An LLM-judge scoring pass (the preregistered secondary metric) might reveal differences the structural checks don't capture.
2. **Qwen 2.5 14b is not Claude Sonnet** — the prereg listed Sonnet as the agent under test. A weaker model may have lower base rates that obscure the cognition effect. Re-running with Sonnet via Anthropic API (~$4) would test this.
3. **Weak gotcha signal (+0.10)** — the cognition stack shows a suggestion of improvement on gotcha tasks (Δ=+0.10, noise-floor level). This could be real but underpowered at n=20/cell.
4. **Clean tasks regress (−0.05)** — cognition ON slightly hurts clean task performance. If real, this could mean the extra context distracts rather than helps on straightforward tasks.

### Recommendation

**Don't ship the cognition stack as default-ON based on this evidence.** The null result doesn't prove the stack is useless — it proves we can't measure a benefit on this setup. Options:

- **LLM-judge scoring** (cheap, ~$1): re-score the existing 80 trials with Haiku + GPT-4o-mini judges to see if semantic quality differs.
- **Sonnet re-run** (~$4): repeat with Claude Sonnet as the agent, which may have higher base rates and show the effect.
- **Per-component ablation** instead of whole-stack: test each flag individually to find which (if any) helps.

### Raw data

- Cell A: `logs/ab/cognition-ab-1778433709-A-1778433709.jsonl` (40 trials)
- Cell B: `logs/ab/cognition-ab-1778433709-B-1778436508.jsonl` (40 trials)
- Scored: `logs/ab/cognition-ab-1778433709-A-1778433709.summary.json`
- Scored: `logs/ab/cognition-ab-1778433709-B-1778436508.summary.json`
