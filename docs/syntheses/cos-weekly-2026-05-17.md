---
doc_tag: weekly-digest
window: 2026-05-11 → 2026-05-17
last_audited: 2026-05-16
---

# Weekly digest — week of 2026-05-11

> **Format established.** First Mission Yield digest, hand-written by me-as-COS
> while the `chump cos digest` CLI is in flight (filed as part of this PR).
> Numbers are operator-truth where possible; estimates flagged inline. From
> next Sunday on, this format is auto-generated.

## Headline number

**Mission Yield (this week): ~13.6 yield-units / Mtok** (baseline — first measurement)

Prior week: unknown (no measurement existed). Will track delta starting next week.

## Composition

Window: 2026-05-11 00:00 UTC → 2026-05-17 00:00 UTC. Author: repairman29.
Merges measured: 88 (2026-05-16 alone; prior 5 days lighter).

| Tag | Count | Yield contribution |
|---|---|---|
| `marcus` | **2** | +2 |
| `fleet-quality` | **57** | +57 |
| `dev-tool` | **9** | +9 |
| `noise` | **20** | 0 |
| reverts (7d) | 0 | 0 |
| **Numerator** | **68** | |
| **Denominator (tokens)** | ~5.0 Mtok (estimated; cost_tracker not fully instrumented yet) | |
| **Mission Yield** | **~13.6** | |

## Top yield contributors (4 named PRs)

These are this week's load-bearing ships — what the operator should remember if you forget everything else.

1. **#2206 INFRA-1490 ci.yml merge driver mid-file** (`fleet-quality`)
   The single most-leveraged ship of the week. Closes the row-add conflict pattern that bit 10-12 PRs simultaneously this morning. **Behavior delta:** when 3+ agents add audit-job test-rows simultaneously, their PRs no longer all go DIRTY — `git merge-file --union` resolves them automatically. If this disappeared, today's fleet would have stalled at ~3 PRs/hr instead of 9/hr.

2. **#2177 INFRA-1400 audit job step isolation** (`fleet-quality`)
   Refactored CI's audit job from one bash-e script (any sub-test fails → whole audit fails → audit-required fails → every PR blocked) to per-step isolation. **Behavior delta:** one broken sub-test no longer cascades across the fleet. Unblocked ~20 PRs that were queued behind one INFRA-1368 time-bomb.

3. **#2196 PRODUCT-086 PWA PR action panel** (`dev-tool`)
   The cockpit's PR action surface — approve / revise / revert / comment from one panel. **Behavior delta:** operator stops alt-tabbing to GitHub for PR ops. Prerequisite for the Mission Yield chip-tag UI (Phase 1 instrumentation gap files this PR).

4. **#2143/#2207 PRODUCT-049 JetBrains ACP Registry** (`marcus`, 2 PRs)
   Registered + published chump in JetBrains' ACP agent registry. **Behavior delta:** an external engineer evaluating ACP-compatible agents now sees chump in the official registry. Marcus's "I saw chump in the registry" path is open. Both PRs together = the customer-discovery surface.

## Top noise contributors (5 named PRs)

Honest accounting. These shipped this week but had zero observable behavior delta. Not bad PRs — just not yield. If we could go back and not write them, the product is identical.

1. **#2222 MISSION: 15 business-thesis gaps** — bundle filing, no behavior
2. **#2224 chore(gaps): 12 PR-process automation gaps** — bundle filing
3. **#2155, #2156, #2165, #2225 (collectively)** — 22 more gaps registered. Filing scales; alignment doesn't.
4. **#2178, #2197, #2209, #2242 audit allowlist patches** — 4 separate "fix(audit): allowlist <kind>" PRs that unblock cascades. These exist because the audit gate doesn't grep the right paths AND because we file gaps that emit kinds before adding them to the registry. **Pattern → pain log** (see below).
5. **#2160, #2203 OFFLINE_COMPLIANCE_RUBRIC.md** — filed canonical doc, no consumer this week.

**Total noise: 20 of 88 ships = 23% of weekly merges.** Above the 10-15% I'd consider healthy. The noise is concentrated in two patterns: bundle gap-filings and audit-allowlist firefighting. Both addressable.

## Pillar mix (against the proposed 30% cap)

