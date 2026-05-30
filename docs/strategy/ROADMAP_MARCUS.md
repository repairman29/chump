# Marcus roadmap — deliver the experience Persona-1 asked for

> **Status:** active 2026-05-16
> **Source:** 2026-05-15 customer-validation interview with Persona-1 (Hooked IC), referenced as "Marcus" across `docs/gaps/INFRA-1473..1491`. Persona kit lives in `docs/strategy/commercial/PERSONAS_VALIDATION.md` (gitignored).
> **One-line:** drive the gap registry toward the specific operator experience Marcus described, milestone by milestone.

## The experience Marcus asked for, in his own framing

A single operator command that does this:

1. He writes ONE `chump.fleet.yaml` — "architectural instruction + 12 service variables." Not 40 prompts.
2. Chump creates 12 worktrees, maps each service's Docker/env, drops one agent per service.
3. Each agent runs under **budgets**: wallclock, files-touched, deps-added, $ cost. So it doesn't Frankenstein-monster after 2 hours.
4. When agents hit conflicts on PR rebase, an **agent resolves the merge**. Not 45 min of Marcus's intense mental focus per PR.
5. Discovered quirks ("legacy DB indexing edge case") commit to a **team vector space** so the next agent doesn't re-suffer.
6. Agents can queue into a **shared team fleet** running on someone's beefy local box. Not choking individual laptops.
7. Auto-merge policy is **per-operator / per-repo** — Marcus's claims default to manual-review until trust is earned.

## Milestones

Each milestone has a clear "Marcus would notice if this didn't exist" test.

### M-A — Trust gate (P0) — **shipped**

Marcus's stated **disqualifying** behavior: "By 2 hours in, 14 files modified, 3 deps I'd never allow — Frankenstein monster." Without budgets nothing else matters because he won't leave the fleet unattended.

| Gap | Effort | Pri | Status |
|---|---|---|---|
| INFRA-1486 per-gap budgets (wallclock, files, deps, $) | m | **P0** | done (PR #2296) |

### M-B — Canonical demo (P1) — **substrate shipped, demo gates in flight**

The "minute-20 hook" the persona script was designed to test: write one fleet.yaml, watch 12 agents work. After this Marcus can run his actual day-job use case (12-microservices upgrade) once end-to-end.

| Gap | Effort | Pri | Status |
|---|---|---|---|
| INFRA-1483 chump.fleet.yaml spec | m | **P1** | done (PR #2303) |
| INFRA-1484 multi-repo fan-out from single command | l | **P1** | done (PR #2340) |
| INFRA-1487 reference-implementation primitive | m | P2 | open (supporting) |
| INFRA-1813 HITL approval gate before fan-out | m | P1 | in flight (claimed) |
| INFRA-1605 PR-bot visual-diff comments on every PWA PR | m | P1 | in flight (claimed) |

### M-C — Daily-tax killer (P1)

Marcus's Q2 single biggest time-sink: 45 min of intense mental focus per PR rebase. Self-contained — can ship parallel to M-B.

| Gap | Effort | Pri | Status |
|---|---|---|---|
| INFRA-1488 merge-conflict-resolution agent | m | **P1** | open |

### M-D — Team-tier substrate (P1) — DEMOED-BY INFRA-2234

The two named reasons Marcus would swipe the $49/op/mo Team-tier card. Both l-effort. Should land after M-A + M-B because their value-prop is invisible without the canonical demo working first.

> Demo runbook: [docs/strategy/CHUMP_PE_SUITE_DEMO_5MIN.md](CHUMP_PE_SUITE_DEMO_5MIN.md) — 5-beat synthetic demo (install → status → ask → reply → resolve+pivot). Run via `bash scripts/demo/chump-pe-suite-demo.sh`.

| Gap | Effort | Pri | Status |
|---|---|---|---|
| INFRA-1473 shared team vector-space for cross-agent context | l | **P1** | open |
| INFRA-1475 cross-operator fleet queue | l | **P1** | open |

### M-E — Trust polish (P2 / P3) — **partial**

After M-A through M-D ship, these complete the experience. Two of four already landed.

| Gap | Effort | Pri | Status |
|---|---|---|---|
| INFRA-1489 per-op + per-repo auto-merge policy override | s | P2 | done (chump-policy crate, 2026-05-29) |
| INFRA-1479 flaky-test detection + retry-aware sandbox | m | P2 | open |
| INFRA-1480 SAST + dep-vulnerability scan pre-PR | m | P3 | open |
| INFRA-1491 smart reviewer routing + notification | s | P3 | done (chump-reviewer-routing, 2026-05-29) |
| INFRA-2155 wire chump-policy check into bot-merge.sh (1489 integration) | s | P1 | open |

## Sequencing rationale

1. **Trust before features.** M-A (1486) is P0 because Marcus called the disqualifying behavior by name. No point shipping fan-out if the per-agent runaway problem isn't solved.
2. **Interface before scope.** M-B starts with the fleet.yaml spec (1483), not the multi-repo fan-out (1484). The spec format is the surface area every later feature attaches to.
3. **Daily-tax killer can ship parallel.** M-C (1488) is self-contained and unblocks Marcus's most-felt pain. It does not depend on M-B.
4. **Team-tier comes after canonical demo works for one operator.** M-D is the $49/mo upsell — it's worthless if M-B isn't already landing. Don't sell across before single-operator is delightful.
5. **Polish (M-E) waits.** Per-op auto-merge policy, flaky-test detection, SAST, smart routing — all real, all secondary to the operator running the demo end-to-end.

## What this roadmap is NOT

- Not the "offline + local-LLM" path. That's a tier-3 differentiator (privacy / cost-ceiling audience). Phase 1 is reliable fleet on GitHub for customers like Marcus.
- Not the fleet-meta-plumbing P0s (1528 auto-merge force-merge, 1532 bot-merge watchdog, 1533 claim handoff, 1534 self-hosted runners). Those are fleet-quality. They ship in parallel but do NOT block M-A through M-D for Marcus.
- Not exhaustive. Other Marcus-adjacent gaps may surface from the 2026-05-15 audit's third pass. File against this milestone arc.

## How to use this doc

- **Fleet pickers:** when scanning for next work, prefer Marcus gaps over equal-priority non-Marcus gaps. The `notes:` field of each Marcus gap is tagged `MARCUS M-A` through `MARCUS M-E` for grep-ability.
- **Operator:** check progress with `grep -l MARCUS docs/gaps/INFRA-14*.yaml | xargs -I{} chump gap show $(basename {} .yaml) --brief`.
- **Reviewer:** for any PR claiming a Marcus gap, the AC must trace back to a quoted phrase from Marcus's interview, not invented features.

## Open question for operator

After M-A ships, do we run a check-in interview with Marcus to validate the trust-gate UX before investing in M-B? Cheap signal, high value if the budget defaults are wrong.

> **Update 2026-05-29:** M-A is done (PR #2296). M-B substrate (1483 spec + 1484 fan-out)
> is also done; the remaining M-B work is the demo-grade HITL approval gate (INFRA-1813)
> and the PR-bot visual-diff (INFRA-1605), both currently claimed. The
> check-in interview the operator wants to run is now unblocked on substrate —
> only blocked on Marcus's calendar. M-E partially landed today (INFRA-1489
> chump-policy + INFRA-1491 reviewer routing); follow-up INFRA-2155 wires
> chump-policy into `bot-merge.sh` for live enforcement.

---

_Last refreshed: 2026-05-29_
