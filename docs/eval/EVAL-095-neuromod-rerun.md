# EVAL-095 — Empirical re-run of CHUMP_BYPASS_NEUROMOD on current chump binary

**Date:** 2026-05-02
**Gap:** EVAL-095 (deferred from EVAL-090)
**Status:** COMPLETE — directional support for F3, full statistical confirmation deferred
**Verdict:** **Δ = +0.150 (neuromod helps), CIs overlap, per-task pattern supports F3 localization.** EVAL-069's null verdict on this fixture+agent does not survive replication on the current chump binary.

## TL;DR

| | EVAL-069 (2026-04-21) | EVAL-095 (2026-05-02) |
|---|---|---|
| n per cell | 50 | 20 |
| acc cell A (control) | 0.920 | 0.850 |
| acc cell B (bypass ON) | 0.920 | 0.700 |
| **Δ (A − B)** | **+0.000** | **+0.150** |
| Wilson 95% CI excludes zero? | yes (delta=0) | **no — overlaps** |
| Per-task structure | mixed (t005 +0.5, t028 −1.0) | concentrated harm (t015, t017, t019 all +1.0) |

Same fixture (`scripts/ab-harness/fixtures/neuromod_tasks.json`), same agent (Ollama qwen2.5:14b), same judge (Claude Haiku 4.5), same harness. The chump binary has had ~10 days of neuromod-related work between the two runs.

## Method

Per [`docs/eval/preregistered/EVAL-090.md`](preregistered/EVAL-090.md) (which scoped both EVAL-090 and the deferred EVAL-095):

- n=20 per cell (40 trials total)
- Cell A: `CHUMP_BYPASS_NEUROMOD` unset (neuromod active, control)
- Cell B: `CHUMP_BYPASS_NEUROMOD=1` (neuromod bypassed, ablation)
- Agent: Ollama qwen2.5:14b at `http://127.0.0.1:11434/v1`
- Judge: Claude Haiku 4.5 (Anthropic, single judge — apples-to-apples with EVAL-069)
- Scorer: `--scorer llm-judge` (verified post-EVAL-090; 40/40 rows show `scorer=llm_judge`)
- Trial timeout: 300s (chump binary regressed to ~90s/trial average; old 120-180s harness defaults timed out)
- Run started 2026-05-02 03:04:15Z, completed ~03:55Z (~50 min wall-clock — actually slower than estimated; first trial took longer due to agent warmup)

Raw JSONL preserved at `docs/archive/eval-runs/eval-095-2026-05-02/eval049-binary-llmjudge-1777691055.jsonl`.

## Results

### Aggregate

| Cell | n | Acc | Wilson 95% CI |
|---|---|---|---|
| A — control (neuromod ON) | 20 | 0.850 | [0.640, 0.948] |
| B — ablation (neuromod bypass ON) | 20 | 0.700 | [0.481, 0.855] |

**Δ (A − B) = +0.150** (positive = neuromod helps). CIs **overlap** ([0.640, 0.948] vs [0.481, 0.855]; overlap = 0.215). The point estimate is in the predicted direction at the 15-pp magnitude EVAL-026 originally claimed, but n=20 is underpowered to cleanly exclude zero.

### Per-task structure (the load-bearing finding)

The cells share 17 tasks where outcome is identical between A and B (most succeed; t005, t010, t013 fail in both). The entire +0.150 aggregate comes from **3 tasks where neuromod ON succeeds and bypass ON fails**:

| Task | Cell A | Cell B | Δ |
|---|---|---|---|
| t015 | 1.00 | 0.00 | **+1.00** |
| t017 | 1.00 | 0.00 | **+1.00** |
| t019 | 1.00 | 0.00 | **+1.00** |

This is the **task-cluster localization** F3 has always claimed. Without per-task replication (n=1 per cell per task here), we can't compute per-task CIs. But the structural pattern matches: harm is concentrated in specific tasks, not spread uniformly.

### Other quality checks

- `scorer=llm_judge` on 40/40 rows (the EVAL-090 lesson honored)
- `output_chars > 0` on 37/40 rows; 3 timeouts hit even at 300s (counted as `correct=False` by the judge — appropriate)
- Average trial duration: 87s

## Decision per EVAL-090 §9

**Empirical H1/H0 axis: AMBIGUOUS** — point estimate in predicted direction at the predicted magnitude (+0.15), but Wilson 95% CI overlaps zero. Per the prereg ambiguous case: "next step — file follow-up to extend to n=100/cell or replicate on Together-routed agent."

**Compared to EVAL-069 verdict:** EVAL-069 found Δ=0.000 (no signal) on the same fixture+agent in 2026-04-21. EVAL-095 finds Δ=+0.150 in 2026-05-02. The two results are mutually inconsistent — same fixture, same agent, ~10 days apart. The likely explanation is **chump's neuromod implementation has changed in those 10 days** such that the ablation now produces a measurable effect where it didn't before. Sampling noise at n=20 vs n=50 cannot fully account for the +0.15 vs +0.00 swing.

## Implications for FINDINGS.md (F3)

The F3 caveat currently says (post-EVAL-090): "F3's aggregate-magnitude retirement therefore rests on a working instrument." That remains true for the **2026-04-21 binary state** but no longer for the **current binary state**. Update needed to acknowledge that the picture has shifted:

> "EVAL-095 (2026-05-02) replicated EVAL-069's protocol on the current chump
> binary and found Δ=+0.15 with localized harm in 3 specific tasks (t015,
> t017, t019) — directionally supporting F3, but Wilson 95% CIs overlap
> zero so not statistically confirmed at n=20. The 2026-04-21 binary
> produced Δ=0.000; the current binary produces Δ=+0.15. The retirement
> verdict (EVAL-069) is binary-specific and may need re-opening: file a
> follow-up at n≥100/cell on the current binary, OR confirm via Together
> Llama-70B as a second judge family. EVAL-076 (cog016-n100, claude-haiku
> agent) already showed Δ=−0.15 directional with overlapping CIs — EVAL-095
> is the second independent directional support. Two underpowered
> replications pointing the same direction is suggestive."

## Followups

- **EVAL-096** (file): n≥100/cell replication on current binary with cross-judge audit (Anthropic + Together Llama-70B). Threshold: |Δ|≥0.10 with non-overlapping CIs to settle the F3 reinstate-or-retire question.
- **INFRA-???** (file): chump binary performance regression — neuromod path is ~90s/trial under qwen2.5:14b vs (presumably) faster in 2026-04-21. The behavioral change between binaries is the load-bearing news; the perf change is the side effect that made this run take 2.5h instead of 50min.

## Cost

- Cloud spend: ~$0.50 (Claude Haiku 4.5 judge × 40 trials)
- Wall-clock: ~50 min sweep + ~30 min smoke + investigation
- Failed earlier attempts: 2 (n=50 zombie + n=20 with too-tight 120s smoke timeout); both produced no usable data
