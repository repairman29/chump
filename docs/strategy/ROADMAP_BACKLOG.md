# Roadmap Backlog — design-conversation items

> **What this is.** Items that wanted design conversation before going into the
> queue, decided 2026-05-16. Each item has a NOW-filed gap with full AC and a
> sequencing rationale. Build, defer, or kill — explicit per item, defended.
>
> **What this isn't.** A wish list. Every item here is either filed as a gap
> (link in the table) or formally killed with reason.

## Decision summary

| Backlog item | Decision | Gap | Sequencing |
|---|---|---|---|
| **Lessons effectiveness loop** (Wilson-twin decay + re-rate) | BUILD | [INFRA-1557](../gaps/INFRA-1557.yaml) P2/m | Depends on routing brain (TBD-INFRA-1545) shipping first |
| **Per-gap cost attribution + cheap→haiku routing** | FOLD into Marcus M-A | [INFRA-1486](../gaps/INFRA-1486.yaml) P0/m (extended) | Ships as $-dimension of the trust gate |
| **Brain graph visualization** (Cytoscape.js) | BUILD MINIMAL | [INFRA-1558](../gaps/INFRA-1558.yaml) P2/s | After Marcus M-B canonical demo |
| **Offline PWA** (IndexedDB + SWR) | DEFER to Q3 | [PRODUCT-138](../gaps/PRODUCT-138.yaml) P3/l | Post 50/hr stabilization |
| **First-run wizard browser parity** | BUILD | [PRODUCT-139](../gaps/PRODUCT-139.yaml) P1/m | After Marcus M-B lands |
| **SSE filter UI + bandit regret rendering** | PAIR-BUILD | [INFRA-1559](../gaps/INFRA-1559.yaml) P2/s | Pair with routing brain (TBD-1545) |
| **launchd-status + bypass audit CLI** | BUILD SMALL | [CREDIBLE-070](../gaps/CREDIBLE-070.yaml) P2/s | Pair with plist work (TBD-1546) |
| **SessionStart dispatch/cascade/funnel auto-digest** | BUILD LEAN (delta-only) | [EFFECTIVE-021](../gaps/EFFECTIVE-021.yaml) P3/xs | Pair with war-room hook (TBD-1547) |

## Three calls defended hard

### 1. Folded cost attribution into INFRA-1486, did not file standalone

The cross-cutting nature was real (cascade, cost_tracker, picker) BUT the
**ceiling-not-floor policy** is the same policy as Marcus's trust-gate. One
gap, one spec, one shipping moment. Filed as INFRA-1486 AC #11-13 with the
tier-default table:

| Effort | Tier default | Budget cap |
|---|---|---|
| xs | haiku | $0.50 |
| s | haiku → sonnet | $2 |
| m | sonnet | $5 |
| l | sonnet → opus | $20 |

Escalation on stall (no commit in N min OR same error 3×). Emits
`kind=agent_model_tier_escalated`.

### 2. Deferred offline PWA to Q3

The infra-is-product reframe (2026-05-16) made offline a tier-3 differentiator,
not the spine. PWA still gets a P3/l gap filed (PRODUCT-138) so the design
spec doesn't get lost: SWR read path, server-arbitrated writes (NOT LWW),
service worker cache-bust on ambient events, honest scope acknowledgment that
PWA without internet can't claim or open PRs. Park until post-50/hr.

### 3. Brain graph viz ships LAST

Most demo-friendly, **least customer-impactful**. Operators rarely use brain
graphs; agents use them programmatically. Build the API consumer (agent
routing brain) first; the renderer is dev-debugging. P2/s — small library
choice (Cytoscape over D3/vis.js) with strict scope guard (2D only, < 800 LOC).

## TBD placeholders to file when the conversation happens

Three gaps were referenced in the backlog as "pair with..." but don't exist
yet because they want their own design conversation:

- **TBD-INFRA-1545 — routing brain.** The bandit that picks agent tier × backend
  × machine per gap. Emits `routing_decision` + `routing_outcome` events that
  feed regret calc + lessons re-rate. *File when ready to commit to bandit choice
  (Thompson? UCB1? Contextual?) — likely after INFRA-1486 budgets ship.*
- **TBD-INFRA-1546 — launchd plist canonical refactor.** All chump launchd
  plists today are hand-edited. Refactor to a templated source-of-truth.
  Pair with CREDIBLE-070 status CLI.
- **TBD-INFRA-1547 — war-room hook.** A "deep operator dashboard" hook beyond
  SessionStart. Pair with EFFECTIVE-021 SessionStart digest.

When any of these is ready for design conversation, file with full AC and
update this doc.

## How this doc relates to the rest

```
docs/ROADMAP.md                       (30-day, broad)
docs/strategy/ROADMAP_MARCUS.md       (customer arc, 5 milestones)
docs/strategy/ROADMAP_50_PER_HOUR.md  (15-day throughput push)
docs/strategy/ROADMAP_BACKLOG.md      (this — design queue with decisions)
docs/strategy/NORTH_STAR.md           (mission)
```

Items move from this doc to one of the active roadmaps when they're ready to
execute. Items get killed (struck through here with rationale) when they no
longer serve a stated outcome.
