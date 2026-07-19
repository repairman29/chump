# Chump Roadmap — current cycle

> **What this is.** The single canonical entry point for "what is chump
> working on, in what order, why." Gaps implement the roadmap, not the
> other way around.
>
> **Cadence.** Reviewed by the operator weekly. Updated by the Mission
> Driver session (see [`CLAUDE.md` → Mission Driver](../CLAUDE.md#mission-driver--every-session-not-just-when-asked))
> when an outcome lands or framing shifts.

## TL;DR for a returning operator (2026-05-28 reality)

Five anchors. **Mission Yield** is the headline number; **Wave order** is the ship discipline; the three workstreams below run inside both constraints.

| Anchor | Doc | What it answers |
|---|---|---|
| **📊 Mission Yield (the rule of X)** | [strategy/MISSION_YIELD.md](strategy/MISSION_YIELD.md) | Is the work actually moving the product? Single number, weekly. |
| **⏯️ Wave order (ship discipline)** | [strategy/ROADMAP_WAVES.md](strategy/ROADMAP_WAVES.md) | What ships first to avoid rework? 4 waves, cumulative. |
| **🚀 50 PRs/hour push** | [strategy/ROADMAP_50_PER_HOUR.md](strategy/ROADMAP_50_PER_HOUR.md) | Capacity to sustain Mission Yield at scale. 15 days. |
| **👤 Marcus customer arc** | [strategy/ROADMAP_MARCUS.md](strategy/ROADMAP_MARCUS.md) | The customer the product is for. 5 milestones M-A → M-E. |
| **🛠️ Backlog decisions** | [strategy/ROADMAP_BACKLOG.md](strategy/ROADMAP_BACKLOG.md) | 8 design-conversation items decided 2026-05-16 — what's build/defer/fold. |
| **🔄 Integration-cycle ship pipeline** | [strategy/INTEGRATION_CYCLE_2026-05-29.md](strategy/INTEGRATION_CYCLE_2026-05-29.md) | How the fleet ships: batched cycles (Mode A) vs per-PR (Mode B) vs hot-fix (Mode C) vs external-repo (Mode D). |
| **🌍 Outward Flywheel (MISSION-050)** | [strategy/OUTWARD_FLYWHEEL_2026-06-22.md](strategy/OUTWARD_FLYWHEEL_2026-06-22.md) | The path to MISSION-010: improving *other* repos. Run outward to discover, fix foundation-first (3→2→1: substrate → outward-loop → work-mix). |

**Read order:** Mission Yield first (the why), Waves second (the order), then the three workstreams (what's pickable now).

**Operating model:** the Chief of Staff role (currently Claude-as-COS; productized via [process/COS_OPERATING_MODEL.md](process/COS_OPERATING_MODEL.md) for autonomy by ~2026-07-01) opens every session with current Mission Yield, enforces the 30%-per-pillar cap, and produces a Sunday digest at [syntheses/cos-weekly-*.md](syntheses/). First digest: [cos-weekly-2026-05-17.md](syntheses/cos-weekly-2026-05-17.md) (Mission Yield baseline ~13.6/Mtok).

**Framing reset 2026-05-16:** Infra IS the product. GitHub is where users
live. "Offline-first" is a tier-3 differentiator, not the spine. The fleet's
behavior (reliable auto-merge, conflict-resolving rebases, healing CI gates)
IS what customers like Marcus pay for.

## Current cycle — Revival & Truth (2026-07-19 → 2026-08-16)

> Filed 2026-07-19 after the queue-clear + registry triage session (15 PRs merged,
> 288 pollution gaps closed, outcome linkage backfilled to 100% of open gaps,
> P0 refilled with 5 true unblockers, 85 dormant P1s demoted). Context: the fleet
> was silent June 22 → July 18 (auth-cache + lid-close class outages); trunk is
> green and the queue is empty. This cycle turns the machine back on WITHOUT
> re-inheriting the failure modes that killed it, then points it at the mission.

## Week 1 — Revive the heart, safely (Jul 19 → 26)

**Outcome.** The fleet ships autonomously again for 72h+ with no silent death:
merge queue alive, sleep/wake survivable, operator has a one-dial control, and
the scoreboard can no longer claim health it can't prove.

**Implementing gaps:**
- **RESILIENT-168** P0 — integrator-daemon dead (exit 127) → merge queue restored
- **RESILIENT-169** P0 — sleep/wake-recovery hook (lid-close killed the fleet twice)
- **EFFECTIVE-305** P0 — chump-mode one-dial run-mode toggle (grind/travel/off), durable port
- **CREDIBLE-151** P0 — mission scoreboard verifies installed-binary SHA vs origin/main (13-day-stale-binary incident)

## Week 2 — Registry truth (Jul 26 → Aug 2)

**Outcome.** state.db is trustworthy end-to-end: no ID collisions across
worktrees, no fixture leakage, workers attributable, vague-AC backlog burned down.

**Implementing gaps:**
- **INFRA-3338** P0 — dual-allocator gap-ID collision fix
- **CREDIBLE-152** P1 — reserve guard: fixture titles hard-blocked from canonical db
- **CREDIBLE-099** P1 — workers register THEMSELVES (heartbeats + kpi --agents attribution)

## Week 3 — Mission proof on BEAST (Aug 2 → 9)

**Outcome.** MISSION-010 stops being aspirational: the fleet runs an overnight
loop against repairman29/BEAST-MODE and lands real merged PRs there — the
scoreboard's own definition of proof.

**Implementing gaps:**
- **INFRA-2268** P1 — `chump onboard --schedule` per-external-repo overnight loop
- **INFRA-2269** P2 — `chump keys` per-org key vault (unblocks safe external-repo auth)

## Week 4 — Product surface (Aug 9 → 16)

**Outcome.** The parts a customer touches get real: monolith decomposed enough
to publish the root crate, TS bindings exist, and the operator gets a weekly
digest instead of reading ambient streams.

**Implementing gaps:**
- **INFRA-3287** P2 — main.rs god-switchboard decomposition (tiny slices; unblocks crates.io root publish)
- **INFRA-2270** P2 — `chump sdk gen --target ts`
- **PRODUCT-137** P2 — operator weekly digest (Discord/email)

---

## Shipped from week-of-2026-05-16 bets ✅

| Bet | Gap | Status |
|---|---|---|
| Hit 50 PRs/hr by end of May | INFRA-1540 + INFRA-1542 | ✅ done |
| Marcus trust gate (per-gap budgets) | [INFRA-1486](gaps/INFRA-1486.yaml) | ✅ done |
| Self-hosted runners actually serve CI | INFRA-1540 ghost-ship recovery | ✅ done |
| 4 follow-up gaps for full INFRA-1534 closure | INFRA-1542 / 1543 / 1544 + CREDIBLE-069 | ✅ done (CREDIBLE-069 still open as P2/s telemetry slice) |
| Marcus canonical demo interface | [INFRA-1483](gaps/INFRA-1483.yaml) | ✅ done |

## Shipped 2026-05-28 — Wave 1 CI scaling ✅

5 PRs landed in one session, targeting ~3–4× CI throughput on existing hardware for $0–5/mo spend. See [`strategy/CI_SCALING_REFERENCE.md`](strategy/CI_SCALING_REFERENCE.md) for the full Wave 1/2/3 decision tree.

| Bet | Gap | PR | Outcome |
|---|---|---|---|
| Trunk-RED keystone fix (5-bug cluster: CARGO_TARGET_DIR path, env-vars registry, INFRA-1392 regex, event-registry orphans, ci-parity drift) | [INFRA-2096](gaps/INFRA-2096.yaml) | #2689 | ✅ unblocked every other Wave-1 PR |
| cargo_build loud-fail wrapper (kills INFRA-2082 silent-class) | [INFRA-2086](gaps/INFRA-2086.yaml) | #2685 | ✅ wrapper available for sibling-sweep (INFRA-2098) |
| cargo-nextest swap — 60% faster parallel test runs | [INFRA-2094](gaps/INFRA-2094.yaml) | #2686 | ✅ active on main; first post-merge measurement next CI cycle |
| GitHub merge_queue coverage gate + readiness doc | [INFRA-2095](gaps/INFRA-2095.yaml) | #2687 | ✅ plumbing GREEN; operator can flip "Require merge queue" toggle when comfortable |
| sccache + Cloudflare R2 shared compile cache — 50–70% compile speedup on hits | [INFRA-2093](gaps/INFRA-2093.yaml) | #2690 | ✅ secrets landed by operator; R2 will populate over next 5–10 PR cycles |

## Today's bets (week of 2026-05-24)

| Bet | Gap(s) | Status |
|---|---|---|
| Chump fleet autopilot — operator playbook as one daemon set | [META-090](gaps/META-090.yaml) P0/m | ✅ done — composes the 5 wizard-retirement daemons; reconciliation shipped via #2570 (RESILIENT-021) |
| Marcus arc M-B → M-C (post-demo trust + first-customer-onboard) | new gap TBD when M-B framing lands | **next operator decision** — defines this week's bet list. M-A (per-gap budgets INFRA-1486) shipped; M-B chump.fleet.yaml spec INFRA-1483 + multi-repo fan-out INFRA-1484 still open |
| 50-PRs/hr Phase 2 — sustained 4h verification | INFRA-1540/1542 instrumentation follow-up | shipped capacity; now needs the 4h-green run |
| A2A-first communication discipline (presence ledger + auto-mirror + passive emit) | [INFRA-1932](gaps/INFRA-1932.yaml) P1/m | ✅ done — partial-shipped via #2524 + later land closed the 6 follow-up ACs |
| Rust-first orchestration substrate (Wave-3) — port 16.8K LOC bash+Python to ~6K LOC Rust across 6 sub-gaps | [META-107](gaps/META-107.yaml) P1/xl umbrella + [INFRA-1997](gaps/INFRA-1997.yaml) P0/m keystone | ✅ done at umbrella level; cutover follow-ups INFRA-2060..2065 + META-120 filed for the 7–14d parallel-run validation window per blueprint [strategy/RUST_FIRST_MIGRATION_BLUEPRINT_2026-05-25.md](strategy/RUST_FIRST_MIGRATION_BLUEPRINT_2026-05-25.md) |

**Chained, not competing.** META-107 IS the substrate that META-090 composes. Without META-107, autopilot inherits 16.8K LOC of bash spaghetti (race conditions in `bot-merge.sh`, env-leak in `pre-push`, `sed`-escape in `broadcast.sh`). With it, autopilot is composed from `chump-ship` + `chump-messaging` + `chump-worker` Rust traits where env-leak / double-instance / SQL-escape bugs are *structurally impossible*.

### Wizard-retirement criteria — 5/5 ✅ shipped (META-090 unblock COMPLETE)

The wizard role retires when the daemon mesh covers what the operator does manually 10×/day. Criteria:

| # | Daemon | Status |
|---|---|---|
| 1 | curator-jit-scheduler | ✅ shipped INFRA-1892 (PR #2463) |
| 2 | transient-retrigger | ✅ shipped INFRA-1899 (PR #2482) |
| 3 | pr-pulse consumer | ✅ shipped INFRA-1898 (PR #2497) |
| 4 | oracle-refresh cron | ✅ shipped META-088 (PR #2510); ongoing observability INFRA-2122 caught silent failures 2026-05-29 |
| 5 | curator-launch automation | ✅ shipped INFRA-1880 (PR #2518) |

All 5 shipped. META-090 autopilot is composing them (#2570). **The wizard role can retire when the operator validates the autopilot daemon-set runs 24h unattended** (Day +14 checkpoint).

The remaining substrate-quality work is OAuth refresh chain (INFRA-2124) + Oracle silent-failure detection (INFRA-2122 observability) — these don't block wizard-retirement but they make the autopilot loop reliable.

## Operator action checkpoints (refreshed 2026-05-28 — Wave 1 CI scaling shipped)

- **Day +1** (~2026-05-29): observe sccache R2 cache hit-rate climb on next 5–10 cargo-test CI runs (target ≥50% hit by Day +3); flip "Require merge queue" toggle in branch protection when comfortable (5-min Web UI flip, reversible in 30s; runbook in `process/MERGE_QUEUE.md`)
- **Day +3** (~2026-05-31): Wave 1 empirical measurement — compare cargo build wall-clock before/after on a representative wave of 5 PRs; document in commit body of follow-up gap
- **Day +7** (~2026-06-04): INFRA-1998 messaging + INFRA-1999 github-cache in parallel; 50/hr sustained 4h green with Wave 1 multipliers active
- **Day +14** (~2026-06-11): INFRA-2001 chump-ship lands (fixes INFRA-1532 double-instance by PID-locked socket, by construction); META-090 autopilot composition begins ON the Rust substrate
- **Day +21** (~2026-06-18): META-090 autopilot daemon-set running unattended for 24h on env-immune substrate; INFRA-2002 chump-worker lands
- **Day +28** (~2026-06-25): Marcus M-B demo with autopilot+substrate as the credibility story (post-trust-gate onboarding)

**The trade** (vs prior 2026-05-25 schedule): Wave 1 CI scaling shipped 3 days ahead of its implicit slot, compressing future bets by the same window. Tonight's INFRA-2096 keystone (5-bug trunk-RED cluster) hardened the registry plumbing as a side effect — the kind of incident the Rust substrate is designed to eliminate by construction, but observed-and-fixed-in-bash is a useful Wave-1 baseline.

---

## Historical cycles

The full May 2026 30-day plan (weeks, vision, success criteria, phase-5 backlog,
hygiene rules, latent levers) is archived at
[archive/ROADMAP_MAY_2026_CYCLE.md](archive/ROADMAP_MAY_2026_CYCLE.md).
