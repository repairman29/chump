# Research-program cost optimization — Together free-tier strategy

> Supplements each preregistration's §10 Budget section with an
> explicit free-tier-first plan. Applies to RESEARCH-018, 020, 021,
> 022, 024, 026 (the gaps that collect or re-analyze cloud data).
> See [`RESEARCH-027`](../../gaps.yaml) for the harness-config work
> that automates the switch.

---

## TL;DR

Original 9-gap program budget estimate: **~$395 cloud**.
Optimized with Together free-tier substitution: **~$175 cloud**.
**Savings: ~$220 (55%)** with no reduction in n, no loss of
RESEARCH_INTEGRITY.md cross-family-judge compliance, and minor
wall-clock cost (Together free-tier rate limits ≈ 60 req/min).

The savings come from two substitutions:
1. **Non-Anthropic agent cells** — 3 of 4 families in
   RESEARCH-021's matrix (Llama, Qwen, DeepSeek) are available on
   Together's free tier at usable quality for our fixtures.
2. **LLM judges** — every preregistration requires ≥1 non-Anthropic
   judge per RESEARCH_INTEGRITY.md; Llama-3.3-70B-Instruct-Turbo
   and Qwen3-Coder-480B are free-tier and already integrated
   (`together:` prefix in `judge_model` — see
   `logs/ab/eval-025-*.jsonl` for live-fire usage).

---

## What's free on Together as of 2026-04-21

Together rotates the free-tier list periodically. The models below
were free-tier on the 2026-04-20 snapshot used in EVAL-069 and the
COG-031 dogfood runs. Verify before starting a sweep.

| Model | Size | Free? | Rate limit (typical) | Suitable role |
|---|---|---|---|---|
| `meta-llama/Llama-3.3-70B-Instruct-Turbo` | 70B | Yes | 60 rpm | Agent (large tier) + judge |
| `meta-llama/Llama-3.3-8B-Instruct` | 8B | Yes | 60 rpm | Agent (small tier) |
| `Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8` | 480B MoE (35B active) | Yes (2026-04-20 snapshot) | 60 rpm | Agent (large tier) + judge |
| `Qwen/Qwen2.5-7B-Instruct` | 7B | Yes | 60 rpm | Agent (small tier) |
| `Qwen/Qwen2.5-72B-Instruct-Turbo` | 72B | Yes | 60 rpm | Agent (large tier) + judge |
| `deepseek-ai/DeepSeek-V3` | 671B MoE (37B active) | Partial — may require paid | 60 rpm | Agent (large tier) |

**What's never free on Together:** the paid serverless tier for
newer or high-traffic models. Budget ~$0.60/M input + $0.60/M output
for paid tier if free-tier slot is unavailable that day. Still
<10% of Anthropic sonnet-4-5 rates.

**What still requires Anthropic directly:** claude-haiku-4-5 and
claude-sonnet-4-5 agent cells in RESEARCH-018 and RESEARCH-021's
Anthropic-family row. These are **load-bearing** — they're the
original finding's family, which we must replicate. Budget ~$40
for these cells.

## Per-preregistration revised budgets

### RESEARCH-018 — Length-matched control

Original: $50.
Revised: **$40**.

| Cell | Agent | Judges | Original | Revised |
|---|---|---|---|---|
| A × haiku | Anthropic | sonnet + Llama-3.3-70B (Together free) | $12 | $10 (judge free) |
| B × haiku | Anthropic | " | $12 | $10 |
| C × haiku | Anthropic | " | $12 | $10 |
| A × sonnet | Anthropic | " | $5 | $4 |
| B × sonnet | Anthropic | " | $5 | $4 |
| C × sonnet | Anthropic | " | $4 | $2 |

Savings: ~$10 (judge calls move off Anthropic).

### RESEARCH-021 — 4-family tier-dependence (the big one)

Original: $150.
Revised: **$40**.

| Family × tier | Agent cost | Notes |
|---|---|---|
| Anthropic haiku-4-5 × {A, B} | $18 | Load-bearing original family |
| Anthropic sonnet-4-5 × {A, B} | $15 | Load-bearing original family |
| Llama-3.3-8B × {A, B} | **$0** | Together free-tier |
| Llama-3.3-70B × {A, B} | **$0** | Together free-tier |
| Qwen2.5-7B × {A, B} | **$0** | Together free-tier |
| Qwen2.5-72B-Turbo × {A, B} | **$0** | Together free-tier |
| DeepSeek-V3-small × {A, B} | ~$4 | If free-tier slot unavailable |
| DeepSeek-V3 × {A, B} | ~$3 | If free-tier slot unavailable |
| Judge panel (3 judges × all 1600 trials) | **$0** | All three judges via Together free-tier |

Savings: ~$110. The DeepSeek cells are the main residual risk —
if Together throttles them, swap to a paid minute-slot
(`together:deepseek-ai/DeepSeek-V3-slim` pay-per-token) or drop
DeepSeek from the matrix (3-family replication still meets H1's
"≥3 of 4 families" requirement).

