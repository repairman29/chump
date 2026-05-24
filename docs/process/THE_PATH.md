# THE PATH — the 5-track ranked program

**Author:** Oracle (orchestrator-opus session). **Updated:** 2026-05-23 23:10Z.
**Refresh cadence:** every 3-4 hours by the Oracle role, or on major-track shift.

This document is the **single ranked source-of-truth** for what the fleet
should be shipping. It exists because `chump gap list --status open` returns
a 192-gap firehose — fine for raw inventory, useless for direction. A curator
or JIT scheduler picking from the firehose has no way to know what *paves
the road* versus what is noise.

## How to read this doc

- **5 tracks** — every shippable gap belongs to one. If it doesn't fit a
  track, it's noise (demote or close).
- **Each track lists "Next 3-5 actions"** — these are the gaps to claim
  next. They're ordered by impact-per-effort. Curators should prefer
  picking from these lists over the raw open queue.
- **Tracks themselves are ranked top to bottom** — Track 1 = highest
  current leverage; Track 5 = lowest. When in doubt, work the higher track.
- **State.db priority should converge here.** If a gap is listed as a
  next-action here but isn't P0/P1 in state.db, that's drift — Oracle's
  job to fix on next sweep.

## How JIT (INFRA-1892) consumes this

When a curator emits `DONE`, the JIT scheduler:
1. Reads this doc (parses track sections + next-action gap IDs).
2. Picks the highest-track gap whose lane matches the curator's last-N
   shipped gaps' pillar fingerprint.
3. Broadcasts assignment via `broadcast.sh --to <session> WARN`.

Without this doc, JIT would just pick "next open P0/P1" — which doesn't
correspond to the road we're paving.

---

## Track 1 — META-070 firewall completion (95% done)

**Theme:** every deterministic CI gate has a local `chump preflight` mirror.
Goal: push-then-CI-fail rate drops below 5%.

**Why #1:** the firewall is the substrate. Without it, every PR is a CI
roulette and the queue clogs. This track has shipped the most today
(INFRA-1831, 1833, 1834, 1836, 1838, 1860, 1879, 1852) and is one ship-
cluster from "done." Close it out, then it stops needing attention.

**Next actions (claim from top down):**
1. **INFRA-1788** — preflight docs-delta-trailer gate (Tier C #2, unclaimed)
2. **INFRA-1790** — preflight markdown-intra-doc-links gate (Tier C #4, unclaimed — original PR closed for fresh restart)
3. **INFRA-1792** — preflight pr-scope sanity gate (Tier C #6, unclaimed)
4. **INFRA-1793** — preflight no-claude-leak gate (Tier C #7, unclaimed)
5. ~~INFRA-1794~~ — broad-canary-coverage (P3, defer — diminishing return)

**Done when:** all 4 above shipped. Then this track moves into maintenance.

## Track 2 — Oracle/JIT self-improvement

**Theme:** stop using Opus for scheduler work. Make the orchestration loop
itself a daemon so the planet handles only architectural judgment.

**Why #2:** every iter of the loop today burns ~5 min of Opus context
doing pebble-shaped JIT work. Once shipped, frees Opus for actual road-
paving (this doc) and architectural meta-fixes.

**Next actions:**
1. **INFRA-1892** — curator-jit-scheduler daemon (just filed, dispatched to handoff/shepherd)
2. **INFRA-1860 / INFRA-1879** — PostToolUse inbox poll + 5-path session
   derivation (both shipped or in-flight — verify in main, no further action)
3. **INFRA-1880** — auto-export `CHUMP_SESSION_ID` at curator launch (filed P1, unclaimed)

**Done when:** orchestrator-opus stops manually broadcasting next-gap
assignments. Operator says "I haven't seen you dispatch in 2 hours."

## Track 3 — META-073 Initiative #2 (forward-looking coordination)

**Theme:** predict collision, route by skill, propagate lessons.

**Why #3:** the A2A coordination wiring that lets the fleet self-organize
beyond the cascade-drain loop. Pairs with Track 2 — once JIT exists, it
needs collision-prediction + skill-routing to assign WELL, not just FAST.

**Next actions:**
1. ~~INFRA-1764 / INFRA-1862~~ — skill-typed claims / world-class A2A
   coordination mesh (filed, look at what's there)
2. **META-075** — collision prediction event schema (just shipped via #2451)
3. **META-085** — shepherd loop playbook Phase 0 (just shipped via #2452)
4. **NEXT** — skill-aware routing + lesson-propagation sub-tracks
   (decompose ci-audit's META-073 children if not yet generated)

**Done when:** the fleet's next cascade self-routes work to capability-
matched curators without operator dispatch.

## Track 4 — META-061 A2A coordination real-impl

**Theme:** the 6 A2A layers (Layer 1a delivery, Layer 2b RPC, Layer 2c
manifest, Layer 3d scratchpad, Layer 3e deliberation, Layer 4f provenance)
all have STUBS shipped today but no REAL implementations. Stubs are
type-stable scaffolding; real impls actually deliver.

**Why #4:** big upside but bigger effort. Each layer is m-l effort. Best
worked one-at-a-time as Track 2 + Track 3 mature.

**Next actions (one at a time, lowest to highest dependency):**
1. **INFRA-1120** — Layer 2c capability manifest real impl (INFRA-1825
   stub shipped; this is the file-backed v0)
2. **INFRA-1121** — Layer 3d scratchpad real impl (INFRA-1826 file-backed)
3. **INFRA-1118** — Layer 1a NATS-primary delivery (after Track 2-3 give
   us real test coverage)
4. **INFRA-1119** — Layer 2b RPC (Layer 1a dependency)
5. **INFRA-1122** — Layer 3e deliberation (after Layer 3d)
6. **INFRA-1123** — Layer 4f provenance (last)

**Done when:** all 6 layers have real impls + the file-fallback removed
in favor of NATS-primary.

## Track 5 — META-067 demo polish (Track 3 evidence)

**Theme:** turn today's autonomy cascade into a sellable demo asset.

**Why #5:** lowest current operational impact but highest commercial
upside once #1-3 are mature. The road has to be paved before we run the
demo on it.

**Next actions:**
1. **DOC-052** — autonomy cascade writeup (shipped via #2427 by handoff)
2. **META-072** — demo loop CLI (shipped via #2445 by handoff)
3. **DOC-053** — DEMO_5MIN.md walkthrough (shipped via #2452 by ci-audit)
4. **INFRA-1894** — chump-dashboard-tui.sh one-shot terminal dashboard
   (filed META, unclaimed — the visual hook for the demo)
5. **NEXT** — Loom/asciinema recording of the demo + Marcus design review

**Done when:** Marcus has reviewed; we have one external party who has
seen the demo and given feedback.

---

## What's NOT on the path (de-prioritize)

These pillars are bloated and need triage:
- **EFFECTIVE: 58 P0/P1** — most are stale grand visions. Demote anything
  not in Tracks 1-5. Operator goal: reduce to <15.
- **RESILIENT: 63 P0/P1** — same. Demote or close as superseded by today's
  firewall ships. Operator goal: reduce to <20.

Pre-product MISSION gaps (launch playbook, pricing, license — INFRA-1500+)
are valid but pre-first-customer. Park at P2 until Tracks 1-3 mature
enough to justify going-public motion.

## Oracle next sweep

Next contemplation: **2026-05-24 03:00Z** (3-4 hours from now). Sooner if:
- A new track-shifting gap lands (e.g. operator pivots strategy)
- The pillar starve alert fires (any track's "Next actions" list goes to 0)
- A cascade keystone surfaces (back to firefighting mode)
