# docs/gaps/ — retired (ZERO-WASTE-020, 2026-07-19)

This directory used to hold one YAML mirror per gap (`docs/gaps/<ID>.yaml`,
plus a `closed/` archive subdirectory for done gaps). Those per-file
mirrors are **retired**. This README and the `TEMPLATES/` subdirectory
(pillar gap-filing templates, unrelated to per-gap mirrors — see
`chump gap template --pillar <P>`) are the only things that should live
here now.

## What's canonical now

- **`.chump/state.db`** — the canonical gap registry (SQLite). Not tracked in
  git (machine-local, gitignored). Every `chump gap ...` command reads/writes
  here directly.
- **`.chump/state.sql`** — the tracked, versioned dump of `state.db`. This is
  what gives the registry git history now that per-gap YAML files are gone.
  It has its own git merge driver
  (`scripts/git/merge-driver-state-sql-regen.sh`, INFRA-310) that regenerates
  it from `state.db` on conflict instead of attempting a textual 3-way merge.

## Why the mirrors were retired

Per-file YAML mirrors (`docs/gaps/<ID>.yaml`) were optional since INFRA-760
(state.db already canonical for the briefing-prompt path) but stayed a live
write path via `chump gap reserve/set/ship --update-yaml` and `decompose`.
In practice they generated pure harm and no benefit:

- **False hijack blocks** — pre-commit's title/AC-divergence guards fired on
  cosmetic YAML quote-style churn (CREDIBLE-153).
- **Import wedges** — duplicate `evidence` fields and other YAML-vs-DB drift
  wedged `chump gap import` (20 files fixed in a single pass, PR #3206).
- **Prereg-gate friction** — the RESEARCH-019 preregistration guard fires on
  any staged `docs/gaps/*.yaml`, including files untouched by the actual
  change.
- **Pull-clobber fights** — two agents mutating the same gap raced on two
  representations of the same fact (state.db row vs. YAML file) instead of
  one.

Full context: `docs/design/GROUND_UP_2026-07-19.md` (ground-up step 3).

## How to work with gaps now

```bash
chump gap show <GAP-ID>              # human-readable single-gap view (reads state.db)
chump gap list --status open         # canonical query surface
chump gap set <GAP-ID> --notes "..." # mutate — writes state.db only, no YAML
chump gap dump --out .chump/state.sql   # regenerate the tracked dump after a
                                         # registry-touching change, before commit
```

`chump gap dump --per-file --out-dir <dir>` still exists for anyone who wants
an ad-hoc offline-browsable YAML export to a scratch directory — it is no
longer wired into `reserve`/`set`/`ship`/`decompose`, so nothing recreates
`docs/gaps/<ID>.yaml` automatically. Do not point `--out-dir` at this
directory; if you need to browse gaps as files, export to a scratch path
outside version control.

## Recovering a single gap's history

The per-file YAML mirrors existed in git history up through the commit that
retired them (search `git log --oneline -- docs/gaps/<ID>.yaml` from before
this tombstone landed — the file's blame stops at the ZERO-WASTE-020 deletion
commit). After that point, a gap's history lives in two places:

1. **`.chump/state.sql` diffs** — `git log -p -- .chump/state.sql` and grep
   for the gap ID; each commit that touched the dump shows the gap's
   YAML-shaped block as it stood at that point (the dump format is
   unchanged — full YAML records, just monolithic instead of per-file).
2. **The final per-file commit** — the last commit under
   `git log --oneline -- docs/gaps/<ID>.yaml` (before the mass deletion) has
   the file's full content at `git show <sha>:docs/gaps/<ID>.yaml`.

Combine both: `git show <last-per-file-sha>:docs/gaps/<ID>.yaml` for the
pre-retirement snapshot, then `git log -p -- .chump/state.sql | grep -A30
"id: <GAP-ID>"` for everything since.
