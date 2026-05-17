---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-16
---

# Roadmap waves — ship-order discipline

> **Why this doc.** The 5 days leading up to 2026-05-16 saw repeated cascades:
> ship new infra → discover the lane / contract / tool isn't actually verified
> → 8-30 PRs blocked → emergency rollback → file structural gaps → ship more
> infra → repeat. Velocity isn't the throughput of one PR; it's the throughput
> of PRs *that don't require rework*. **Order is the velocity multiplier.**
>
> **This doc names the dependency graph explicitly.** Each wave below MUST be
> on main before the next wave starts. A gap from a later wave is not
> "pickable" even if AC are written and the gate-audit says it's claimable —
> it requires the prior wave's foundation.
>
> **Owner.** Operator approves wave transitions. Workers should not skip waves
> just because picker shows them eligible; check this doc first.

---

## Wave 0 — Verification infrastructure (foundation)

**Must hit main before Wave 1.** These are the truth-gates. Every cascade in
the last 5 days was preventable if these existed in code:

| Gap | Pillar | Effort | What it gates |
|---|---|---|---|
| **INFRA-1568** | CREDIBLE | s | Broad canary contract — new runner lane must pass FULL production workflow end-to-end before declared ready |
| **INFRA-1541** | CREDIBLE | m | Pre-merge AC coverage gate — block ship when PR diff misses an AC bullet (advisory first 50 PRs, then blocking) |
| **INFRA-1580** | CREDIBLE | m | Rust-First-Bypass auto-verify — machine-check the criteria the bypass implicitly waives |
| **INFRA-1539** | RESILIENT | xs | Workflow guard sweep — proactive `runner.os == 'Linux'` guards on every sudo/apt/pip step |
| **INFRA-1556** | RESILIENT | s | Self-hosted runner deps contract — installer + smoke test + --upgrade flag | (shipping #2249 as of 2026-05-16) |

**Done test (Wave 0 → Wave 1 transition):**
- `scripts/ci/test-ac-coverage-gate.sh` exists on main + passes
- `scripts/ci/test-broad-canary-coverage.sh` exists on main + passes
- `scripts/ci/test-rust-first-bypass-gate.sh` exists on main + passes
- `scripts/ci/test-self-hosted-runner-deps.sh` exists on main + passes (INFRA-1556 done)
- `bash scripts/ci/test-workflow-linux-guard.sh` exists on main + passes (INFRA-1539 done)

**Cost of skipping ahead:** every Wave-1+ shell daemon or runner migration ships
with the SAME class of bug today's session discovered four times (chump-PATH,
apt-unguarded, pyyaml-unguarded, ACP-silent). Each costs a guard-fix PR, a
~5-min CI cycle, an emergency rollback, and ~30min of operator firefighting.

---

## Wave 0b — Fleet self-healing (autonomy loop)

**Must hit main before Wave 1.** Wave 0's gates *catch* failures at ship-time;
Wave 0b's loop *resolves* them at run-time without operator intervention.
Without 0b, the operator becomes the watcher-of-watchers (which is exactly
what happened today when M4 had no paramedic installed and #2255 sat DIRTY
for an hour).

| Gap | Pillar | Effort | What it gates |
|---|---|---|---|
| **INFRA-1594** | RESILIENT | s | `chump-fleet-bootstrap.sh --check` verifies paramedic + rebase-daemon + bot-merge-watchdog are registered (META-066 expansion) |
| **INFRA-1595** | RESILIENT | m | `chump fleet doctor --heal` — autonomous loop that auto-installs missing daemons + dispatches subagents for stuck PRs via `chump --execute-gap`. Launchd timer, 5min cadence, 3-subagent budget per 10min |
| **INFRA-1427** | INFRA | s | `chump fleet doctor --strict` — single command exits non-zero on any known issue (the diagnose layer INFRA-1595 wraps) |
| **INFRA-1410** | RESILIENT | m | PR-stuck SLO + auto-respawn — BLOCKED > 2h with no progress closes PR + respawns |
| **INFRA-1588** | RESILIENT | s | Pre-push hook SIGPIPE silent failure — every subagent shipping today hit this; without it, "auto-dispatch a subagent" cascades into "subagent silently fails to push" |

