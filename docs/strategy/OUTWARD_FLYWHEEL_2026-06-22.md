# The Outward Flywheel — discovery-driven roadmap (2026-06-22)

> **What this is.** The roadmap for turning Chump from "a fleet that improves
> itself" into "a fleet that builds and improves *other people's software*
> autonomously" (MISSION-010). Operator-set 2026-06-22. Tracked as **MISSION-050**.
>
> **The core bet:** *outward work is the discovery engine.* We don't theorize
> what to fix — we **point the machine at real external repos, hit real
> friction, and fix what breaks, foundation-first.** One BEAST-MODE run on
> 2026-06-22 surfaced 8 concrete gaps + a data-quality hole. That's the loop.

---

## The flywheel

```
        ┌──────────────────────────────────────────────┐
        │  ① RUN OUTWARD                                │
        │     chump improve <real repo>                  │
        │        │ hits real friction                    │
        │        ▼                                       │
        │  ② FILE the gaps it hits (auto, per run)       │
        │        │                                       │
        │        ▼                                       │
        │  ③ FIX foundation-first:  P3 → P2 → P1         │
        │        │ machine gets faster + more reliable   │
        │        ▼                                       │
        └──────► ① RUN OUTWARD again — deeper, cleaner ──┘
```

The continuous track (**①+②**) never stops — running outward is how the
roadmap stays honest. The fix track (**③**) is sequenced **3 → 2 → 1** below,
because each phase makes the next one cheap.

---

## Why 3 → 2 → 1 (foundation before machine before scale)

| Phase | What | Why this order |
|---|---|---|
| **3 — Substrate** | Make the build/CI system fast + honest | Every fix on 2026-06-22 fought the substrate (8-min cargo lock-stalls, `/tmp`-target corruption, forced `--no-verify`). A slow/flaky foundation taxes *every* downstream fix and erodes CI discipline. Fix it first → everything later goes 3–5× faster. |
| **2 — Outward loop** | Make `chump improve` work external repos cleanly, unattended | Once builds are fast, harden the actual pipeline (pick → dedup → implement → verify-merge) so it runs a repo's backlog without a human nudge. This *is* the MISSION-010 machine. |
| **1 — Work-mix** | Point the fleet's work outward at scale | Only worth doing once outward work is **cheap (3)** and **reliable (2)**. Today **72% of the open queue is self-referential** (INFRA 753 + META 125 + RESILIENT 102 of 1,361); only **17 gaps (1.2%) are external**. Scaling a still-broken loop just makes more mess. |

---

## Phase 3 — SUBSTRATE (fix first)

**Goal:** a fix-PR builds and ships without a lock-stall or a `--no-verify`
bridge; warm `chump preflight` < 60s.

- **RESILIENT-161** — cargo package-cache lock-stall under fleet contention
  (8-min hangs → forced `--no-verify`). *Fix shape:* per-worker isolated
  `CARGO_TARGET_DIR` off `/tmp`; a cargo-lock-aware build queue.
- **RESILIENT-163** — `/tmp`-target corruption: `wasmtime_wasi.d` parse errors,
  cold 15–20 min rebuilds because the target lives under a `/tmp` macOS purges.
  *Fix shape:* move `CARGO_TARGET_DIR` to a stable cache dir.
- **Bypass-pressure** — CREDIBLE-094 (`*_SKIP`/`*_BYPASS` ratchet) + the
  habitual `--no-verify` the lock-stall forces. The substrate fix removes the
  *reason* to bypass.

**Exit criterion:** ship 3 consecutive fix-PRs with zero lock-stalls and zero
bypass trailers.

## Phase 2 — OUTWARD LOOP (fix second)

**Goal:** `chump improve <repo>` runs N gaps unattended, opens clean PRs that
merge themselves — the literal MISSION-010 proof on `repairman29/BEAST-MODE`.

The 2026-06-22 BEAST run surfaced the exact gap list, mapped to pipeline stages:

| Stage | Gap | Status |
|---|---|---|
| IMPLEMENT (clone) | **EFFECTIVE-291** clone freshness | ✅ merged (#3164) |
| IMPLEMENT (scope) | **EFFECTIVE-292** scope-crept/dirty PRs | open (291's `clean -fd` partial) |
| PICK | **EFFECTIVE-289** skip-and-advance past done/in-flight | open · **P1** (flywheel-surfaced bottleneck) |
| PICK (scout) | **EFFECTIVE-290** onboard can't find intent docs → stale scan | open · **P1** (flywheel-surfaced bottleneck) |
| PICK (green-first) | **CREDIBLE-140** false-fires on stale PR branches | open |
| VERIFY-MERGE | **CREDIBLE-141** can't finish a verified-good merge | open |
| VERIFY-MERGE | **CREDIBLE-125** judge on CI-*delta* (pre-existing red advisory) | open |
| WORK QUALITY | **EFFECTIVE-294** reserve stamps real AC · **298** backfill 434 · **CREDIBLE-143** registry pollution + gap-mutation tooling | 294 in-flight |

**Exit criterion:** one `chump improve` invocation lands ≥3 merged PRs on BEAST
with zero human touches, overnight.

## Phase 1 — WORK-MIX (fix third)

**Goal:** the majority of weekly ships are outward/product work, not fleet-meta.

- **Picker bias** — a mission-rank multiplier for `external_repo:` gaps so they
  out-sort fleet-internal INFRA when both are pickable.
- **An outward curator** — a curator role whose only lane is filing
  outward/product work (the inverse of today's self-referential default).
- **A quota** — e.g. ≥30% of ships must be outward; surfaced in Mission Yield.

**Exit criterion:** external/product ships ≥ 30% of weekly throughput (today
~1%).

---

## How to run it

1. **Keep the flywheel turning** — run `chump improve` on BEAST (then new
   repos) on a cadence. Each run files what it hits → refills Phase 3/2/1.
2. **Drain 3 → 2 → 1** — the fleet picks the substrate gaps first, then the
   outward-loop gaps, then the work-mix levers. Don't start Phase 1 until
   Phase 2's exit criterion is met.
3. **Measure** — Phase exits above are the honest checkpoints. If a phase's
   exit isn't met, the next phase is premature.

**Anti-goal:** optimizing the engine while the car sits in the driveway. The
flywheel only counts when it's pointed at a *real repo that isn't ours*.

> **Provenance.** Born from the 2026-06-22 BEAST-MODE run that took the repo
> from 0 green-able PRs to fully green + merged a real autonomous RLS-recursion
> fix, then surfaced the 8 gaps above. The roadmap *is* the run's output.
