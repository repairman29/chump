# DOC-005 — Doc hygiene plan

**Filed:** 2026-04-25
**Owner:** DOC-005 (this gap = the plan; staged sub-gaps file the work)
**Trigger:** Red Letter "143 docs/*.md files (up from 66)" — first-pass survey
showed obvious cleanup targets all have inbound references, so a delete pass
without infrastructure breaks the published mdBook. Phase 4b consolidation
(DOC-002, 2026-04-20) handled one cluster; the system that prevents the next
cluster from re-accreting did not ship.

## Problem statement

`docs/` has grown from 66 to 143 top-level Markdown files in five months. The
growth is real work product (eval reports, RFCs, runbooks, decision logs), but
the directory has no:

1. **Classification** — no way to tell from a filename whether a doc is
   canonical reference, transient session log, superseded redirect, or
   archive-candidate.
2. **Lifecycle rules** — when a workstream finishes, nothing forces its docs
   to be archived.
3. **Inbound-link integrity** — the mdBook link checker covers nav chapters
   only; a doc can be orphaned without CI noticing.
4. **Generation pressure** — ROADMAP sections, gap tables, and eval indexes
   are hand-maintained, so every gap-shipping PR rewrites doc prose, which
   dominates merge conflicts in `docs/gaps.yaml` and ROADMAP.

The result: every cleanup PR is ad-hoc judgment, no two agents classify the
same file the same way, and the directory accretes faster than gardening
removes.

## Phases

### Phase 0 — Classify (the prerequisite)

Every `docs/*.md` (top-level only; subdirectories already have implicit
classification via path) gets YAML front-matter with one tag from this set:

| Tag | Meaning | Lifecycle |
|---|---|---|
| `canonical` | Single source of truth for a domain. ROADMAP, FINDINGS, AGENTS, RESEARCH_INTEGRITY, MEMORY (root). | Permanent. Edited in place. |
| `decision-record` | ADR / RFC / design proposal. Immutable once accepted; supersession noted in successor. | Permanent. New decisions get new files. |
| `runbook` | How-to / operational guide. | Permanent until the procedure goes away. |
| `log` | Append-only session log, eval review log, market evidence log. | Rotated to `archive/YYYY-MM/` after 90 days of inactivity. |
| `redirect` | "Moved" stub pointing to a renamed canonical doc. | Deleted once all inbound refs are scrubbed (target window: 30 days from creation). |
| `archive-candidate` | Workstream complete, doc no longer load-bearing. | Moved to `archive/YYYY-MM/` in next gardener pass. |

Front-matter format:

```yaml
---
doc_tag: canonical
owner_gap: ROADMAP            # optional; gap or workstream this doc belongs to
last_audited: 2026-04-25
---
```

Why front-matter and not a separate manifest: the tag travels with the file,
survives renames, and is greppable. A separate manifest is a coordination
hazard the gap-claim system already taught us about.

### Phase 1 — Inventory

One-time script (`scripts/doc-inventory.py`) writes
`docs/_inventory.csv` with:

| Column | Source |
|---|---|
| path | filesystem |
| tag | front-matter |
| owner_gap | front-matter |
| last_modified | `git log -1 --format=%cI -- <file>` |
| inbound_refs | grep across `docs/`, `book/src/`, `src/`, `scripts/`, `.github/`, `tests/` |
| line_count | `wc -l` |
| last_audited | front-matter |

The CSV is checked in. Subsequent runs diff against it to flag drift (new
untagged file, doc that lost all inbound refs and is a candidate for archive).

### Phase 2 — Automation

1. **Pre-commit guard** (`scripts/git-hooks/pre-commit` extension):
   refuse a new top-level `docs/*.md` without `doc_tag` front-matter. Bypass
   `CHUMP_DOC_TAG_CHECK=0` for emergencies. Mirrors the
   gaps.yaml-discipline pattern — the cost of skipping is loud.
2. **CI link integrity** (extend `scripts/mdbook-linkcheck.py` or add a
   sibling): for every `docs/*.md`, walk inbound refs across the repo. Block
   PRs that delete or move a doc without scrubbing the references.
