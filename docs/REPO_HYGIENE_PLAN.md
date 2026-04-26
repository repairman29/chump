---
doc_tag: canonical
owner_gap: INFRA-067
last_audited: 2026-04-25
---

# Repo Hygiene Plan (INFRA-067)

Companion to [`DOC_HYGIENE_PLAN.md`](./DOC_HYGIENE_PLAN.md). That plan covers
`docs/*.md`. This one covers everything else: scripts/, crates/+src/,
top-level + config, and `.github/workflows/`.

## Why a single plan, not four

Each of the four areas has its own scope, blast radius, and tooling — but they
share one root cause: nothing distinguishes "live" from "stale" without reading
the file. The same instinct that produced 144 untagged docs produced 255
scripts of unknown vintage and an unknown number of orphan modules. The fix
shape is the same: classify first, automate the guard, then clean up.

## Scope inventory (2026-04-25)

| Area | Count | Concern |
|---|---|---|
| `scripts/*.{sh,py}` | 255 | Unknown which are live, which are one-shots, which are dead |
| `crates/*/` + `src/` | 9 crates + ~6 src/ subdirs | Orphan modules, unused deps post-REMOVAL-003 |
| top-level + config | ~30 files | Multi-location config drift (post Together.ai key leak); orphan dirs |
| `.github/workflows/` | 15 | Stale jobs (some pre-merge-queue, pre-INFRA-MERGE-QUEUE) |

## Area #1 — `scripts/` (5-phase, mirrors DOC-005)

255 scripts, no classification. Same shape as DOC-005:

- **Phase 0 — classify.** Add a single-line front-comment tag to each script:
  `# script_tag: live-tool | one-shot | bench | install | dead-candidate`.
  Tag is read by Phase 1 inventory.
- **Phase 1 — inventory.** `scripts/script-inventory.py` writes
  `scripts/_inventory.csv` with: path, tag, owner_gap, last_modified,
  inbound_refs (from CLAUDE.md, AGENTS.md, .github/, docs/, other scripts),
  line_count.
- **Phase 2 — automate.** Pre-commit guard refuses *new* untagged
  `scripts/*.{sh,py}`. CI step asserts every script in `_inventory.csv` has a
  valid tag. `chump script-archive` gardener subcommand flags
  `dead-candidate` rows older than 30 days.
- **Phase 3 — cleanup.** Stage-merge clusters (e.g. all `bench-*` scripts,
  all `*-reaper.sh`, all `apply-*-env.{sh,py}`) into single canonical
  scripts where possible.
- **Phase 4 — generate.** Auto-generate `scripts/README.md` from the
  inventory CSV, grouped by tag.

**Sub-gaps:** DOC-005 will get DOC-007..010 once each phase is picked up;
this area gets INFRA-068..072 on the same cadence. Don't pre-file all
five — file each only when the previous ships.

## Area #2 — `crates/` + `src/` dead-code audit (one-shot)

REMOVAL-003 (PR #465) deleted the 666-LOC belief_state crate. There's
likely more. This is a one-shot audit, not a recurring process — once
done, normal Rust compiler dead-code warnings keep things clean.

- **Tools:**
  - `cargo udeps --workspace --all-targets` — unused deps
  - `cargo machete` — unused dependencies (cross-check)
  - `cargo +nightly rustc -- -W dead_code` per crate — orphan modules
  - Manual review: `src/` subdirs, `crates/*/src/` for unreferenced files
- **Output:** one PR per cluster (unused deps, dead modules, dead bins). Don't
  bundle into one mega-PR — each cluster has a different blast radius.
- **Gap shape:** INFRA-073 (audit + report), then one cleanup gap per cluster.

## Area #3 — top-level + config (one-shot)

Triggered by the Together.ai key leak (caught and fixed earlier this cycle):
configuration is scattered across multiple locations and `.gitignore` was
missing entries.

- **Audit:**
  - `git ls-files | grep -E '\.(env|toml|yaml|yml|json)$'` at repo root
  - `find . -maxdepth 2 -type d` — orphan top-level dirs
  - Cross-check against `.gitignore` — every secrets-bearing path must be
    ignored AND have a `.example` sibling or be documented in
    `docs/CONFIGURATION.md` (file may need creating).
- **Output:** one PR consolidating config locations + tightening `.gitignore`
  + adding `docs/CONFIGURATION.md` if missing.
- **Gap shape:** INFRA-074, single PR.

## Area #4 — `.github/workflows/` consolidation (one-shot)

15 workflows; some predate the merge queue (INFRA-MERGE-QUEUE, 2026-04-19)
and may now be redundant or contradictory. Merge-queue + required-CI is
load-bearing — touching workflows is risky, but stale jobs cost CI minutes
and confuse newcomers.

- **Audit:**
  - List every workflow + trigger (`on:` block) + required-vs-optional status
  - Identify pre-merge-queue jobs that duplicate post-merge-queue grading
  - Identify any `pull_request` jobs that should now be `merge_group`
- **Output:** one PR removing or relocating stale jobs. Touch
  branch-protection settings only via PR description for human approval —
  agents cannot change required-check lists.
- **Gap shape:** INFRA-075, single PR. Label `human-review-wanted`.

## Sequencing

1. **INFRA-067 (this plan)** — ship plan.
2. **Area #1 Phase 0** (INFRA-068) — classify the 255 scripts. Highest fanout.
3. **Area #2** (INFRA-073) — dead-code audit; runs in parallel with Area #1
   since they touch disjoint files.
4. **Area #3** (INFRA-074) — config audit; small, independent.
5. **Area #4** (INFRA-075) — workflow consolidation; last because it's the
   riskiest and benefits from a clean baseline.

## What this plan is NOT

- Not a refactor charter. We are not redesigning crate boundaries or
  reorganizing src/ — only removing what is provably dead.
- Not a re-architect of CI. We are removing stale workflows, not designing
  new ones.
- Not a one-shot cleanup PR for any of the four areas. Each area gets its
  own gap (or gap sequence for Area #1) so blast radius stays scoped.

## Reference

- [`DOC_HYGIENE_PLAN.md`](./DOC_HYGIENE_PLAN.md) — sibling plan for `docs/*.md`
- [`RED_LETTER.md`](./RED_LETTER.md) — 2026-04-25 addendum (the trigger for both plans)
- [`AGENT_COORDINATION.md`](./AGENT_COORDINATION.md) — gap registry + coordination
