# EVAL-102 Result — Cognition A/B Follow-up (n≥50/cell)

> **Preregistration:** [`docs/eval/preregistered/EVAL-102.md`](../preregistered/EVAL-102.md)
> **Result status:** RESULTS PENDING — harness run not yet executed
> **Preregistration locked:** 2026-05-11 (commit SHA to be recorded at data collection start)
> **Result doc filed:** 2026-05-14
> **Author:** Claude Sonnet 4.6 (operator-delegated per META-046)

---

## Why EVAL-101 Cannot Be Cited

EVAL-101 (2026-05-10) returned null (Δ=+0.025) but violated the following
protocol requirements:

| Violation | Required | Actual |
|---|---|---|
| Primary agent | claude-sonnet-4-6 | Qwen 2.5 14b (Ollama local) |
| n per cell | ≥50 (RESEARCH_INTEGRITY §1) | 20 |
| Cell C (padding control) | Required | Omitted (Ollama timeout) |
| LLM judges | haiku + gpt-4o-mini | Structural scoring only |
| Deviations section | Must document all deviations | Left blank |

The EVAL-101 null result cannot be cited as evidence the cognition stack
fails or succeeds. **EVAL-102 is the first citable run.**

---

## Protocol Summary

**Hypothesis (H1):** Cognition stack ON (CHUMP_REFLECTION_INJECTION=1 +
CHUMP_NEUROMOD_ENABLED=1 + CHUMP_LESSONS_SEMANTIC=1 +
CHUMP_LESSONS_AT_SPAWN_N=5) increases composite task-completion score by
≥0.08 vs all-off, with Wilson 95% CI lower bound strictly above zero.

**Null (H0):** Mean delta ≤ 0.03 OR Wilson CI crosses zero.

**Cells:**
| Cell | Intervention |
|---|---|
| A | Cognition stack OFF (baseline) |
| B | Cognition stack ON (treatment) |
| C | Neutral padding control (~500 tokens, rules out length confound) |
| A' | Cell A repeated with seed_offset=1 (A/A noise floor) |

**n per cell:** 50 (RESEARCH_INTEGRITY §1 minimum for directional signal)

**Primary metric:** Composite score = 0.5 × structural + 0.5 × mean(haiku_binary, llama_binary)

**Decision rule:**

| Outcome | Decision |
|---|---|
| Wilson lower bound on (B−A) > 0.05, \|C−A\| < 0.5×\|B−A\|, kappa > 0.4 | **SUPPORTED** — keep cognition defaults |
| Wilson CI on (B−A) crosses zero, OR (B−A) < 0.03 | **NULL** — gut lesson injection; no new cognition gaps until re-run |
| \|C−A\| > 0.5×\|B−A\| | **LENGTH CONFOUND** — re-design with content-matched control |
| kappa < 0.4 | **JUDGES DISAGREE** — reformulate rubric |
| n < 50/cell after 48h | **UNDERPOWERED** — re-baseline only |

**Evaluation-awareness consideration (EVAL-087 directive):** This eval uses
fixtures that include task IDs and harness-style preamble. Evaluation-awareness
cannot be ruled out until EVAL-094 (naturalized-framing comparison) ships.
Result interpretation must carry this caveat unless Cell C shows awareness is
absent (i.e., if the padding cell — which looks like non-eval content — shows
similar delta to Cell A, that disfavors awareness as a mechanism).

**Cross-judge gate:** κ ≥ 0.60 between haiku and Llama-3.3-70B under the
strict binary rubric is required to report mechanism claims (EVAL-093 directive).

---

## Results Status: PENDING

The harness run requires:
- Live Anthropic API access (claude-sonnet-4-6 + claude-haiku-4-5)
- Together AI API access (meta-llama/Llama-3.3-70B-Instruct, free tier)
- ~$4–6 budget for 200 primary trials + 250 judge scoring passes
- ~24h wall-clock at API rate limits

**To execute:**

```bash
# 1. Smoke-check (n=2/cell, ~$0.05) — required before full launch (anti-EVAL-076 pattern)
python3.12 scripts/ab-harness/run-local-v2.py \
  --gap EVAL-102 \
  --cells A,B,C,A_prime \
  --n 2 \
  --agent claude-sonnet-4-6 \
  --judges claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct \
  --scorer llm-judge \
  --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
  --prereg docs/eval/preregistered/EVAL-102.md

# 2. Full run (n=50/cell)
python3.12 scripts/ab-harness/run-local-v2.py \
  --gap EVAL-102 \
  --cells A,B,C,A_prime \
  --n 50 \
  --agent claude-sonnet-4-6 \
  --judges claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct \
  --scorer llm-judge \
  --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
  --prereg docs/eval/preregistered/EVAL-102.md \
  --budget-cap-usd 15 \
  --wall-clock-cap-hours 48
```

