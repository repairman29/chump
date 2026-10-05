---
doc_tag: design-decision
last_audited: 2026-08-16
audience: operator, external-collab, fleet engineers
purpose: Resolve the PWA-cockpit-vs-fleet-scrubber consensus question (INFRA-2294) — chosen architecture, migration plan, data-shape changes, routing strategy.
implements: INFRA-2294
status: draft v0 — operator sign-off pending; sub-gaps filed, not yet claimable
---

# Cockpit + Scrubber Unification — decision doc

> Filed under INFRA-2294. Routed via `FEEDBACK kind=proposal subject=cockpit-scrubber-unification`
> (broadcast 2026-05-30T16:01Z) plus the mission-lens amendment
> (`cockpit-mission-lens-amendment`, 2026-05-30T16:04Z).

## Consensus status (honest accounting)

The gap's AC calls for `scripts/coord/feedback-report.sh --corr-id cockpit-scrubber-unification`
to show a tallied A/B/C vote distribution and a `kind=consensus_resolved` event from the
deliberator. As of this write-up:

- `feedback-report.sh` has no `--corr-id` filter (only `--window`/`--json`) — it reports
  domain-level rollups, not per-proposal tallies.
- No `FEEDBACK kind=vote` events for either `cockpit-scrubber-unification` or
  `cockpit-mission-lens-amendment` are present in `.chump-locks/ambient.jsonl` or `.chump/state.sql`
  in this worktree's visible history — i.e. the quorum-of-5 curator vote never landed a
  recorded tally.
- `chump vote` itself reports `feature flag off, vote not emitted` in this environment.

Per the A2A roadmap precedent (`docs/design/A2A_ROADMAP.md`, status `draft v0 — operator
sign-off pending; sub-gaps not yet filed`), a design doc without a fully closed governance
loop is a valid, previously-used shipping state. This doc follows that precedent: it is a
**reasoned synthesis against the decisive factors the proposal itself specified**, written by
the curator that picked up INFRA-2294, offered for operator sign-off rather than
self-certified as consensus. It does **not** claim a fabricated A/B/C tally. If/when the
quorum vote actually lands (deliberator emits `kind=consensus_result` for the two corr_ids),
this doc should be revised to cite it and the "Consensus status" section replaced.

## Recap: the two existing artifacts

| | PWA cockpit (PRODUCT-122) | fleet-scrubber (INFRA-2164) |
|---|---|---|
| URL | `localhost:3737/v2/?view=cockpit` | `localhost:7070/scrubber/` |
| Shape | 5-zone grid: attention queue, inbox, daily-brief, fleet-roster, ambient-tail, quick-actions | D3 gantt timeline of segments |
| Backend | `/api/fleet-status`, `/api/ambient/stream` SSE (PWA server) | `chump-fleet-server` (`crates/chump-fleet-server`), separate process/DB (`agent_segments` table) |
| Strength | Operational — "what needs me now" | Forensic replay — "what happened, in order, across sessions" |
| Weakness | No timeline/replay view | Flat session-id soup; no role hierarchy; `gap_id` column exists but is unpopulated (0/235 segments carry it) |

## Mission-lens amendment: now unblocked

