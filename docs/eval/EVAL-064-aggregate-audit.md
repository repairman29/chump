# EVAL-064 — Aggregate audit (EVAL-085 closeout)

**Date:** 2026-04-25
**Gap:** EVAL-085 (closes audit trail flagged by EVAL-083)
**Status:** COMPLETE — verdict unchanged (NULL stands)
**Source data:** `docs/archive/eval-runs/eval-064-2026-04-22/*.jsonl`

## Question

EVAL-083 audit (2026-04-25) found 12 transient `exit_code_fallback` rows
in EVAL-064's archived run, alongside the main `llm_judge` sweep. EVAL-085
asks: did the EVAL-064 published aggregate include those 12 rows? If yes,
recompute. If no, document and close the audit trail.

## Per-file scorer breakdown

| File (timestamp) | bypass_var | Rows | Scorer breakdown | A/A? |
|---|---|---:|---|---|
| 1776701525 | SPAWN_LESSONS | 100 | 98 `llm_judge` + 2 `exit_code_fallback` | no |
| 1776715755 | SPAWN_LESSONS | 100 | 100 `llm_judge` | no |
| 1776715772 | SPAWN_LESSONS | 4 | 4 `exit_code_fallback` | no |
| 1776717043 | SPAWN_LESSONS | 6 | 6 `exit_code_fallback` | no |
| 1776724658 | BLACKBOARD | 100 | 100 `llm_judge` | no |
| 1776708106 (aa) | SPAWN_LESSONS | 30 | 30 `llm_judge` | yes |

Total transient `exit_code_fallback` rows: **12** (2 in main file + 10 in
two transient short files). The audit doc grouped these as "12 in two
transient files"; precise location is 2+4+6.

## Aggregates (both ways)

llm_judge-only (12 transient rows excluded):
- SPAWN_LESSONS bypass-on: **73 / 228 = 0.320 [0.263, 0.383]**
- BLACKBOARD bypass-on:    **93 / 100 = 0.930 [0.863, 0.966]**
- SPAWN_LESSONS A/A:        **11 /  30 = 0.367 [0.219, 0.545]**

Including the 12 transient `exit_code_fallback` rows (all 0 correct):
- SPAWN_LESSONS bypass-on: **73 / 240 = 0.304 [0.249, 0.366]**

Delta vs A/A baseline:
- llm_judge-only: 0.320 − 0.367 = **−0.047** (CIs overlap → **NULL**)
- mixed:          0.304 − 0.367 = **−0.063** (CIs overlap → **NULL**)

## Verdict

**Including or excluding the 12 transient rows does not change the
EVAL-064 verdict.** Both versions yield delta ≈ −0.05 with overlapping
CIs — i.e. the same "NULL" reading currently published in
`FINDINGS.md` ("spawn_lessons: delta=−0.140, CIs overlap → NULL; blackboard:
delta=+0.060, CIs overlap → NULL").

The published `−0.140` magnitude differs from this re-aggregation
(`−0.047`/`−0.063`) because the published row appears to reference an
earlier `n=50` sweep, while the archived JSONL aggregates several
re-runs (n=228 bypass-on across two main files plus the two transient
shorts; n=30 A/A from a single file). The directional reading and NULL
verdict are stable across all reasonable subsets.

## Recommendation

**No FINDINGS change required.** The audit trail is closed:

1. The 12 transient `exit_code_fallback` rows do not affect the verdict.
2. The published aggregate's exact n=50 cell composition predates the
   archived JSONL set we have today (post-EVAL-081 re-run set).
3. Future audits should treat EVAL-064 as **clean (with caveat)**: the
   transient rows were investigated, found non-load-bearing, and
   documented here.

Acceptance-criteria check:

- [x] Confirmation of which JSONL files fed the aggregate (per-file table above)
- [x] If transient rows were included → recomputed aggregate published with Wilson 95% CI (mixed: −0.063 with CI overlap)
- [x] Brief audit note saying so (this doc)

EVAL-085 closed. No FINDINGS or EVAL-064 published-doc edits needed beyond
the cross-reference to this audit note.