**Runtime enforcement:** The runner reads the locked-fields manifest from
`docs/eval/preregistered/EVAL-102.md` §12 and refuses to start if any env
var or CLI flag diverges from the preregistered values. If EVAL-103
(prereg-enforcement gates) has not shipped, add `--skip-enforce-check` and
document as a deviation in §13 of the prereg.

---

## Downstream Consequence Map

These gaps are gated on EVAL-102's outcome. The operator should apply the
decision immediately on result landing:

### Unblocks if SUPPORTED (B−A ≥ 0.08)

| Gap | What it enables |
|---|---|
| COG-049 (closed) | Context-expanded lesson queries — already shipped; confirm signal is real |
| REMOVAL-004 | Haiku-specific neuromod bypass retest — positive Sonnet result motivates Haiku investigation |
| META-039 | Close the learning loop — semantic retrieval worth investing in if cognition shows measurable effect |
| CREDIBLE-059 | LLM-judge re-score of cognition-ab — this IS that re-score; supersedes CREDIBLE-059 |

### Confirms dead if NULL (Δ ≤ 0.03 or CI crosses zero)

| Gap | What it means |
|---|---|
| META-039 | Learning loop investment is faith-based — demote to P3 pending better signal |
| REMOVAL-004 | Neuromod retest not motivated — close or P3 |
| Any new cognition-stack gaps | Blocked until a re-run with design changes shows positive signal |
| COG-044–COG-050 (all closed) | Implemented on faith; null result doesn't validate them but doesn't require rollback unless cost analysis shows waste |

**Null action required:** If null, file one gap to audit cognition-stack
cost vs. benefit (token overhead vs. unmeasured gain) and document the
decision in AGENTS.md / ROADMAP.md Week 2 outcome.

---

## Cross-Judge Kappa Requirement

Per RESEARCH_INTEGRITY §2 and EVAL-093:
- κ ≥ 0.60 between haiku and Llama-3.3-70B on the 50-task overlap is the bar
- A/A noise floor must be within ±0.05 before interpreting B−A delta
- Mechanism claims for any |Δ| > 0.05 require explicit evaluation-awareness
  consideration (EVAL-087 directive)

---

## Single-Judge Scope Declaration

This study uses a **multi-judge design** (haiku + Llama-3.3-70B) and is
therefore **not** a single-judge scope study. Cross-judge audit artifact
requirement (RESEARCH_INTEGRITY §8) is satisfied by design: the JSONL
output from the runner includes `judge_model` fields covering both
anthropic and meta judge families.

---

## Next Steps for Operator

1. Verify API credits available: Anthropic (~$5) + Together AI (free tier,
   confirm token quota not exhausted)
2. Verify EVAL-103 (prereg enforcement runner) has shipped — if not, add
   a deviation note when running
3. Execute smoke-check first (n=2/cell), verify at least one trial produced
   non-empty stdout and a real `judge_score` (not `exit_code_fallback`)
4. Launch n=50/cell sweep
5. Update §13 (Deviations) of `docs/eval/preregistered/EVAL-102.md` if any
   config drift occurred
6. Replace this result doc with actual numbers once the sweep completes
7. Apply downstream consequence map immediately per decision rule

---

## Compliance Checklist

- [x] Preregistration filed before data collection (2026-05-11)
- [x] n=50 per cell specified (RESEARCH_INTEGRITY §1)
- [x] Non-Anthropic judge included (Llama-3.3-70B, RESEARCH_INTEGRITY §2)
- [x] Exit-code scorer explicitly prohibited (RESEARCH_INTEGRITY §6)
- [x] A/A control cell included (RESEARCH_INTEGRITY §5)
- [x] Evaluation-awareness as candidate mechanism considered (EVAL-087)
- [x] Strict binary rubric on both judges (RESEARCH_INTEGRITY §2)
- [x] Cross-judge kappa gate specified: κ ≥ 0.60 (EVAL-093)
- [x] Downstream consequence map explicit (gap list above)
- [ ] Results recorded (PENDING — harness run required)
- [ ] Decision rendered (PENDING)
- [ ] Linked from ROADMAP.md current cycle (see Week 2 update)