The 2026-05-30 amendment held that the A/B/C vote was premature — the *first* question is
which lens organizes the fleet (Mission / Gap / Session), because that answer constrains
which of A/B/C makes sense. It named two blockers: **INFRA-2247** (Mission type shapes in
`chump-coord`) and **CREDIBLE-071** (`chump cos digest` / Mission Yield). Both are now
`status: done` (INFRA-2247 closed via PR #2831 on 2026-05-30; CREDIBLE-071 closed via PR
#2256). Mission is now a queryable primitive (`crates/chump-coord/src/mission/`), not just a
title-prefix convention — the amendment's stated precondition for locking in a design is
satisfied.

## Decision: Option C — one artifact, two presentations, Mission as primary lens

**Chosen: C.** Single PWA codebase; `?view=cockpit` (operational, default) and
`?view=scrubber` (forensic gantt, full-bleed) as query-param presentations of the same
underlying session/segment data model, with **Mission** — not raw session-id — as the
primary grouping key surfaced in both views.

### Why C over A and B, against the proposal's four decisive factors

1. **Single-URL operator desire** — operator's own framing ("does the PWA need to be the
   end-all be-all? are there two tools?") reads as skepticism of *forced* consolidation, not
   an endorsement of two permanently separate URLs. C gives one deep-linkable origin
   (`localhost:3737/v2/`) while keeping the forensic view's layout (full-bleed gantt) free of
   the cockpit chrome tax that pure-A (embed-as-drill-down) would impose on every visit.
2. **Forensic-vs-operational perf** — A's "embed gantt in ambient-tail" would load D3 +
   segment data on every cockpit visit even when nobody needs forensic replay; that's the
   documented con for A in the original proposal, and it's correct. C's query-param routing
   keeps the gantt bundle on a separate code-split chunk, loaded only when
   `?view=scrubber` is requested — zero perf tax on the default operational view.
3. **Component dup cost** — B keeps them fully separate (own components, own backend), which
   is the status quo's actual problem: `cockpit.js` (54KB) and the D3 gantt in
   `web/fleet-scrubber/index.html` already duplicate session-list rendering, and every future
   role/mission field has to be wired twice. C shares the data-fetch layer and the
   session/segment rendering primitives; only the timeline-specific D3 code is
   view-exclusive.
4. **BEAST-MODE / mission integration path** — MISSION-010 is the load-bearing mission of
   record. A Mission-first lens needs one navigable surface where "what is Mission X doing
   right now" (operational) and "how did Mission X's work actually unfold" (forensic) are the
   same drill-down, not two different tools with two different backends to keep in sync. C is
   the only option where that drill-down is a client-side view swap instead of a cross-origin
   navigation.

**Why not keep B (status quo, cross-linked):** B was evaluated seriously — its "perf-optimized
per use case" pro is real, and C's routing/design-discipline burden (the proposal's stated con
for C) is not free. But B leaves two backends (PWA server's `/api/fleet-status` and
`chump-fleet-server`'s SQLite) as separate sources of truth for the same underlying session
data, which is exactly the kind of drift the Credible pillar exists to prevent — two dashboards
that can silently disagree about what a session is doing. C forces one source of truth by
construction.

## Sub-question: role-grouping — carried, yes

The sub-question (4-tier role hierarchy: curators / sub-agents nested under spawning curator /
`claim-*` short-lived sessions / 1 operator session, vs. flat `session_id` list) is carried as
**yes**. It's a prerequisite for C regardless of the A/B/C outcome — a Mission-first or
role-aware fleet-roster needs the hierarchy to group by, and the flat list is the specific
weakness the proposal names for the scrubber today.

## Data-shape changes required

`crates/chump-fleet-server/src/db.rs` `agent_segments` table today:

```sql
CREATE TABLE IF NOT EXISTS agent_segments (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT NOT NULL,
    start_ts_ms  INTEGER NOT NULL,
    end_ts_ms    INTEGER,
    activity     TEXT NOT NULL,
    gap_id       TEXT,              -- column exists, 0/235 rows populated
    event_count  INTEGER NOT NULL DEFAULT 0,
    UNIQUE(session_id, start_ts_ms, activity)
);
```

Required additions (tracked in sub-gap (c) below):

- `role TEXT` — derived from `session_id` naming convention (`curator-opus-*`, `claim-*`,
  operator session, plain worker) at write time by the segmenter background task.
- `parent_session TEXT` — populated when a session is an `Agent`-tool sub-agent spawned by a
  curator session, enabling the nested tree the role-grouping sub-question calls for.
- `gap_id` population — the column already exists; the segmenter isn't threading it through.
  Backfill from `events.gap_id` (already NOT NULL DEFAULT '' on the `events` table) via a join
  on `session_id` + time-window overlap.

## Routing / URL strategy

- `localhost:3737/v2/?view=cockpit` — default, unchanged behavior for existing bookmarks
  (no `view` param also resolves to cockpit — no forced migration for existing links).
- `localhost:3737/v2/?view=scrubber` — full-bleed gantt, replaces `localhost:7070/scrubber/`
  as the canonical forensic URL.
- `localhost:3737/v2/?view=scrubber&mission=<id>` — deep-link into a single Mission's
  timeline, the concrete BEAST-MODE integration point from decisive factor 4.
- `localhost:7070/scrubber/` — kept as a redirect (302 to the `?view=scrubber` equivalent)
  for one deprecation window, then removed. `chump-fleet-server`'s HTTP surface stays as the
  data API (`/api/segments`, etc.); only the standalone HTML/D3 page at that origin is retired.

## Deprecation / migration plan for the losing artifact

Nothing is fully "losing" under C — both existing UIs contribute code, and the standalone
scrubber *page* (not its backend) is what's retired:

1. Sub-gap (b) ships the HUD strip and Mission-aware fleet-roster in the existing cockpit —
   no scrubber dependency, ships independently.
2. Sub-gap (a) ships role-grouping in `fleet-sidebar.js`, consumed by both views once (b)
   lands.
3. Sub-gap (c) ships the `agent_segments` schema additions + backfill.
4. A follow-up gap (filed once (a)-(c) land, not pre-filed per the two-phase decomposition
   rule) ports the D3 gantt rendering from `web/fleet-scrubber/index.html` into a
   `?view=scrubber` route in `web/v2/`, wired to the enriched segment data.
5. `localhost:7070/scrubber/` gets the redirect; `chump-fleet-server`'s standalone HTML is
   deleted once the redirect has been live for the deprecation window (operator call on
   window length — suggest 2 weeks, consistent with other deprecation precedent in this repo).

## Sub-gaps filed

- **(a)** [INFRA-3636](../gaps/) fleet-sidebar role-grouping (4-tier hierarchy)
- **(b)** [INFRA-3637](../gaps/) HUD metric strip (TRUNK / SHIP-RATE / WORKERS / ATTENTION / COST / TICKS / YOU)
- **(c)** [INFRA-3638](../gaps/) recorder segments enrichment (`role`, `parent_session`, `gap_id` backfill)

All three carry a note: **do not claim until this doc has operator sign-off** — per AC5,
sign-off is a gate on code landing, not on filing.

## Open items for operator sign-off

1. Confirm Option C over B — the B tradeoff (perf isolation) is real; sign-off should
   explicitly weigh it against the two-source-of-truth risk this doc argues against.
2. Confirm the deprecation window length for `localhost:7070/scrubber/` (suggested: 2 weeks).
3. Confirm role-grouping sub-question carry (yes/no) — this doc assumes yes as a C
   prerequisite.

## External-collab review (Marcus-facing impact)

**Reviewed 2026-08-16 by curator-opus-external-collab. Verdict: NO Marcus-facing impact.**

Checked `docs/PITCH.md`, `docs/HIDDEN_GEMS.md`, `docs/DEMO_5MIN.md` for any reference to
`cockpit`, `scrubber`, `localhost:3737`, or `localhost:7070` — zero matches across all three.
These docs describe product-surface claims and demo flow for Marcus (per
`docs/strategy/ROADMAP_MARCUS.md`); the PWA cockpit and fleet-scrubber are internal
operator/fleet-visualization tools, not product surface, and are not named in any customer-facing
artifact or demo script.

Option C's routing change (`?view=cockpit` default, `?view=scrubber` forensic, 2-week redirect
for `localhost:7070/scrubber/`) is invisible to Marcus — he never sees these URLs or tools.

No gap needed. No stale claims to flag. If a future revision of DEMO_5MIN.md or HIDDEN_GEMS.md
ever cites the cockpit/scrubber as a "look how we dogfood our own fleet" demo beat, that
addition would need to track the `?view=` routing introduced here — but no such reference
exists today.

Confidence: high (direct grep against all three canonical operator-facing docs, zero hits).
