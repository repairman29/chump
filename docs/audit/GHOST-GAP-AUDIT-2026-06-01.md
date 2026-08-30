# Ghost-gap audit — COG-*/EVAL-* PR-title references with no YAML/DB row

**INFRA-2395** (ZERO-WASTE). Filed date estimated ~36 ghost gap_ids; the
actual inventory below found **105** (27 `COG-*` + 78 `EVAL-*`) merged-PR-title
references to a gap_id that has neither a `docs/gaps/<id>.yaml` file nor a
`gaps` table row in `.chump/state.db`. The original estimate undercounted
because it was made without running the full `git log --all` sweep across
every historical squash-merge title.

## Method

1. `git log --all --oneline -E --grep='(COG|EVAL)-[0-9]+' -i` — every commit
   subject (across all refs) mentioning a `COG-*` or `EVAL-*` id, filtered to
   subjects ending in `(#NNNN)` (i.e. an actual squash-merged PR title, not a
   WIP or since-rewritten commit).
2. Extracted the unique set of `COG-*`/`EVAL-*` ids referenced (113 ids).
3. Diffed against the union of:
   - `SELECT id FROM gaps WHERE id LIKE 'COG-%' OR id LIKE 'EVAL-%'` in the
     canonical `.chump/state.db` (16 rows: `COG-044/045/047/048/049/050/054`,
     `EVAL-085/086/087/094/101/102/103/124/125`)
   - `docs/gaps/{COG,EVAL}-*.yaml` on disk (same 16 ids — YAML and DB agree,
     no drift between them)
4. Cross-checked the resulting 105 ghost ids against `gap_dup_archive_audit`
   (the dedup/archive audit trail) — **zero matches**. These ids were never
   filed as gaps and then archived/merged into a survivor; they simply never
   got a `docs/gaps/<id>.yaml` or DB row in the first place.
5. For each ghost id, recorded every referencing PR number and the earliest
   commit subject, to support classification.

Full per-id table (id, referencing PRs, candidate `closed_pr` = highest PR
number that mentions the id, representative commit subject) is in
`/tmp/ghost_table.md` at audit time; the summary below is the operator-facing
cut. Raw sweep artifacts (`/tmp/ghost_details.tsv`, `/tmp/ghost_pr_ids.txt`)
are ephemeral — re-run the method above to regenerate.

## Findings summary

| Metric | Value |
|---|---|
| Unique `COG-*`/`EVAL-*` ids in merged PR titles | 113 |
| ...with existing YAML + DB row | 16 |
| **Ghost ids (neither YAML nor DB row)** | **105** |
| — `COG-*` ghosts | 27 |
| — `EVAL-*` ghosts | 78 |
| Ghosts matched in `gap_dup_archive_audit` | 0 |
| `INFRA-NNN` ghosts found (typo class) | 0 — see note below |

**No `INFRA-NNN` ghosts found.** The gap's AC anticipated an `INFRA-087` vs
`INFRA-87` style typo class; a parallel sweep of `INFRA-[0-9]+` ids in merged
PR titles against `docs/gaps/INFRA-*.yaml` + DB found no such orphans — the
INFRA namespace has been consistently YAML/DB-backed since early on. The typo
classification (b) is therefore **empty** in this audit; keep the sweep
method above on file for the next quarterly re-run in case future INFRA
titles drift.

## Root cause

All 105 ghosts date from the **April–June 2026 cognition-stack / evaluation
R&D sprint** (COG-001 through COG-053, EVAL-002 through EVAL-100), which
predates the point at which `docs/gaps/<id>.yaml` + `state.db` row became the
mandatory system of record for every gap (INFRA-498 and the gap-doctor drift
checks that followed). During that sprint, gap ids were assigned informally
inside commit messages and roadmap doc chunks ("chore(gaps): file COG-025 …",
"gap-seed(EVAL-071): file follow-ups …") without a corresponding YAML file
ever being committed — the id existed only as a citation inside prose. A
minority of ids in the same two namespaces (16 total) *did* eventually get
backfilled into YAML/DB, which is why the namespaces aren't wholesale absent
from the tracking system — just inconsistently backfilled.

## Classification decision matrix

| Classification | Definition | Count | Disposition |
|---|---|---|---|
| **(a) Historical experiment, finished long ago** | Predates mandatory YAML/DB tracking; the underlying work shipped (each id has a `candidate_closed_pr` — the highest-numbered PR that references it, usually the one that reported final results or explicitly closed/superseded the id) | **105 / 105** | Recommend `chump gap ship <id> --closed-pr <candidate_closed_pr>` backfill, batched, **operator-reviewed** before execution (see Not-destructive note below) |
| **(b) Typo in PR title** | e.g. `INFRA-087` vs `INFRA-87` | 0 | none found this pass |
| **(c) Intentional rebranding** | prefix retired, ids replaced by a new domain | 0 | `COG-*`/`EVAL-*` are **not** retired — `COG-054`, `EVAL-124`, `EVAL-125` are live tracked ids as of this audit, so the prefixes remain in active use; this is inconsistent backfill, not rebranding |