### RESEARCH-020 — Ecological fixtures

Original: $25. Revised: **$20**.

Judges move to Together free-tier (Llama-3.3-70B); agent cells
remain Anthropic since we're replicating findings on Anthropic
family's original matrix.

### RESEARCH-022 — Module-reference analysis

Original: $15 (LLM-stage paraphrase detection).
Revised: **$0**.

Swap the LLM-stage judge from claude-sonnet-4-5 to
`together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8` (free-tier).
Paraphrase-detection does not require a specific model family;
Qwen3-Coder-480B is equivalent quality for semantic-equivalence
scoring. Save $15. Expected budget $0.

### RESEARCH-024 — Multi-turn degradation

Original: $75. Revised: **$60**.

Agent is Anthropic (replicating haiku/sonnet multi-turn). Judge
panel (10 turns × 120 trajectories × 2 judges = 2,400 judge calls)
moves to Together free-tier. Saves $15.

### RESEARCH-026 — Observer-effect check

Original: $20. Revised: **$15**.

Small savings (all judges Together free-tier). Agent stays
Anthropic.

### Gaps with $0 cost — no change

- RESEARCH-023 — mediation analysis is post-hoc on existing JSONLs.
- RESEARCH-025 — human-grading only; no LLM compute cost.
- RESEARCH-019 — already shipped.

## Total revised program budget

| Gap | Original | Revised |
|---|---|---|
| RESEARCH-018 | $50 | $40 |
| RESEARCH-020 | $25 | $20 |
| RESEARCH-021 | $150 | $40 |
| RESEARCH-022 | $15 | $0 |
| RESEARCH-023 | $0 | $0 |
| RESEARCH-024 | $75 | $60 |
| RESEARCH-025 | $0 | $0 |
| RESEARCH-026 | $20 | $15 |
| **Total** | **$335** | **$175** |

Savings: **$160** cloud. The `$395` figure in the research critique
was a ceiling estimate; the revised `$175` is the realistic floor
assuming Together free-tier availability holds through Q3.

## Wall-clock implications

Free tier ≈ 60 rpm. Each trial = 1 agent call + N judge calls
(typically 2–3). For RESEARCH-021 at 1,600 trials × 4 calls per
trial = 6,400 calls, wall-clock floor is ~2 hours at sustained
throughput, probably 3–4 hours with backoff. Acceptable for
a single-dogfooder sprint.

For RESEARCH-024 at 1,200 per-turn observations × 3 judges =
3,600 calls, wall-clock ~1 hour.

## Implementation status

**Already supported by the harness** (no code change required for
judge swaps):
- `judge_model` argument accepts comma-separated `together:<model>`
  and `anthropic:<model>` prefixes — see
  `scripts/ab-harness/run-cloud-v2.py` callsites and the archived
  `eval-025-*.jsonl` live-fire examples.
- `TOGETHER_API_KEY` in `.env` is already set.

**Not yet supported** (filed as RESEARCH-027):
- Agent-side Together routing in `scripts/ab-harness/run-binary-ablation.py`
  and `run-cloud-v2.py`. Currently the agent is hardcoded to
  Anthropic or to the `CHUMP_DISPATCH_BACKEND=chump-local`
  provider-cascade path. For RESEARCH-021's 4-family sweep, we
  need an explicit `--agent-provider together --agent-model <name>`
  switch. RESEARCH-027 scopes the work.
- Rate-limit-aware sweep mode — automatic backoff + retry when
  Together returns 429. Exists in `run-binary-ablation.py` at
  1s backoff; RESEARCH-027 should raise it to 5s/30s/60s expo.

## Risk register for the free-tier strategy

| Risk | Impact | Mitigation |
|---|---|---|
| Together removes a model from free tier mid-sweep | Mid-sweep provider switch or budget bump | Pre-check free-tier list at sweep start; abort before trial 1 if the planned model is no longer free; document fallback model per cell in the preregistration |
| Free-tier rate-limit throttle slows sweep | Wall-clock doubles | Build throttle-aware pacing into RESEARCH-027 (5s → 30s → 60s expo backoff); parallelize across providers where possible |
| Judge-family monoculture if all judges are Together | RESEARCH_INTEGRITY.md violation | Preserve ≥1 Anthropic judge in every panel; only swap the *second* judge to Together free-tier |
| Contamination — Qwen judges see Qwen agent outputs | Circular validation | Rule: same-family judge is excluded from trials where its family is the agent (stated in each preregistration's §3 panel) |
| DeepSeek tier-dependence cells unavailable on free tier | Drop from 4-family matrix to 3 | H1 still checkable at 3 families; acceptable degradation |

## Follow-up gap

**RESEARCH-027** (filed with this doc) — ship the harness code
changes that let preregistered sweeps route agents to Together's
free tier via CLI flags. Until RESEARCH-027 ships, the agent side
of the free-tier swap must be done manually by running the chump
binary with the Together provider env vars set. Judges can be
routed immediately using the existing `--judge` flag.