| Pillar | Merges | % | vs 30% cap |
|---|---|---|---|
| RESILIENT | ~55 | 63% | **OVER (+33%)** |
| ZERO-WASTE | ~14 | 16% | OK |
| EFFECTIVE | ~10 | 11% | OK (under-floor) |
| CREDIBLE | ~6 | 7% | OK (under-floor) |
| MISSION | ~3 | 3% | OK (under-floor) |

**Calibration miss this week.** RESILIENT dominated because of the runner ghost-ship + cascade-fix cycle. EFFECTIVE+CREDIBLE combined = 18%, below the proposed floor of 50%. Next week's correction: demote new RESILIENT gaps to P2 until EFFECTIVE catches up.

## Reverts within 7d

**0.** No code from this week got reverted. (Question for the next 7d — will any of today's fleet-quality PRs need revert?)

## Operator overrides

**1.** Operator override of P0 budget at ~16:30 UTC when INFRA-1486 was promoted to P0 alongside 4 already-P0 gaps, briefly putting the count at 6. Mitigated by demoting INFRA-1535 to P1.

## Calibration drift

**One issue worth surfacing.** "MISSION-tagged but doc-only" — PRs like #2160 (OFFLINE_COMPLIANCE_RUBRIC.md) and #2222 (15 business-thesis gaps) were filed under the MISSION pillar but had zero behavior change this week. The pillar tag and the chip-tag disagree.

**Proposed resolution:** the chip-tag wins. A PR tagged MISSION but `noise` does not contribute to mission progress; it contributes to filing pressure. This pattern repeats often enough that the pillar tag may be misleading us. **Take to next week's session for a decision.**

## Pain log (3-strike candidates for gap promotion)

Patterns that hit ≥3 times this week. Promote to gap if pattern persists.

| Pattern | Count | Proposed gap |
|---|---|---|
| Audit-allowlist firefighting after we ship a kind without registry entry | **4** | EXISTS as INFRA-1490 follow-up; close once 2026-05-23 has 0 recurrences |
| Bundle gap-filings producing 10+ untriaged gaps per PR | **5+** | NEW: `chump gap reserve` should refuse bundles > 5 unless `--bulk-override` |
| Cherry-pick failures across sibling branches (today's "PUSH FAILED" was actually "Everything up-to-date") | **3** | NEW: cherry-pick helper should check `git rev-list HEAD..target` BEFORE attempting; skip cleanly if already there |
| Cascade-fix PRs (allowlist / retrigger / empty-commit) shipped to unblock another PR | **6** | Already addressed by Wave 0 verification infra (INFRA-1541 / INFRA-1568 / INFRA-1539) — measure recurrence next week |

## What I want from you (operator) this week

1. **Spot-check the chip-tag classifications above.** I tagged 88 PRs from descriptions alone. If you'd reclassify any (especially marcus vs fleet-quality on the edges), `chump cos dispute <PR-#> --tag <new>` in batch is fine.
2. **Decision on the pillar-vs-chip-tag disagreement.** When the pillar says MISSION but the chip-tag says noise, which one drives demotion? My recommendation: chip-tag wins, pillar is descriptive not prescriptive.
3. **Are these targets right?** I set the weekly-Mission-Yield floor at 10 and targets at 20 → 30 → 50 → over the next 8 weeks. Calibrate from your gut.

## What's coming next week (preview)

- Wave 0 finishing: INFRA-1568 sibling claim, my INFRA-1539/1541/1580 in flight (#2250/2251/2252 — #2251 already landed)
- Mission Yield instrumentation (this PR's 4 gaps + this doc)
- First chip-tags actually being SET at merge time (not just backfilled by me)
- Backfill audit: confirm or revise the 88 tags I assigned tonight

## Cross-references

- [`docs/strategy/MISSION_YIELD.md`](../strategy/MISSION_YIELD.md) — formula
- [`docs/strategy/ROADMAP_WAVES.md`](../strategy/ROADMAP_WAVES.md) — ship-order
- [`docs/ROADMAP.md`](../ROADMAP.md) — top-level entry

---

*COS digest format established 2026-05-17. From 2026-05-24 forward, this section is auto-generated by `chump cos digest`.*