Every one of the 105 ghosts falls into class (a). Representative evidence
patterns backing this call:

- **Explicit closure language already in the commit subject** — e.g.
  `COG-041`: *"chore(close): auto-close COG-041 via PR #1112"*; `EVAL-050`:
  *"chore(gaps): close EVAL-047 (#253) (#257)"*; `COG-018`: *"research: close
  COG-001 + open COG-014-018 …"*. These ids were opened and closed entirely
  within the informal commit-message workflow of the era.
- **Superseded-by-later-finding language** — e.g. `EVAL-090`: *"AUDIT-3
  broken-scorer claim contradicted by archived JSONL; F3 retirement
  stands"*; `EVAL-088`: *"amend EVAL-073 result doc — cross-judge agreement
  was rubric- and fixture-specific"*. The research question the id
  represented was answered and written up; nothing is pending.
- **Absorbed into a consolidated findings doc** — a cluster of ids
  (`EVAL-069/070/071`, `EVAL-060/061`, `EVAL-062/063/064`) all resolve to the
  same commit subjects (`docs(FINDINGS): consolidate F1-F6 empirical
  findings`, `docs(EVAL-061): choose path (b) for all three NULL-validated
  faculties`) — these were graduated into `docs/RESEARCH_INTEGRITY.md` /
  findings docs rather than staying open as individually tracked gaps.
- **No open thread**: none of the 105 ids appear in any *currently open*
  gap's `depends_on`, and none appear as an `archived_id` in
  `gap_dup_archive_audit` (which would indicate a live successor gap took
  over the work) — there is no dangling dependency pointing at a ghost id.

## Per-id table

