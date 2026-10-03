# Mission Driver — every session, not just when asked

Moved out of `CLAUDE.md` by ZERO-WASTE-125 (rulebook line-budget cut).

You are responsible for **driving the 4 pillars**, not just servicing gaps
as they appear. The fleet defaults to filing gaps about itself (because
that's what's easy to notice) — Resilient and Zero-Waste pile up while
Effective and Credible starve. Counteract that on purpose.

**At session start AND every iter of any loop:**

1. **Pillar inventory.** Count fleet-pickable gaps per pillar (INFRA P0|P1
   xs|s|m, no deps). Quick scan via title prefix tags `EFFECTIVE:` /
   `CREDIBLE:` / `RESILIENT:` / `ZERO-WASTE:` / `MISSION:`.
2. **Balance lever — surface, do NOT manufacture (anti-bloat, 2026-07-26).**
   Pillar imbalance is a **metric**, not a work order. It is already
   surfaced by `chump fleet brief` + `fleet_health.pillars_starved`. **Do
   NOT "file 1-2 gaps to refill a starved pillar"** — that instruction
   manufactured 146 self-referential "pillar starved" gaps (filed as
   INFRA, which never refill the *named* pillar) and was the #1 driver of
   the 2026-07-26 gap-bankruptcy (1,214 → 25). A pillar refills by
   pointing the fleet at a real **outcome** whose work happens to be that
   pillar — not by conjuring gaps to hit a count.
3. **Every P0/P1 gap must trace to an outcome (MISSION-045).**
   `chump gap reserve --priority P0|P1` **requires `--outcome <id>`** (a
   row in the outcomes table; `chump outcome list`) and refuses without
   it. Bypass (audited): `--no-outcome-required` or
   `CHUMP_GAP_RESERVE_NO_OUTCOME=1`. P2/P3 stay permissionless for
   exploration. Title-tag every new gap with the pillar prefix.
4. **P0 budget = 5 max.** Reserve P0 for true unblockers across all 4
   pillars; demote inflation.
5. **Roadmap-before-gaps.** When unsure what to file, re-read
   `docs/ROADMAP.md` first. Gaps implement the roadmap, not the other way
   around.
6. **Don't optimize the engine while the car sits in the driveway.**
   Reject yet-another fleet-meta gap when the queue already has
   Resilient/Zero-Waste covered. Bias toward Effective (user-facing) and
   Credible (measurement) when fleet plumbing is healthy.
7. **Rate surprising outcomes.** After ship, rate the gap with
   `chump gap rate <ID> <1-5>` — the picker uses class-aggregate ratings
   to bias future selection. Low-rated classes (mean < 2.5, min 2
   samples) are demoted one priority tier in tie-breaks.

PM-curation role: see **META-046**. Honest pillar-grade reports are part
of the job, not an aside.

Explicit SLO targets: [`docs/process/FLEET_SLOS.md`](./FLEET_SLOS.md).
Check current vs. target: `chump health --slo-check` (exits non-zero on breach).
