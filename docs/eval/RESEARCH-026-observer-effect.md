# RESEARCH-026 — Observer-effect / evaluation-framing (result shell)

**Gap:** `RESEARCH-026` in `docs/gaps.yaml`  
**Preregistration:** [`preregistered/RESEARCH-026.md`](preregistered/RESEARCH-026.md)  
**Pilot / rewrite rules:** [`RESEARCH-026-naturalization-pilot.md`](RESEARCH-026-naturalization-pilot.md)

**Harness shipped:** [PR #400](https://github.com/repairman29/chump/pull/400) on `main` (2026-04-21).

## Status

| Milestone | State |
|-----------|--------|
| 50-task casual fixture (`reflection_tasks_casual_v1.json`) | **Done** (`naturalize-fixture.py`) |
| 50-task formal fixture paired to same IDs/order | **Done** (`reflection_tasks_formal_paired_v1.json` via `sync-reflection-paired-formal.py`) |
| Harness wiring (`run-observer-effect-ab.sh` + `run-cloud-v2.py --n-per-cell --out-dir` + CI preflight) | **Done** ([PR #400](https://github.com/repairman29/chump/pull/400)) |
| Human validation gate (≥8/10 pilot rewrites) | **Pending** (Jeff — table in pilot doc) |
| Cloud sweep n=50/cell × 2 framings × 2 tiers (=400 trials in gap accounting) | **Pending** (API keys + ~\$15–\$20 budget per prereg) |
| Wilson / paired analysis → `docs/FINDINGS.md` | **Pending** (after JSONLs exist) |

This file becomes the **canonical result memo** once the sweep finishes: paste
per-tier summaries, judge panel, and the §9 decision (H1 vs H0).

## One-command sweep (after validation gate)

From repo root (requires `ANTHROPIC_API_KEY` and judge access as for other
`run-cloud-v2.py` sweeps):

```bash
scripts/ab-harness/run-observer-effect-ab.sh \
  --casual-fixture scripts/ab-harness/fixtures/reflection_tasks_casual_v1.json \
  --n-per-cell 50 \
  --tiers haiku sonnet
```

Formal fixture defaults to `reflection_tasks_formal_paired_v1.json` (paired to
the casual file). Override with `--formal-fixture` only if you know the IDs
still match.

Smoke / harness check (cheap):

```bash
scripts/ab-harness/run-observer-effect-ab.sh --smoke
```

## Analysis (after JSONLs land)

For each tier, pick the matching pair of JSONLs (`research-026-<tier>-formal-*`
vs `research-026-<tier>-casual-*` timestamps from the same run), then:

```bash
python3.12 scripts/ab-harness/analyze-observer-effect.py \
  --formal-jsonl logs/ab/research-026-haiku-formal-<ts>.jsonl \
  --casual-jsonl logs/ab/research-026-haiku-casual-<ts>.jsonl \
  --cell A
```

**Interpretation note:** `run-cloud-v2.py` still runs an internal **lessons A
vs B** ablation per fixture. For framing isolation, the preregistered primary
comparison holds **lessons constant** by comparing **cell A** (lessons on)
between the formal pass and the casual pass at the same tier, paired by
`task_id`. Use `--cell B` only for a secondary “lessons-off framing” probe.

## Regenerate paired formal after casual edits

Whenever `reflection_tasks_casual_v1.json` is regenerated:

```bash
python3.12 scripts/ab-harness/sync-reflection-paired-formal.py
```

## Decision rule (from prereg §9)

- **|Δ| > 0.05** (formal vs casual, per tier, with CI excluding zero): document
  observer-effect correction requirement for Paper 1.
- **Otherwise:** record as validation that casual naturalization did not move
  correctness enough to threaten published deltas.