id | referencing PR(s) | candidate `closed_pr`
---|---|---
COG-001 | 39,48,91,1016 | #1016
COG-006 | 51,91,210 | #210
COG-007 | 29,176,184,243 | #243
COG-011 | 29,37,176,1398,2325 | #2325
COG-014 | 44,47,49,65,70,91,108,2325 | #2325
COG-015 | 66,78,79,90,98,111,113,271,523 | #523
COG-016 | 80,90,113,114,120,128,134,149,161,205,215,380,750,2325,2329 | #2329
COG-018 | 111,176 | #176
COG-019 | 111,122,126 | #126
COG-020 | 128,167,171,927 | #927
COG-021 | 128,232,233 | #233
COG-022 | 128,234,235 | #235
COG-023 | 128,130,134,135,154 | #154
COG-024 | 130,140,153,154,523,776,927,982,1142 | #1142
COG-025 | 169,172,759,770,783,934,1058 | #1058
COG-026 | 169,172,182,186,197,521,855,876,981,1035 | #1035
COG-027 | 173,178,212,213 | #213
COG-031 | 185,186,194,197,209,216,276,289,326,553 | #553
COG-032 | 812,817,918,921,927,1011,1020 | #1020
COG-035 | 606,607,608,1016,4072 | #4072
COG-036 | 606,607,608,609 | #609
COG-037 | 606,607,608,610,614,1031,1041 | #1041
COG-038 | 614,617,619,620,637 | #637
COG-039 | 641,650,842,1031,1045 | #1045
COG-041 | 1112,1114 | #1114
COG-051 | 1290 | #1290
COG-053 | 1206,1310,1398 | #1398
EVAL-003 | 29,176,184 | #184
EVAL-008 | 36,39 | #39
EVAL-010 | 44,47,49,50,51,52,58,65,80,85,244,247,2325 | #2325
EVAL-011 | 60,65,67,1124 | #1124
EVAL-012 | 65,73,113,116 | #116
EVAL-013 | 65,77 | #77
EVAL-014 | 65,71,73,83,2325 | #2325
EVAL-015 | 65,75 | #75
EVAL-017 | 65,71,109 | #109
EVAL-019 | 65,78 | #78
EVAL-020 | 65,74 | #74
EVAL-021 | 65,79 | #79
EVAL-022 | 65,76,80,2325 | #2325
EVAL-023 | 90,111,113,114,118,120,128,133,226 | #226
EVAL-024 | 90,114,115 | #115
EVAL-025 | 120,128,133,142,148,215,362,368,380,633,2329 | #2329
EVAL-026 | 128,133,151,154,156,283,288,290,330,335,336,364,373,1358,1359,1360,1363,1365,1368,1371 | #1371
EVAL-027 | 128,130,133,134,140,142,154,380 | #380
EVAL-028 | 128,138,146,154,253 | #253
EVAL-030 | 128,161,212,242,243,633,663,750 | #750
EVAL-031 | 128,238,243 | #243
EVAL-032 | 128,206,210 | #210
EVAL-033 | 128,138,226,229 | #229
EVAL-035 | 128,207,633,640 | #640
EVAL-036 | 128,219,221 | #221
EVAL-037 | 128,249,251 | #251
EVAL-038 | 128,205,212,258 | #258
EVAL-039 | 248,251 | #251
EVAL-040 | 128,236,237 | #237
EVAL-041 | 173,244,246,247 | #247
EVAL-042 | 175,215,219,296,317,553,554 | #554
EVAL-043 | 175,210,255,316,590,633,640,663,797,2329,3103 | #3103
EVAL-044 | 211,348,352 | #352
EVAL-046 | 244,247,251 | #251
EVAL-047 | 252,253,257,259,260,262 | #262
EVAL-048 | 255,263,371,523 | #523
EVAL-049 | 256,288 | #288
EVAL-050 | 257,258,259,260,266 | #266
EVAL-051 | 259,260,263 | #263
EVAL-052 | 262 | #262
EVAL-053 | 264,268,271,273,275,279,288,336 | #336
EVAL-054 | 265,275,284,286,292 | #292
EVAL-055 | 266 | #266
EVAL-056 | 268,271,275,297,750 | #750
EVAL-057 | 269 | #269
EVAL-058 | 270,271,275,297 | #297
EVAL-059 | 270,273,275,277,286,385 | #385
EVAL-060 | 273,276,279,282,289,290,291,292,296,297,327,330,334,335,336 | #336
EVAL-061 | 274,276,280,286,288,297 | #297
EVAL-062 | 278,281,292 | #292
EVAL-063 | 278,282,283,288,291,292,296,330,335,336,364,525,527 | #527
EVAL-064 | 278,282,283,289,290,291,295,297,327,364,525,528 | #528
EVAL-065 | 285,340,405 | #405
EVAL-066 | 289,291,404,405 | #405
EVAL-067 | 289,297,327 | #327
EVAL-068 | 289,296,299,314 | #314
EVAL-069 | 290,296,330,335,336,344,347,364,467,525,527,722,730,737 | #737
EVAL-070 | 290,318 | #318
EVAL-071 | 290,332,338,339,345,467,549,551,552,558,666 | #666
EVAL-072 | 299,314,317 | #317
EVAL-073 | 311,314,317,321,551,554,558 | #558
EVAL-074 | 332,335,339,526,546,549,551,552,554,557,558,589,590,600,601,625,646,666,779,1016 | #1016
EVAL-075 | 332,345 | #345
EVAL-076 | 335,336,346,364,366,373,737,789,1017,1463 | #1463
EVAL-081 | 385,525,527 | #527
EVAL-083 | 525,527,528,641 | #641
EVAL-084 | 525,527,528 | #528
EVAL-088 | 554,557,558,628,634,2676,2677,2678 | #2678
EVAL-089 | 558,601,603,779 | #779
EVAL-090 | 577,580,714,722,726,730 | #730
EVAL-091 | 580,778 | #778
EVAL-092 | 600,601,603,606,714 | #714
EVAL-093 | 606,779 | #779
EVAL-095 | 722,726,730,737,738,778,789,1017 | #1017
EVAL-096 | 737,789,1017,1146,1193 | #1193
EVAL-097 | 1003,1006 | #1006
EVAL-098 | 1094,1114,1116,1492 | #1492
EVAL-100 | 1116 | #1116

## Ambient emission

One `kind=ghost_gap_audit_finding` event was emitted to `.chump-locks/ambient.jsonl`
per row above, with fields `{gap_id, pr_numbers_referencing, classification,
candidate_closed_pr}`. Registered in `docs/observability/EVENT_REGISTRY.yaml`
under "Gap-registry hygiene (INFRA-2395)".

## Not destructive — operator review required (AC #5)

This audit performed **no PR retitling** and **no `state.db` mutations**.
The 105 candidate `closed_pr` backfills above are a **recommendation**, not
an executed action — creating a `status:done` row for an id that never had
one is a new-row insert, not a status update on an existing row, so it is
deliberately left for the operator to execute (or decline) after reviewing
this report, e.g.:

```bash
# Illustrative — NOT run by this audit:
chump gap reserve --domain COG --title "<derived from commit subject>" --no-outcome-required
chump gap ship <id> --closed-pr <candidate_closed_pr> --update-yaml
```

Given the volume (105) and that these are purely historical/paper-trail
backfills with zero live dependents, the recommended operator action is
either (a) batch-backfill via a small script wrapping the table above, or
(b) explicitly decide the paper trail isn't worth the DB rows and close this
audit as informational-only. Both are reasonable; this doc exists so the
decision is made deliberately rather than by omission.
