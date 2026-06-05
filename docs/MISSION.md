# Chump — Mission (load-bearing)

> **Operative mission of record.** Everything the fleet and the conductor do is
> subordinate to the **Scoreboard** below. If a day's work didn't move the
> Scoreboard, it didn't count — no matter how busy it looked.
>
> Filed as MISSION-014. Canonical mission gap: **MISSION-010**. Current
> multiplier: **MISSION-012** (self-deploy).

## North Star (the *why* — never "done")

A solo developer — even offline, on local LLMs — can build and ship real
software while the fleet does the hands-on work. **The coordination layer IS the
product.** No human in the conductor's chair.

## Mission (the measurable *what* — this year, falsifiable)

Chump takes a neglected or greenfield repo from **0→1** (or dormant → deployed)
with **zero human-written code and zero human merges.** The proof / cargo:
**`repairman29/BEAST-MODE`, dormant → deployed, autonomously.**

Acceptance gate (operator's words): *"If Chump can't merge a PR in the BEAST
repo without a human, what is it for?"* →
**A PR merges in BEAST-MODE, in production, with no human touch.**

- Canonical mission gap: **MISSION-010** (self-coordinating fleet / empty
  conductor's chair, proven on BEAST-MODE).
- Active mission pointer: `~/.chump/ACTIVE_MISSION` (currently `MISSION-010`).
- The picker (**MISSION-011**) reads it and ranks mission-linked gaps above
  same-priority throughput gaps (after priority, before effort).

## Goals (the capabilities that make the mission true — each measurable)

1. **Self-deploy** — a merged fix reaches the running system with no human.
   (**MISSION-012**.) *Metric: manual deploy steps per ship = 0.*
   **← CURRENT MULTIPLIER: until this lands, every merge is inert.**
2. **Self-heal** — the fleet recovers from any halt with no human terminal.
   (**RESILIENT-087** + the pty/auth fragility class: RESILIENT-086/088/092.)
   *Metric: unattended-recovery rate.*
3. **Mission-weighted output** — the fleet's work-mix favors mission over
   self-maintenance. *Metric: mission-ships ÷ total-ships; target ≥ ⅔
   (today ~⅓).*
4. **External delivery** — Chump scouts + works + ships in a repo it doesn't
   own. (onboard → BEAST: **EFFECTIVE-112 / 123 / 133**.)
   *Metric: external PRs merged.*
5. **Zero-touch loop** — human interventions per merged PR → **0**.

## Scoreboard (the one honest measure)

Run **`scripts/dev/mission-scoreboard.sh`** (read-only, safe anytime). It reports:

- **① THE BINARY (weekly):** Did Chump merge a zero-human-touch PR in
  BEAST-MODE this week? — *today: **NO**.*
- **② Mission-ship ratio (24h):** mission merges ÷ total (target ≥ ⅔).
- **③ Deploy-lag:** is the running binary current with `main`? (Goal 1 proxy.)
- **④ Fleet liveness:** last-merge age + 24h ship count.
- **Verdict:** `HANDS-OFF` / `ON-TRACK` / `DRIFTING` / `STALLED`.

**The mission is achieved when ① is YES on its own, repeatably, with no human in
the loop.**

## Doctrine (so we can't drift again)

- **Motion ≠ progress.** Queue hygiene, substrate hardening, and self-maintenance
  keep the lights on but are **not** mission progress. They are justified only
  insofar as they unblock a Goal.
- **Gap-generation serves the mission.** Bias new gaps toward the Goals above. A
  backlog that is mostly self-maintenance gaps generates mostly self-maintenance
  ships — the gap schema shapes the output.
- **The conductor's job is the Scoreboard, not busy-ness.** Each conductor tick
  consolidates its check into the scoreboard (one call) and acts only to move a
  Goal or unblock a mission ship.
- **Operator controls remain sovereign:** `~/.chump/AUTONOMY_LEVEL` (0 = stop,
  fail-closed) and `chump fleet stop`. Autonomy is dialed, not assumed.

## Scale (the *to where* — operator framing 2026-06-05)

> *"I want this to scale to 100s of repos soon. I alone have 100 repos.
> So maybe we need 10,000s."*

The mission's proof (BEAST-MODE, MISSION-010) is N=1 external repo.
That's necessary, not sufficient. The fleet has to generalize. Full
phase model + per-phase load-bearing gaps lives in
[`docs/strategy/MULTI_REPO_SCALE_2026-06-05.md`](./strategy/MULTI_REPO_SCALE_2026-06-05.md);
short version:

| Phase | Repos | Status |
|---|---|---|
| **A** | 1–10  | TODAY. Tag-based routing in `gap.skills_required`. BEAST proves. |
| **B** | 10–100 | Operator's own portfolio. 6 Tier-1 gaps under MISSION-032. |
| **C** | 100–10,000 | Multi-customer commercial. Sharding + per-customer privacy. |

**Substrate decisions** (constraints, not gaps):
- state.db stays single-writer through Phase B; sharding decision deferred to Phase C entry.
- Per-repo namespace is filesystem (`~/.chump/external/<owner>/<repo>/`), not schema.
- Privacy boundary is **per-repo** (`repos.cascade_tier`, operator-controlled), not per-gap.

**Phase-transition triggers** to watch for: tracking ≥5 active external repos,
disk usage `~/.chump/external/` > 5 GB, or mission scoreboard needing a
per-repo view → start Phase B work. See strategy doc for the full trigger
table.

Canonical umbrella: **MISSION-032**.

## Follow-ups

- Port `scripts/dev/mission-scoreboard.sh` into **`chump kpi mission`** (Rust,
  durable) once the metrics stabilize.
- Surface ① (THE BINARY) in the fleet-brief / SessionStart banner so it's visible
  every session.
- Instrument a true **human-touch counter** (Goal 5) — events for manual merge,
  manual rebuild/deploy, operator-recall-acted, conductor-intervention — so the
  zero-touch metric is measured, not estimated.
- Phase B Tier-1 gaps (MISSION-033 — MISSION-038) — see MISSION-032 umbrella.
