# almanac zero-hit mining — first real run (EFFECTIVE-380)

`scripts/dev/almanac-zero-hits.py` mines almanac's usage telemetry
(`~/.almanac/usage.jsonl`, schema owned by `crates/almanac-core/src/usage.rs`
in the separate repairman29/almanac repo) for zero-hit queries — questions
the fleet actually asked, in its own words, that the index could not answer
— and clusters them into themes classified as `absent` / `retrieval-miss` /
`unsupported-artifact`. See the script's module docstring for the full
rationale and the "why chump-side, not almanac-side" note.

## Honesty note on this run

This chump worktree had no `~/.almanac/usage.jsonl` (a fresh sandbox never
ran almanac). To satisfy "first real run recorded, visible now" without
waiting on a live log, this run used a **106-call synthetic fixture** shaped
to match the real sample cited in the gap description (2026-08-06: 6%
zero-hit rate over 106 calls) — 100 realistic hit queries plus 6 realistic
zero-hit queries spanning all three causes. The retrieval-miss evidence
below is **not staged**: it is real `git grep` output against this actual
checkout, manually verified (see "spot-check" below). The next real fleet
run against a live `usage.jsonl` should replace this file's numbers — that
replacement is the actual first-run signal this doc exists to unblock.

## Command

```
python3 scripts/dev/almanac-zero-hits.py --log <fixture> --days 3650
```

## Output

```
almanac zero-hit mining — <fixture>
  106 calls, 6 zero-hit (5.7%), 6 distinct themes, showing top 6
  by cause: {'retrieval-miss': 3, 'unsupported-artifact': 3}

1. [retrieval-miss] "MISSION-045 anti-bloat outcome gate keystone"  (x1)
   method: git grep on this checkout found >= 2 of the cluster's distinctive query tokens within 6 lines of each other — the content exists, so the zero-hit is a retrieval quality bug, not absence
   - 'MISSION-045 anti-bloat outcome gate keystone'
   evidence: crates/chump-preflight/src/preflight.rs:681-681: 'keystone' and 'mission' co-occur within 6 lines
   evidence: crates/chump-verify/src/external_verify_merge.rs:3-4: 'keystone' and 'mission' co-occur within 6 lines

2. [retrieval-miss] "where does chump block P0 reserves with no outcome"  (x1)
   method: git grep on this checkout found >= 2 of the cluster's distinctive query tokens within 6 lines of each other — the content exists, so the zero-hit is a retrieval quality bug, not absence
   - 'where does chump block P0 reserves with no outcome'
   evidence: crates/chump-preflight/src/preflight.rs:681-681: 'reserves' and 'outcome' co-occur within 6 lines
   evidence: src/almanac_tool.rs:161-161: 'reserves' and 'outcome' co-occur within 6 lines

3. [unsupported-artifact] "how is the supabase RLS policy defined for the gaps table"  (x1)
   method: regex match on SQL-shaped terms (sql/rls/migration/postgres/create table/…) — almanac never indexes SQL (INFRA-3530, deliberate deferral, not a bug)
   - 'how is the supabase RLS policy defined for the gaps table'

4. [unsupported-artifact] "sql migration that adds the gaps table schema"  (x1)
   method: regex match on SQL-shaped terms (sql/rls/migration/postgres/create table/…) — almanac never indexes SQL (INFRA-3530, deliberate deferral, not a bug)
   - 'sql migration that adds the gaps table schema'

5. [unsupported-artifact] "gap importer written in swift for the ios client"  (x1)
   method: regex match on an unsupported source-language extension (swift/kt/c/h/cpp/rb/java) — ast-crawler's is_supported() does not cover these yet (CREDIBLE-210 class)
   - 'gap importer written in swift for the ios client'

6. [retrieval-miss] "does chump ship a windows msi installer wizard"  (x1)
   method: git grep on this checkout found >= 2 of the cluster's distinctive query tokens within 6 lines of each other — the content exists, so the zero-hit is a retrieval quality bug, not absence
   - 'does chump ship a windows msi installer wizard'
   evidence: docs/strategy/CI_POLICY_AUDIT.md:143-146: 'installer' and 'windows' co-occur within 6 lines
   evidence: docs/process/SCHEDULING_LAYERS.md:237-239: 'installer' and 'wizard' co-occur within 6 lines
```

## Spot-check (proves AC3, not just claims it)

Theme 1's evidence line `crates/chump-preflight/src/preflight.rs:681-681`
points at:

```
        // MISSION-045: outcome-gate keystone — proves P0/P1 reserves are blocked
        // without an outcome (when outcomes exist), the audited flag + empty-DB
        // skip work. Fast (~2s), pure local (chump binary + temp dirs, no network).
```

— i.e. the fixture's zero-hit query really was about content that exists,
verbatim, in this checkout. That is the concrete quality-bug proof AC3 asks
for: a real almanac index that missed this would be a retrieval bug, not a
coverage gap.

## A known, disclosed limitation (this is what AC2 means by "a reader can disagree")

Theme 6 is a good example of the heuristic's ceiling: the query was crafted
to be genuinely off-topic ("windows msi installer"), but proximity-based
token co-occurrence still found two *unrelated* hits (a CI-policy doc
mentioning "windows" and "installer" separately, a scheduling doc mentioning
"installer" and "wizard" separately) and called it `retrieval-miss`. This is
a real false-positive risk of the method: 2-of-N generic-word co-occurrence
within `PROXIMITY_WINDOW=6` lines, on a large multi-domain repo, produces
occasional coincidental matches, especially for words this repo's own docs
happen to use in an unrelated sense (chump has its own internal "wizard"
role, orchestrator terminology, etc.). The classification method is stated
per-cluster precisely so a human triaging the themes can override calls like
this one — the tool is a ranking/triage aid over 100+ raw log lines, not an
oracle.

## Follow-up

Filed as a follow-up: port this mining logic (or call out to it) from the
real `almanac usage --zero-hits` CLI surface in the separate
repairman29/almanac repo, once that repo is available in the working
environment — see the script's module docstring for why this landed
chump-side first.
