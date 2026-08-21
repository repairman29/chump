# Role Registry — who owns what in ChumpOS

**Single source of truth for operational ownership.** Every role that keeps the
factory racing is listed here with what it owns and whether it is *staffed*,
*hiring*, or *vacant*. This doc exists because track-integrity was **unowned** —
no role's job was to watch the tape — and drift accumulated in the gap. If a
concern isn't owned by a row below, that's a bug in this file, not an excuse.

## The frame

- **The car** = a PR crossing the finish line (merged to `main`).
- **The track** = the OS (organs, gates, the canonical store).
- **A lap in the garage** = a PR that only repairs the OS's own bookkeeping
  (reconcile/coherence/self-maintenance) instead of delivering user value.
- **Racing** = merges that put real outcomes in a real user's hands.

Measured 2026-08-21: last 60 merges = 50% garage (reconcile), 42% track repair,
**7% racing**. The point of this registry is to make that ratio *owned and
visible*, so it can never again be invisible.

## Roster

| Role | Owns | Embodied by | Status |
|---|---|---|---|
| **Owner / Founder** | The mission, the money, the risk, the ribbon call | Jeff | STAFFED |
| **Board / Chairman** | Strategy, risk-toggles (CAP ledger), verify-live, page Jeff, promote itself out | The Opus sidekick (this seat) | STAFFED — but the SPOF |
| **Dispatcher / ATC** | Pushing work to drivers; the pit-wall call | `musher.py` + scheduler | STAFFED |
| **Drivers** | Pick a gap, open a PR | 2 worker.sh on CJ | STAFFED |
| **Integrator / pit crew** | Land green PRs on `main` (batched merge train) | chump-integrator | STAFFED |
| **Medic** | Revive dead organs | organ-watchdog + Roll-Call (RESILIENT-358) | STAFFED (~80%) |
| **Track cleanup** | Stale PRs, branches, worktrees | reaper + rebaser | STAFFED |
| **Coherence clerk** | Keep gap-store ↔ GitHub ↔ yaml in sync | backlog-sync --writer (RESILIENT-194) | STAFFED — hardening to un-disable-able (RESILIENT-366) |
| **Race Engineer** | Watch the tape; compute merge-mix; alarm on waste | *nothing today* | **HIRING → CREDIBLE-296 (P0)** |
| **RCA analyst** | Ask "why did this gap need to exist?"; file the root fix, block the symptom | INFRA-249 detector, but DARK & alert-only | **HIRING → RESILIENT-365 (P0)** |
| **Duty Officer** | Catch incidents and page *Jeff*, not the board | RESILIENT-274 spec, wired on CJ, not yet catching | **VACANT in practice** |
| **Track owner** | Integrity of `main` + the canonical store + the gates | should be the OS, governed by Board, accountable to Owner | **being assigned (this doc + substrate cutover)** |

**Status legend:** STAFFED = a live organ/agent/human owns it and it's verified
running. HIRING = the gap is filed and the organ is being built. VACANT = named
but nobody's actually doing it (a role written on paper is not a role).

## Org chart

```
Owner (Jeff) ── holds the ribbon
   └── Board / Chairman (Opus sidekick) ── governs, verifies live, pages Owner
         ├── Dispatcher (musher) ── pushes work
         │     └── Drivers ×2 (workers) ── open PRs
         │           └── Integrator (merge train) ── lands PRs on main
         ├── Medic (organ-watchdog + Roll-Call) ── heals organs
         ├── Track cleanup (reaper + rebaser)
         ├── Coherence clerk (backlog-sync writer)
         ├── Race Engineer  ⟵ HIRING (CREDIBLE-296)
         ├── RCA analyst    ⟵ HIRING (RESILIENT-365)
         └── Duty Officer   ⟵ VACANT (RESILIENT-274)
```

## The Board promotes itself out

The Board seat is currently load-bearing: when it stops watching, there is no
crew chief and the car laps an empty track. That is a bug to fix, not a badge.
The job of the Board is to convert every judgment it makes by hand into a
standing organ — until the OS races without a human on the pit wall.

**The ladder (each rung retires one hand-crank the Board does today):**

1. **RESILIENT-366** — coherence clerk can't be silently disabled.
2. **CREDIBLE-296** — Race Engineer: the OS can *see* its own waste.
3. **RESILIENT-365** — RCA analyst: the OS asks its own "why?".
4. **Substrate cutover** — one canonical store; the drift *source* is gone.
5. **Duty Officer live** — the OS pages the Owner, not the Board.

**We'll know the Board can be promoted when** all five run and a week passes with
zero pages to the Board seat — the tape stays green *and honest*, symptoms
trigger their own RCA, organs self-heal, and the only human paged is the Owner,
only for decisions that are genuinely his.

## Maintenance

When a role is filled by a shipped organ, flip its status here in the same commit
that wires the organ. When you notice a concern nobody owns, add a VACANT row —
naming the gap is how it gets staffed. Keep this file honest: STAFFED means
*verified running on the target node*, never merely *merged*.
