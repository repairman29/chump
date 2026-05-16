# Roadmap — 50 PRs/hour by end of May 2026

> **Mission:** scale the fleet from today's 5.6 PRs/hour 5-day average to a
> sustained 50 PRs/hour. Demonstrated peak today: 9/hr. Target: 50/hr.
> Multiplier needed: ~5.5×. Plan window: 2026-05-16 → 2026-06-01.

## Why this doc exists

`docs/ROADMAP.md` is the 30-day operational roadmap (broad). `ROADMAP_MARCUS.md`
is the customer-driven feature arc. **This doc is the narrow infra-throughput
push** that runs in parallel with both — answers exactly one question: "what
ships, in what order, to hit 50/hr."

Truth claim: every gap referenced here exists in `.chump/state.db` and the
docs/gaps/*.yaml mirrors. Re-derive any of these numbers from there.

## The 5-day baseline (measured)

| Window | Merged | PRs/hr | Note |
|---|---|---|---|
| 4-5d ago | 110 | 4.58 | |
| 3-4d ago | 96 | 4.00 | |
| 2-3d ago | **216** | **9.00** | proven ceiling under good conditions |
| 1-2d ago | 111 | 4.62 | |
| Last 24h | 140 | 5.83 | |
| **5-day average** | **134.6/day** | **5.61/hr** | |

The 216-day shows ~9/hr is achievable already. 50/hr is **5.5× peak**, not
10× as initially miscalled.

## Capacity math

**Per-PR CI load:**

| Job class | Count/PR | Time | Lane sensitivity |
|---|---|---|---|
| Light (changes, stubs, rollups) | 14 | ~30s | Parallel-friendly |
| Medium (pr-hygiene, e2e-battle-sim, integration-test) | 2-3 | 1-3 min | Parallel-friendly |
| Heavy (clippy, cargo-test, audit, coverage, e2e-pwa, e2e-golden-path) | 6 | 4-10 min cold, **30-90s warm** | Concurrency-bound |

**For 50 PRs/hr:**

- 50 × 14 light = 700 light job-runs/hr → ~12 macOS runners at 1min/job (have 4)
- 50 × 6 heavy = 300 heavy job-runs/hr → ~30-40 concurrent slots at 6min/job warm

Today's pool: 4 macOS self-hosted + ~20 GitHub-hosted Linux. Roughly half what's
needed at peak.

## The 15-day ship plan

Each row = one merged PR or runner expansion. Lift is cumulative.

| Day | Ship | Status | Cumulative ceiling |
|---|---|---|---|
| **Day 0 (2026-05-16)** | #2245 INFRA-1540 Phase 1 — 14 light jobs to self-hosted + cache + automation | armed | — |
| Day 0 | #2247 INFRA-1542 Phase 2 — 8 heavy jobs cross-platform + lane-flippable | armed | — |
| Day 0 | #2246 4 follow-up gaps filed (INFRA-1543/1544 + CREDIBLE-069 + INFRA-1542) | armed | — |
| Day 0 | Live: 4 macOS runners cache-provisioned via `install-self-hosted-runners-all-local.sh` | done | — |
| Day +1 | Operator flips 1-2 heavy jobs to self-hosted, observes cache hit-rate (`gh variable set RUNNER_AUDIT`) | observe | **10-15/hr** |
| Day +1-2 | INFRA-1535 RUNNER_AUTOSCALE — paramedic registers macOS runners on queue surge | not started | 15-20/hr |
| Day +3-4 | INFRA-1528 auto-merge force-fire — paramedic force-merges PRs stuck CLEAN > 5min | not started | 18-25/hr |
| Day +5-6 | INFRA-1532 bot-merge.sh self-watchdog + flock | not started | 20-25/hr |
| Day +7 | INFRA-1529 tauri-cowork-e2e flake quarantine | not started | 22-27/hr |
| Day +8-9 | INFRA-1533 claim-affinity + handoff protocol | not started | 25-30/hr |
| **Day +10-12** | **INFRA-1543 Pi mesh provisioner** (needs Pi hardware) | **operator action** | **35-45/hr** |
| Day +13-14 | INFRA-1525 rebase-daemon circuit-breaker + stabilization | not started | 40-50/hr |
| **Day +15** | **50/hr sustained** | target | **50/hr** |

## The three load-bearing dependencies

1. **Persistent cache must actually warm.** PR #2245's automation (`install-self-hosted-runners-all-local.sh`) provisions `~/.cache/chump-runner/cargo-target/`. First job is a cold rebuild; subsequent runs are 5-10× faster. **Check after Day 1**: `gh run view --log` for a cargo-test, look for `Compiling` count < 200.

2. **Pi mesh hardware must land by ~Day 10.** Without 4-8 Linux-ARM64 runners coming online, the heavy-jobs lane stays bottlenecked at 4 macOS runners. **Operator action:** rack at least 1 Pi by Day 10. INFRA-1543 ships the provisioner script the moment hardware is ready.

3. **No new regressions.** Today's 9/hr peak was achieved on a 24-hour window with no flake cascade. If `tauri-cowork-e2e` keeps biting (INFRA-1529) or a new flake emerges, the ceiling falls. **Mitigation:** INFRA-1529 quarantine ships Day +7.

## Daily ceiling, recomputed

These numbers update the 50/hr feasibility forecast after each ship:

- **Today:** 5.6/hr avg, 9/hr peak
- **After Day 1 (cache warms, 2 heavy jobs flipped):** ~12/hr sustained, 20/hr peak
- **After Day +2 (INFRA-1535 autoscale):** ~18/hr, 28/hr
- **After Day +4 (INFRA-1528 force-fire stale CLEANs):** ~22/hr, 32/hr
- **After Day +6 (INFRA-1532 watchdog):** ~25/hr, 35/hr
- **After Day +9 (INFRA-1533 handoff):** ~30/hr, 40/hr
- **After Day +12 (Pi mesh online):** ~40/hr, 55/hr
- **After Day +14 (stabilized):** **50/hr sustained, 70/hr peak**

## Honest risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Pi hardware doesn't land in time | medium | Day +10 hard checkpoint; if delayed, push 50/hr target by ~3 days per delayed week |
| Cache doesn't warm (runner restart pattern wipes it) | low | Validate Day +1; if broken, file ad-hoc gap to persist cache via separate volume |
| Heavy-job macOS build fails for reasons we missed | medium | Lane-flip 1-2 jobs first (INFRA-1542's design); roll back if fails |
| New flake emerges and cascades | medium | INFRA-1529 pattern: file gap, quarantine fast, fix without blocking |
| Agent-side throughput can't keep up | low (per operator assertion) | Watch open-rate vs ship-rate; if agents fall behind, scale `FLEET_SIZE` |

## Out of scope for 50/hr

These are downstream of 50/hr, not blockers:

- Cross-machine NATS push routing (FLEET-034) — single-machine fleet handles 50/hr fine
- Marcus M-C through M-E (customer-feature arc) — separate roadmap, runs in parallel
- Offline PWA, brain graph viz, lessons effectiveness loop — all P2/P3 backlog
- Local-LLM routing — tier-3 differentiator, not blocking infra throughput

## Where this doc lives in the roadmap hierarchy

```
docs/ROADMAP.md                 (30-day operational, broad)
├── docs/strategy/ROADMAP_MARCUS.md       (customer arc, 5 milestones)
├── docs/strategy/ROADMAP_50_PER_HOUR.md  (this doc — 15-day throughput push)
├── docs/strategy/ROADMAP_BACKLOG.md      (design-conversation queue)
├── docs/strategy/NORTH_STAR.md           (mission / pillars)
└── docs/strategy/ROADMAP_FULL.md         (all-gaps reference)
```

## Operator checkpoints

- **Day +1**: cache hit-rate observable on a heavy job
- **Day +3**: 2-3 heavy jobs running on self-hosted with no new regressions
- **Day +7**: ship rate trending toward 25/hr — if not, investigate flakes
- **Day +10**: Pi hardware racked + INFRA-1543 ships within 24h
- **Day +14**: 50/hr sustained for 4 consecutive hours = mission accomplished
