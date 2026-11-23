# THE PATH — the 5-track ranked program

**Author:** Oracle (orchestrator-opus session). **Updated:** 2026-11-23 17:20Z.
**Refresh cadence:** every 3-4 hours by the Oracle role, or on major-track shift.

This document is the **single ranked source-of-truth** for what the fleet should be shipping. It exists because `chump gap list --status open` returns a 192-gap firehose — fine for raw inventory, useless for direction. A curator or JIT scheduler picking from the firehose has no way to know what *paves the road* versus what is noise.

## How to read this doc

- **5 tracks** — every shippable gap belongs to one. If it doesn't fit a track, it's noise (demote or close).
- **Each track lists "Next 3-5 actions"** — these are the gaps to claim next. They're ordered by impact-per-effort. Curators should prefer picking from these lists over the raw open queue.
- **Tracks themselves are ranked top to bottom** — Track 1 = highest current leverage; Track 5 = lowest. When in doubt, work the higher track.
- **State.db priority should converge here.** If a gap is listed as a next-action here but isn't P0/P1 in state.db, that's drift — Oracle's job to fix on next sweep.

## How JIT (INFRA-1892) consumes this

When a curator emits `DONE`, the JIT scheduler:
1. Reads this doc (parses track sections + next-action gap IDs).
2. Picks the highest-track gap whose lane matches the curator's last-N shipped gaps' pillar fingerprint.
3. Broadcasts assignment via `broadcast.sh --to <session> WARN`.

Without this doc, JIT would just pick "next open P0/P1" — which doesn't correspond to the road we're paving.

---

## Track 1 — META-070 firewall completion (95% done)

**Theme:** every deterministic CI gate has a local `chump preflight` mirror. Goal: push-then-CI-fail rate drops below 5%.

**Why #1:** the firewall is the substrate. Without it, every PR is a CI roulette and the queue clogs. This track has shipped the most today (INFRA-1831, 1833, 1834, 1836, 1838, 1860, 1879, 1852) and is one ship-cluster from "done." Close it out, then it stops needing attention.

**Next actions (claim from top down):**
1. **INFRA-1788** — preflight docs-delta-trailer gate (Tier C #2, unclaimed)
2. **INFRA-1790** — preflight markdown-intra-doc-links gate (Tier C #4, unclaimed — original PR closed for fresh restart)
3. **INFRA-1792** — preflight pr-scope sanity gate (Tier C #6, unclaimed)
4. **INFRA-1793** — preflight no-claude-leak gate (Tier C #7, unclaimed)
5. ~~INFRA-1794~~ — broad-canary-coverage (P3, defer — diminishing return)

**Done when:** all 4 above shipped. Then this track moves into maintenance.

## Track 2 — Oracle/JIT self-improvement

**Theme:** stop using Opus for scheduler work. Make the orchestration loop itself a daemon so the planet handles only architectural judgment.

**Why #2:** every iter of the loop today burns ~5 min of Opus context doing pebble-shaped JIT work. Once shipped, frees Opus for actual road-paving (this doc) and architectural meta-fixes.

**Next actions:**
1. **INFRA-1892** — curator-jit-scheduler daemon (just filed, dispatched to handoff/shepherd)
2. **INFRA-1860 / INFRA-1879** — PostToolUse inbox poll + 5-path session derivation (both shipped or in-flight — verify in main, no further action)
3. **INFRA-1880** — auto-export `CHUMP_SESSION_ID` at curator launch (filed P1, unclaimed)

**Done when:** orchestrator-opus stops manually broadcasting next-gap assignments. Operator says "I haven't seen you dispatch in 2 hours."

## Track 3 — META-073 Initiative #2 (forward-looking coordination)

**Theme:** predict collision, route by skill, propagate lessons.

**Why #3:** the A2A coordination wiring that lets the fleet self-organize beyond the cascade-drain loop. Pairs with Track 2 — once JIT exists, it needs collision-prediction + skill-routing to assign WELL, not just FAST.

**Next actions:**
1. **CREDIBLE-1459** — gap done-checks (P1, unclaimed — critical for fleet reliability)
2. **CREDIBLE-1493** — point eval harness inward (P2, unclaimed — 3x calibration failures in last 24h)
3. **INFRA-1862** — world-class A2A coordination (P2, unclaimed — 12 gaps in queue)

## Track 4 — A2A coordination (agent-to-agent)

**Theme:** the fleet's ability to self-organize beyond the cascade-drain loop.

**Why #4:** the A2A coordination wiring that lets the fleet self-organize beyond the cascade-drain loop. Pairs with Track 2 — once JIT exists, it needs collision-prediction + skill-routing to assign WELL, not just FAST.

**Next actions:**
1. **INFRA-1862** — world-class A2A coordination (P2, unclaimed — 12 gaps in queue)
2. **CREDIBLE-1459** — gap done-checks (P1, unclaimed — critical for fleet reliability)
3. **CREDIBLE-1493** — point eval harness inward (P2, unclaimed — 3x calibration failures in last 24h)

## Track 5 — Demo (road-paving)

**Theme:** the fleet's ability to self-organize beyond the cascade-drain loop.

**Why #5:** the A2A coordination wiring that lets the fleet self-organize beyond the cascade-drain loop. Pairs with Track 2 — once JIT exists, it needs collision-prediction + skill-routing to assign WELL, not just FAST.

**Next actions:**
1. **PRODUCT-142** — build 6-page Chump Product Suite (P2, unclaimed — 2026-11-23 PR #5892)
2. **MISSION-010** — finish Universal Chump v1.0 (P2, unclaimed — 2026-11-23 PR #5889)
3. **CREDIBLE-004** — add tests for 4 critical untested files (P2, unclaimed — 10430 LOC with zero tests)
