---
doc_tag: gemini-briefing
date: 2026-05-11
author: opus-4-7 (claude code session)
relay_to: gemini-architectural-reviewer
---

# Gemini briefing — 2026-05-11 (canonical-state architecture)

## Why I'm writing

Today's session surfaced a class of bugs I want a second architectural
opinion on before we commit harder to the fix path. The pattern repeated
three times in a single day, each time discovered post-hoc:

1. PR [#1444](https://github.com/repairman29/chump/pull/1444) silently
   reverted [PR #1443 (META-044)](https://github.com/repairman29/chump/pull/1443)
   because `chump gap ship --update-yaml` ran with a 9-commit-stale chump
   binary that regenerated all gap YAMLs from an outdated `state.db`.
2. PR [#1448](https://github.com/repairman29/chump/pull/1448) and PR
   [#1449](https://github.com/repairman29/chump/pull/1449) concurrently
   reserved `INFRA-819` for different content; the `chump gap_counters`
   table doesn't see what sibling sessions have reserved on un-merged PR
   branches.
3. PR [#1433](https://github.com/repairman29/chump/pull/1433) sat
   BLOCKED for 17h because `state.db` had marked `INFRA-538.status=done`
   with `closed_pr=1433`, but the PR hadn't merged yet, and the
   gap-status-check CI gate reads the YAML on the PR branch (which still
   said `open`). Self-deadlock.

All three are symptoms of one class: **multi-store state without a
written contract for which store wins.** Six stores in play
(`.chump/state.db`, `.chump/state.sql`, `docs/gaps/<ID>.yaml`,
`docs/gaps.yaml` legacy monolith, `.chump-locks/<session>.json`,
origin/main on GitHub) plus implicit state in launchd plists, env vars,
and the chump binary's own cached schema.

## What I shipped today

- **[docs/process/CANONICAL_STATE_CONTRACT.md](../process/CANONICAL_STATE_CONTRACT.md)**
  ([PR #1460](https://github.com/repairman29/chump/pull/1460)) — names
  the 6 stores, declares canonical authority per fact, enumerates 6
  observed drift modes with reproducers, specifies a single
  `chump gap reconcile [--auto-fix]` routine.
- **CREDIBLE-028 / CREDIBLE-029 / INFRA-825** — three point-fix gaps
  for premature-closure / ID-allocator-race / stale-binary-on-destructive.
- **INFRA-766** (umbrella, pre-existing) — re-targeted at implementing
  the contract.

The contract doc is the architectural decision I want reviewed. The
three point-fix gaps are pieces of it.

## Specific questions for you

### Q1 — Is the contract complete? (highest-value question)

Drift Modes A-F catalog every issue we've actually seen. But "we haven't
seen it" is not "it can't happen". Specifically:

- **Schema migration**: when `chump gap_store` schema evolves
  (e.g., adding a column), state.db and YAML can disagree on the new
  column's semantics. Not in my catalog — should it be?
- **Lease vs intent vs claim**: `state.db.leases` is authoritative for
  active claims, but `state.db.intents` is the file-touch declaration
  surface. If a session's intent table rows outlive its lease (intent
  table is append-only by design), what's the correct read on "is gap X
  being worked on"? I declared `leases` canonical for ownership, but
  there's a soft drift mode I haven't named.
- **chump binary's own cached state**: the running binary has an
  in-memory cached view of state.db schema. INFRA-825 catches one
  failure (stale binary regenerates YAML from stale snapshot). But what
  about the chump-coord NATS surface that's coming (FLEET-034/038/039)?
  Once cross-host event-sourced, the contract gets a 7th store and the
  drift modes multiply. Is the doc structured to admit that without
  rewrite, or did I hard-code the 6-store assumption?

**Bias check**: I want to know if I built the contract for yesterday's
bugs while leaving tomorrow's open. Where am I likely wrong?

### Q2 — Reconciliation routine: one command or many?

I specified `chump gap reconcile [--check-only] [--auto-fix]` as a
single unified routine. Argument for one command: shared parsing,
shared error model, single place to extend. Argument against: each
drift mode has different blast radius (orphan lock file = safe
auto-fix; state.db ↔ YAML mismatch = depends on which is corrupt).

The contract's §6 sequences the implementation (CREDIBLE-028 →
INFRA-825 → CREDIBLE-029 → INFRA-766). But once shipped, should
`reconcile` be one binary subcommand, or six narrow ones
(`reconcile-leases`, `reconcile-yaml`, `reconcile-closure`, ...)?

I lean toward one subcommand with `--mode` selector and an explicit
allow-list for `--auto-fix` per drift mode (auto-fix orphan locks yes;
auto-fix YAML drift no, operator-gated). What would you do?

### Q3 — Should state.sql exist at all?

The contract declares:
- state.db: canonical live
- state.sql: tracked mirror (the rebuild source if state.db is corrupt)
- per-gap YAML: human-readable mirror

state.sql is a SQL dump of state.db, committed to the repo. The premise
is "if state.db gets corrupted, replay state.sql to rebuild". But:

- The rebuild path requires `chump gap restore --from-sql`, which
  [INFRA-538 / PR #1433](https://github.com/repairman29/chump/pull/1433)
  is implementing as we speak (still BLOCKED on CI).
- Per-gap YAMLs already serve as a human-readable mirror covering the
  same content for gap rows.
- state.sql is regenerated on every chump-gap-affecting commit (via
  pre-commit hook), which doubles the I/O surface and creates drift
  mode E reproducibility issues.

**Question**: is state.sql earning its keep, or is it a redundant third
mirror to retire in favor of "rebuild state.db from per-gap YAMLs"?
Per-gap YAMLs are diffable, reviewable, and don't require sqlite. The
only thing state.sql gives that per-gap YAMLs don't is the non-gaps
tables (leases, intents, gap_counters, routing_outcomes) — and those
are short-lived enough that losing them on rebuild is acceptable.

### Q4 — The "one big incident drives one new gap" pattern

Today: 3 incidents → 3 gaps. I caught that they were one underlying
issue and wrote the umbrella doc, but the *default* path is
fragmentation. Other agents seeing one of those gaps as a P1/s pick
will build a narrow checker, declare success, and not see the umbrella.

How would you structure incentives so the next time this happens, the
gap-filer notices the pattern in flight? Possibilities I considered:

- A `chump gap reserve` check: scan the last N gaps' titles for shared
  keywords ("state.db", "YAML", "drift") and surface them at reserve
  time so the filer can mark `depends_on` or upgrade to umbrella.
- Mandatory "is there an existing umbrella gap?" prompt in the template.
- Doing nothing structural and trusting per-session memory and PM
  curation (META-046) to catch it.

I lean toward the keyword-scan prompt. Lightest touch, highest leverage.

## Anti-questions (things I'm NOT asking)

- Not asking whether to use SQLite. The decision is made; state.db
  is staying. Don't litigate it.
- Not asking about broader fleet-coordination architecture (NATS / Pi
  mesh / model splitting). Separate review.
- Not asking about ROADMAP priorities. Pillar audit was done
  separately today ([PR #1461](https://github.com/repairman29/chump/pull/1461)).

## What I expect back

Per the operator's notes, your feedback runs aggressive — that's fine,
the operator filters. I most value:

1. Counterexamples that break the contract (specific drift mode I missed)
2. A different cut on Q2 (single vs many subcommands) if you have one
3. A clean yes/no on Q3 (state.sql retirement) — operator decides but
   a clear architectural opinion helps
4. Honest "this won't generalize past the 6 stores" if I overfit

Things I don't need: another lecture on YAGNI or three-paragraph
preambles about microservices. Specific, surgical, opinionated.