3. **Gardener subcommand** (`chump doc-archive`): for each
   `archive-candidate`, move to `docs/archive/YYYY-MM/<file>` and rewrite
   inbound refs in one atomic commit. Daily gardener cycle (per
   `project_doc_infrastructure.md` memory) calls this.

### Phase 3 — Staged consolidation

Cleanup happens in cluster-scoped batches, each its own PR with its own
sub-gap. Initial cluster list (from the inventory CSV — refine after Phase 1):

| Cluster | Estimated files | Sub-gap |
|---|---|---|
| Cursor / fleet protocol stubs (CHUMP_CURSOR_PROTOCOL, CURSOR_CLI_INTEGRATION → CHUMP_CURSOR_FLEET) | 3–5 | DOC-006 |
| mistral.rs split docs (consolidated into MISTRALRS.md but redirects + ADR-002 empty stub remain) | 4–6 | DOC-007 |
| Eval session logs older than 90 days | ~10 | DOC-008 |
| Superseded research briefs (CHUMP_PROJECT_BRIEF / CHUMP_RESEARCH_BRIEF post-RESEARCH_INTEGRITY) | 2–3 | DOC-009 |

Each sub-gap follows the same shape: scrub inbound refs, archive or delete,
update inventory CSV, ship.

### Phase 4 — Generated docs

Largest source of merge churn in `docs/` is hand-maintained tables that
duplicate `state.db` (or `gaps.yaml`) content. Replace with generation:

| Doc | Currently | After |
|---|---|---|
| `docs/ROADMAP.md` open-gaps section | hand-edited | `chump gap list --status open --format roadmap-md` regenerated by gardener |
| `docs/eval/index.md` (if it exists post-Phase 3) | hand-edited | generated from `docs/eval/*.md` front-matter |
| FINDINGS.md aggregate table | hand-edited | generated from per-eval JSONL + Wilson CI helper |

Generation closes the loop: gap shipping no longer touches multiple docs,
which removes the largest pre-commit-conflict surface.

## Acceptance criteria (this gap = DOC-005)

- [ ] This plan committed at `docs/DOC_HYGIENE_PLAN.md` with phase definitions
- [ ] DOC-005 gap entry in `docs/gaps.yaml` pointing to this plan
- [ ] `RED_LETTER.md` updated to reference this plan and remove the stale
      "915 unwraps" bullet (production unwraps already 0 per QUALITY-001/002/003)
- [ ] Phase 0 sub-gap (DOC-006: classify all top-level docs) filed but
      not necessarily started in this PR

Phases 1–4 are out of scope for this PR. Each phase = its own gap, shipped
in its own PR, against the inventory and rules established here.

## Why this shape

- **Classification before deletion**: DOC-002 (2026-04-20) was a one-shot
  consolidation that worked but didn't leave behind a system. Five months
  later we are doing it again. Front-matter is the smallest mechanism that
  prevents the next re-accretion.
- **Front-matter, not manifest**: a separate `docs/_classification.yaml` is
  a merge-conflict generator (every doc edit touches two files). YAML
  front-matter travels with the file.
- **Phase 4 last**: generation is the highest-leverage step but requires
  Phase 0 + 2 to be safe. Generating against unclassified, unaudited docs
  produces wrong output.
- **Daily gardener already exists**: this plan adds subcommands to
  infrastructure already running, rather than spinning up a new daemon.

## Out of scope

- `docs/archive/` reorganization (already structured by month).
- Subdirectory docs (`docs/eval/`, `docs/rfcs/`, etc.) — they have implicit
  classification via path. Phase 1 inventory will surface any that need
  surfacing.
- Generated docs in `book/src/` — owned by the mdBook sync workflow already.
- The unwrap audit. Verified 2026-04-25: 0 production unwraps remain;
  914 in test code is idiomatic Rust. RED_LETTER.md will be updated.

## Cross-references

- `docs/RED_LETTER.md` — source of the "143 docs" critique
- `memory/project_doc_infrastructure.md` — daily gardener / hourly tech
  writer / on-demand journalist roles
- `docs/MD_BOOK_PUBLISH_SURFACE.md` — current sync rules between
  `docs/` and `book/src/`
- `docs/WORLD_CLASS_ROADMAP.md` M5 — "metrics + auto-route by gap class" —
  doc hygiene metrics (untagged-doc count, orphan-ref count) belong on
  that dashboard
