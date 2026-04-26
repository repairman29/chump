# Archive: EVAL-025 cog016 validation runs

Archived 2026-04-19 from `.claude/worktrees/eval-025/logs/ab/` before
worktree removal. Original PR: #120 (merged 2026-04-19). Original
branch: `claude/eval-025-cog016-validation`.

## Files

- `eval-025-reflection-cog016-n100-1776579365.summary.json` + `.jsonl`
  — n=100 reflection fixture, claude-haiku-4-5, cog016 lessons block
- `eval-025-perception-cog016-n100-1776580628.summary.json` + `.jsonl`
  — n=100 perception fixture, same agent + lessons block
- `eval-025-neuromod-cog016-n100-1776581775.summary.json` + `.jsonl`
  — n=100 neuromod fixture, same agent + lessons block
- `eval-025-smoke-1776579297.jsonl` — n=5 smoke test before main run

## Headline result (per `docs/research/CONSCIOUSNESS_AB_RESULTS.md`)

| Fixture | Δ hallucination (cog016) | Status |
|---|---|---|
| reflection | -0.01 (overlap, noise) | eliminated harm |
| perception |  0.00 (overlap, noise) | eliminated harm |
| neuromod   |  0.00 (overlap, noise) | eliminated halluc but +0.15 correctness drift |
| **mean**   | **-0.003** | **directive works at haiku-4-5** |

Compare to EVAL-023 baseline (v1 lessons block, same fixtures, same
agent): mean +0.137 hallucination delta. The directive eliminated the
documented harm at this tier.

## Subsequent context (post-archive)

EVAL-026b <!-- NOTE: informal ID from this eval run; not filed in docs/gaps.yaml --> (2026-04-19) revealed the directive does NOT behave uniformly
across capability tiers — backfires at sonnet-4-5 in n=50 sample
(EVAL-027c <!-- NOTE: informal ID; not filed in docs/gaps.yaml --> at n=100 confirmation in flight at archive time). See
`docs/eval/EVAL-029-neuromod-task-drilldown.md` <!-- NOTE: EVAL-029 not yet filed in docs/gaps.yaml --> and
`docs/architecture/CHUMP_FACULTY_MAP.md` for current Reasoning faculty status.
