---
doc_tag: synthesis
date: 2026-05-11
author: opus-4-7 (operator-delegated PM curation per META-046)
---

# Pillar audit — 2026-05-11

Snapshot of the 217 open gaps in `.chump/state.db` graded against the 4
pillars (RESILIENT, EFFECTIVE, CREDIBLE, ZERO-WASTE) plus MISSION.
Triggered by the session-start brief flagging that 22 of 30 recent ships
were `OTHER` pillar — the fleet was self-referential. This audit names
what is actually in the queue, who it serves, and what to demote.

## Headline

- **217 open gaps total**; 1 P0, 62 P1, 130 P2, 24 P3
- **95 gaps (44%) carry no pillar prefix in title** — biggest curation
  gap. Half the registry is invisible to operators scanning for "what
  pillar are we starving."
- **Pickable pool (P0/P1, xs/s/m)**: 56 gaps. EFFECTIVE dominates at 43%;
  CREDIBLE 18%, RESILIENT 13%, ZERO-WASTE 4%, MISSION 4%, untagged 20%.
- **No pillar is below the 2-pickable floor** mandated by CLAUDE.md.
- **P0 count = 1**, within the 5-budget.

## Pillar mix (all 217 open)

| Pillar | All | Pickable (P0/P1, xs/s/m) | Notes |
|---|---|---|---|
| EFFECTIVE | 51 (24%) | 24 (43% of pickable) | Healthy. Strong user-facing pipeline. |
| ZERO-WASTE | 26 (12%) | 2 (4%) | Many tagged but few pickable; mostly P2 cleanup. |
| CREDIBLE | 21 (10%) | 10 (18%) | Healthy after today's filings (CREDIBLE-025-029). |
| RESILIENT | 19 (9%) | 7 (13%) | Healthy. INFRA-819 + RESILIENT-006 boost from today. |
| MISSION | 5 (2%) | 2 (4%) | At the floor. META-045/046 the load-bearing two. |
| **OTHER (untagged)** | **95 (44%)** | **11 (20%)** | **Curation crisis.** |

## What was demoted in this audit

5 P1→P2 demotions. All were "UMBRELLA" or vague-orchestrator gaps with
no concrete next-action. Implementer-actionable work exists in their
sub-gaps; the umbrella itself was a P1 placeholder.

| Gap | Was | Now | Why |
|---|---|---|---|
| [META-030](../gaps/META-030.yaml) | P1/m | P2 | Backchannel abort signal is nice-to-have; preflight self-detect already prevents the worst case |
| [META-032](../gaps/META-032.yaml) | P1/s | P2 | COG-052 (AC audit-ac, shipped #1439) already covers the AC-lag detection use case |
| [META-038](../gaps/META-038.yaml) | P1/l | P2 | UMBRELLA coord-tax collapse — no atomic next step; decomposed work would file as new gaps |
| [META-039](../gaps/META-039.yaml) | P1/m | P2 | UMBRELLA learning loop — concrete measurement is META-045 (cognition-stack A/B) |
| [META-042](../gaps/META-042.yaml) | P1/l | P2 | UMBRELLA cull scripts/coord — no atomic next step |

## What was retagged with pillar prefix

7 P1 gaps that were doing pillar-relevant work but didn't advertise it.
Title-only edit; status, priority, AC unchanged.

| Gap | Pillar added | Why visible now |
|---|---|---|
| [INFRA-372](../gaps/INFRA-372.yaml) | EFFECTIVE | Anthropic prompt caching is a user-facing cost win |
| [INFRA-792](../gaps/INFRA-792.yaml) | RESILIENT | Wedged PR for 71m = CI reliability |
| [META-033](../gaps/META-033.yaml) | RESILIENT | System-invariants cron is the reaper-liveness/disk-headroom check |
| [META-043](../gaps/META-043.yaml) | CREDIBLE | "no measurement = no merge" gate is the credibility discipline |
| [PRODUCT-075](../gaps/PRODUCT-075.yaml) | RESILIENT | Agent-silent investigation is operational reliability |
| [CREDIBLE-015](../gaps/CREDIBLE-015.yaml) | CREDIBLE | ID already CREDIBLE-*; title prefix matches |
| [CREDIBLE-018](../gaps/CREDIBLE-018.yaml) | CREDIBLE | Same |

## What was NOT demoted but probably should be (operator decision)

3 FLEET-* gaps describing NATS migration:

- [FLEET-034](../gaps/FLEET-034.yaml) — `chump-coord assign` daemon (NATS push routing) — P1/l
- [FLEET-038](../gaps/FLEET-038.yaml) — Lease store migration to NATS KV (event-sourced + dual-write) — P1/l
- [FLEET-039](../gaps/FLEET-039.yaml) — Event-sourced gap store (JetStream + per-host read view) — P1/xl

These are large-effort and represent a single architectural bet (move
coordination to NATS). Per the fleet-vision memory the Pi-mesh /
model-splitting direction is intact, but the *path* to it isn't
necessarily NATS-first. **Recommendation**: keep one as P1 for the
near-term `assign` daemon (FLEET-034), demote the migration pair
(FLEET-038, FLEET-039) to P2 until the NATS commitment is concrete.
Operator confirms or overrides.

## The 95 untagged gaps

The biggest curation surface. Spot-checked sample shows:

- ~30 INFRA-* gaps that pre-date the title-prefix convention (April 2026).
  Many would tag as RESILIENT or ZERO-WASTE if retagged.
- ~20 PRODUCT-* gaps from the Champ-rename / ChumpAgent product work —
  most are EFFECTIVE.
- ~10 COG-* gaps on cognition-stack improvements — mostly CREDIBLE
  (measurement) once retagged.
- The rest: a long tail of DOC-, RESEARCH-, FLEET-* / SMOKE / FRONTIER.

A bulk retag pass is its own gap and should not block this audit's
shippable changes. Filed [META-054](../gaps/META-054.yaml) (next-free
when this PR lands) as the "retag the 95 untagged gaps" cleanup task.

## What this audit explicitly does NOT do

- Doesn't touch P2/P3 gaps. The pickable pool is the leverage point;
  the long-tail backlog is the operator's to curate over time.
- Doesn't close any gap. Demotion to P2 is the soft no; close is a
  harder call left to the operator + author.
- Doesn't change AC. Any gap whose AC was TODO-placeholder boilerplate
  was already covered by [COG-052](../gaps/COG-052.yaml) (audit-ac)
  and the always-file-with-AC memory.

## Followups

- Operator: run `chump gap audit-priorities --json` after this PR
  lands and confirm the P0/P1 mix matches what's wanted.
- Operator: decide on FLEET-038/039 demotion.
- Fleet: retag the 95 untagged gaps (filed as [META-054](../gaps/META-054.yaml)).
- Doc growth: this synthesis becomes the template for the next pillar
  audit. Run again whenever the OTHER-tagged share crosses 50% of pickable
  or any pillar drops below 2 pickable.