**Done test (Wave 0b → Wave 1 transition):**
- `com.chump.self-doctor` registered + actively healing across the entire fleet
- One synthetic "kill a daemon" test: kill `com.chump.paramedic` on a host, observe self-doctor re-install + restart within 10 minutes, emits `kind=self_doctor_healed`
- One synthetic "stuck PR" test: open a DIRTY PR, observe paramedic rebase OR self-doctor dispatch within 10 minutes
- `chump-fleet-bootstrap.sh --check` returns 0 on every chump host
- Pre-push hook regression test green

**Cost of skipping ahead:** operator continues to babysit stuck PRs and dead
daemons. Every "what about these 2 PRs" conversation operator surfaces is a
Wave 0b absence symptom. Velocity is capped at operator's vigilance, not
fleet capacity.

---

## Wave 1 — Migration completeness + per-lane control

**Depends on Wave 0.** With verification in place, finish what INFRA-1535
stage migrations started, plus add granular rollback so one broken lane
can't kill all four.

| Gap | Pillar | Effort | Why it's in Wave 1 |
|---|---|---|---|
| **INFRA-1538** | RESILIENT | m | Fix migration-pipeline gate-query bug (workflow .name vs job name) — pipeline can't auto-advance without this |
| **INFRA-1581** | RESILIENT | s | Backfill smoke tests for shell scripts under bypass — establishes behavioral baseline before Wave 2 ports them to Rust |
| **INFRA-1567** | RESILIENT | s | Split `CHUMP_SELF_HOSTED_ENABLED` into per-lane toggles — granular rollback (today's ACP cascade forced rolling back ALL 4 lanes) |
| **INFRA-1561** | RESILIENT | m | Fix `chump --acp` silent-stdout on M4 — the ONE broken lane that's keeping var=false now |
| **INFRA-1537** | ZERO-WASTE | m | Route `changes` paths-filter job to self-hosted — completes the migrated-lane story; without this every CI still queues on ubuntu-latest first |
| **INFRA-1540** | RESILIENT | l | Ghost-ship recovery — make sure all of ci.yml actually migrated, not just a subset (sibling-claimed, in flight as #2245) |
| **INFRA-1542** | RESILIENT | l | Phase 2 heavy CI cross-platform — clippy/cargo-test/coverage fan-out (sibling-claimed, in flight as #2247) |

**Done test (Wave 1 → Wave 2 transition):**
- All 4 self-hosted lanes (fast-checks, clippy, cargo-test, ACP) actively serve
  ≥ 50% of their jobs across 24 hours of real CI
- Per-lane toggle var allows rollback of any single lane without affecting others
- `chump-runner-migration-pipeline.sh --status` reports `stage_5_done`
- ACP smoke green on M4 across 10 consecutive PRs

**Cost of skipping to Wave 2:** the Rust port lands without a behavioral
baseline to match. Worse: the port replaces the gate-query bug without ever
verifying the original was caught.

---

## Wave 2 — Durability (port shell to Rust)

**Depends on Wave 1.** With migrations stable + tests in place, replace the
shell daemons with Rust under a single `chump runners` subcommand.

| Gap | Pillar | Effort | Why it's in Wave 2 |
|---|---|---|---|
| **INFRA-1579** | RESILIENT | l | Port migration pipeline + autoscale to `crates/chump-runner-orchestrator/`, exposed as `chump runners` subcommand. Shell shims become 3-line `exec` wrappers. |
| **INFRA-1535-autoscale** (slice) | RESILIENT | m | Already in flight as #2233; once Wave 1 verifies it works, port to Rust as part of INFRA-1579 — DO NOT ship a second shell version |

**Done test (Wave 2 → Wave 3 transition):**
- `chump runners migrate-status` returns the same data the shell version did
- `chump runners autoscale-tick` makes the same scale-up/scale-down decision the shell version did
- Both shell scripts archived under `scripts/coord/legacy/`
- Per-tick decision latency drops from ~2s to <100ms (measured)

**Cost of skipping to Wave 3:** scale-out work (Pi mesh, sustained 50/hr)
fights against shell-daemon brittleness that ports would have eliminated.

---

## Wave 3 — Capacity / scale-out

**Depends on Wave 2.** Now the platform can take more load without rework.

| Gap | Pillar | Effort | Note |
|---|---|---|---|
| **INFRA-1543** Pi mesh provisioner | RESILIENT | m | needs Pi 5 hardware racked (operator action) |
| **INFRA-1410** PR-stuck SLO + auto-respawn | RESILIENT | m | builds on Wave 1 stable lanes |
| **INFRA-1420** Auto-retrigger CI cascade | RESILIENT | m | builds on Wave 1 |
| **INFRA-1532** bot-merge self-watchdog + flock | RESILIENT | m | parallel to other Wave 3 work |
| **INFRA-1377** Merge Queue tier | INFRA | s | blocked on GitHub plan tier (operator decision) |

**Done test (Wave 3 → Wave 4 transition):**
- Sustained 50 PRs/hour across a 4-hour window
- No PR stuck > 30min under normal queue conditions
- 4+ Linux-ARM64 runners online + serving heavy jobs

---

## Wave 4 — Customer-facing & mission

**Depends on Wave 3.** With plumbing healthy, bias toward EFFECTIVE/MISSION
work per CLAUDE.md mission driver.

| Gap | Pillar | Effort |
|---|---|---|
| **INFRA-1486** Marcus per-gap budget trust gate | EFFECTIVE | (claimed in `ROADMAP_MARCUS.md`) |
| **INFRA-1483** Marcus canonical demo interface | EFFECTIVE | (claimed in `ROADMAP_MARCUS.md`) |
| **INFRA-1505** Telemetry opt-in with privacy contract | CREDIBLE | m |
| **INFRA-1502** Awesome-list placement | MISSION | s |
| **INFRA-1510** Payment infra spike | MISSION | s |

---

## How to use this doc

**For a worker picking a gap:**
1. Read the wave table. Identify which wave your candidate gap is in.
2. Check that all gaps in earlier waves are status=`done` on main.
3. If yes → claim normally. If no → pick from the earliest unfinished wave instead.

**For the operator reviewing roadmap shifts:**
1. A new gap gets filed → assign it to a wave AT FILING TIME (notes field is fine).
2. If a gap genuinely belongs in Wave N but Wave N-1 isn't done, it stays
   on the backlog, NOT in the pickable surface.

**For the picker (chump CLI):**
1. (Future, via INFRA-1582-or-similar) The picker reads this doc + filters
   pickable gaps to only those whose wave is "current."
2. Until that automation exists, this is a soft contract. Honesty discipline.

---

## What this doc replaces / supersedes

- The day-by-day plan in `ROADMAP_50_PER_HOUR.md` assumed capacity work could
  ship in parallel with the verification layer. **That assumption broke today.**
  This doc adds the explicit prerequisite ordering.
- This doc does NOT replace `ROADMAP_MARCUS.md` (customer arc) or
  `ROADMAP_BACKLOG.md` (design decisions). Those run in parallel to the
  wave order described here.

---

## Cross-references

- [`docs/ROADMAP.md`](../ROADMAP.md) — top-level entry, links here from "Today's bets"
- [`docs/strategy/ROADMAP_50_PER_HOUR.md`](ROADMAP_50_PER_HOUR.md) — capacity plan; reorder its Day 0/+1 sequence per Wave 0 prerequisites
- [`docs/strategy/ROADMAP_MARCUS.md`](ROADMAP_MARCUS.md) — customer arc, parallel
- [`docs/strategy/ROADMAP_INDEX.md`](ROADMAP_INDEX.md) — navigation
- [CLAUDE.md Mission Driver](../../CLAUDE.md#mission-driver--every-session-not-just-when-asked) — pillar balance + roadmap-before-gaps rule
