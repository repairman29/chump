# THE FLOOR — foundational plan for 50/hr to feel boring

**Status:** Plan-for-sign-off (2026-05-25)
**Owner:** Opus (drafter), operator (decider)
**Tracked as:** META-NNN (umbrella) — sub-gaps INFRA-1987 through INFRA-1996
**Companion doc:** `docs/process/WEDGE_CLASS_CATALOG.md`

---

## The problem in one paragraph

We can ship gaps. We can run an autopilot. We can spawn workers. We cannot do those things ON TOP OF A FLOOR THAT WOBBLES. Today's evidence: a pre-push hook regression that silently disabled force-push race protection for 3 days; an env-var injection (mine) that cascaded into 17 broken tests; a 5-PR pile-up that needed Opus + admin-merge authorization to unstick; and a wedge catalog of 13 classes we've discovered ONE AT A TIME, by tripping on them. At 2 agents we average 9-11 merges/hr in bursts. At 25× that we don't get 25× the throughput — we get 25× the pile-ups, because the autopilot scales the work, not the resilience. **Scaling agents on a wobbly floor produces failure modes that scale faster than throughput.**

## What "the floor" means

A set of structural primitives such that:

- Adding agents adds throughput, not pile-ups
- Silent failures (hooks that exit 0 without doing their job, daemons that "run" but do nothing, env overrides that hijack unrelated paths) are auditable surfaces, not invisible ones
- Recovery from common wedge classes is automated; manual `bash -x` archaeology is the exception, not the routine
- The operator doesn't have to be online for the fleet to unstick itself
- Agents learn from each other — knowledge gained from one wedge propagates to all future agents before they pick their next gap

When the floor is solid: 50/hr is boring. Until then: 50/hr is heroic.

## The 7 floor items

### 1. Floor-temperature signal (INFRA-1992)
**Effort: s · Phase 1**

Every agent prompt reads `chump health --temp` before picking work. Returns `COLD` | `WARM` | `HOT`:
- COLD: <1 silent regression in 24h, <1 trunk-RED in 2h, 0 admin-merges in 2h → ship aggressively
- WARM: 1-2 of the above → file no new shell glue, prefer Rust, double-verify
- HOT: ≥3 of the above → only low-risk gaps (xs effort, docs, single-file), no env-mutating work

One ambient field (`kind=floor_temp`), one CLI command, one prompt-template change. Converts "every agent ships at max risk all the time" into adaptive throttling. **Smallest unit-change, largest behavior-change.**

**Status: 100% wired (INFRA-2008).** `scripts/dispatch/worker.sh` sources
`scripts/dispatch/lib/floor-readers.sh` before every claim cycle, which reads
both this signal and fleet-hold (item 2) and exports `CHUMP_FLOOR_TEMP` /
`CHUMP_FLEET_HOLD` for the loop and any spawned subagent (contract documented
in `docs/process/SUBAGENT_DISPATCH.md`). Verified by
`scripts/ci/test-worker-prelude-floor-signals.sh`.

### 2. Cluster-first autopilot (INFRA-1987)
**Effort: s · Phase 1**

When ≥3 open PRs fail the IDENTICAL check-set within 30 min, the bug is in TRUNK or a shared layer, not the individual PRs. Today's autopilot retries individual PRs — burning CI minutes against a wall. Cluster detector emits `kind=ci_failure_cluster`, auto-HOLDs ship across the fleet, auto-files an RCA gap. Workers read the HOLD and switch to non-shipping work (docs, tests, gap triage).

### 3. Silent-failure tax (INFRA-1988 + INFRA-1990)
**Effort: m · Phase 2**

Anywhere shell does `2>/dev/null || true`, Rust does `.unwrap_or_default()`, or a hook can `exit 0` without doing its main loop = a silent-failure surface. The pre-push regression existed because `exit 0` was too easy. CI audit counts these surfaces, budgets them, and requires `# Silent-OK-Reason: <one sentence>` comments on new ones. New surfaces fail CI without the justification trailer.

Also: hook-stdin-drain audit gate (INFRA-1990) — specific to the pattern we just hit. Counts `while.*read.*local_sha` loops; fails if >1 in any hook without `_HOOK_STDIN` cache.

### 4. Cluster RCA + blame bot (INFRA-1989)
**Effort: s · Phase 1**

When a CI test goes from green to red with no test-file change, auto-`git blame` the related production paths since the last green run. Post the suspect commit ID + diff range as a comment on the cluster RCA gap. Converts 50 min of `bash -x` archaeology into 30 sec of "here's the suspect." Pairs with cluster detector (item 2).

### 5. Recovery without Opus on duty (INFRA-1993)
**Effort: l · Phase 3**

Admin-merge cycle (drop required gates → merge → re-arm) requires me (Opus) + the operator's "you have the bridge" authorization. When neither of us is online, every wedge stays wedged for hours. Worker agents need a queued recovery channel: emit `kind=operator_recovery_requested` ambient event with reason + cluster gap ID; automation services it with rate limits (max 3/hour fleet-wide) + audit trail + ambient `kind=operator_recovery_executed` on completion. The bridge becomes a queue, not a person.

### 6. Wedge catalog as executable state machine (INFRA-1994)
**Effort: l · Phase 3**

We have 13 W-NNN classes documented. Each is a doc with a "playbook" section. They should be: `detector_fn() + auto_trigger + remediation_playbook + escalation_policy` — code, not prose. `scripts/coord/wedge-watch.sh` is the start with 7 detectors. Refactor all 13 wedge classes to ship a detector + a remediation function. When the signature fires, the remediation runs (subject to rate limits + the operator recovery queue from item 5).

### 7. Single-pane fleet pulse (INFRA-1995)
**Effort: m · Phase 2**

Today, to understand "what's happening?" the operator (or I) query 5 surfaces: `chump health`, `chump fleet status`, `tail .chump-locks/ambient.jsonl`, `gh pr list`, `tmux ls`. Single command: `chump fleet pulse` returns one screen with floor temp + active leases + PR queue + autopilot daemon health + last 5 wedge fires + last 5 admin-merges + last 5 alerts + 4-pillar ship rates last hour. Web endpoint `/api/fleet/pulse` for PWA. **Operators cannot manage what they cannot see in one frame.**

## Dependency graph

```
Phase 1 (Week 1) — observation primitives, no behavior change yet
  ├─ INFRA-1992  Floor-temperature signal           (s)
  ├─ INFRA-1987  Cluster-first detector             (s) — emits only, no HOLD yet
  └─ INFRA-1989  Blame bot                          (s)

Phase 2 (Week 2) — behavior change, fed by Phase 1 data
  ├─ INFRA-1988  Silent-no-op alarm (hooks)         (xs)
  ├─ INFRA-1990  Hook stdin-drain CI gate           (xs)
  ├─ INFRA-1996  Silent-failure tax (audit + gate)  (m) — depends on 1988+1990 patterns
  ├─ INFRA-1995  Single-pane fleet pulse            (m) — reads floor temp + cluster events
  └─ Cluster detector v2: auto-HOLD on N≥3 cluster fires (extends INFRA-1987)

Phase 3 (Week 3) — automation + delegation
  ├─ INFRA-1993  Recovery queue (replaces Opus-on-duty)  (l)
  └─ INFRA-1994  Wedge catalog → executable state machine  (l)
```

Phase 1 alone (3 small gaps, ~1 day work each) gives us OBSERVATION — we can see when the floor is HOT, we can see when a cluster is forming, we can see the suspect commit. Phase 1 is the minimum viable floor.

Phase 2 turns observation into AUTOMATIC BEHAVIOR — agents throttle on HOT, autopilot pauses on clusters, new silent-failure surfaces fail CI.

Phase 3 lets the fleet RECOVER WITHOUT US.

## Success criteria (measurable, not aspirational)

| Metric | Today | Floor-solid target |
|---|---:|---:|
| Time to detect a pile-up | 15-30 min (operator-noticed) | <2 min (auto) |
| Time to attribute a regression to a commit | 15-50 min (`bash -x` manual) | <5 min (blame bot) |
| Time to unstick a pile-up without Opus on duty | infinite | <15 min (recovery queue) |
| Silent-failure surfaces in production paths | unknown (≥1 just shipped for 3 days) | 0 unannotated; audited count |
| % of agent picks that read floor temp before claim | 100% (INFRA-2008, `scripts/dispatch/worker.sh` prelude) | 100% |
| Wedge classes with detector + automatic remediation | 7 of 13 (detector only) | 13 of 13 (both) |
| Operator queries to understand fleet state | 5 surfaces | 1 (`chump fleet pulse`) |
| Mean time between admin-merge cycles needed | ~30 min (today) | >4 hours (target) |

## What's NOT in the floor

Explicitly out of scope here (to keep the floor scoped + shippable):

- **More wedge-class fixes** — these are infinite; the floor is the META-LAYER that catches the next class
- **More tests** — tests catch what they're written for; the floor catches the unknown
- **Scaling to 4 / 8 / 16 workers** — premature until floor is solid; scaling on a wobbly floor produces worse outcomes
- **Cross-machine sync improvements** — orthogonal; FLEET-006 NATS work is its own track
- **PWA polish** — `chump fleet pulse` includes a web endpoint, but visual cockpit work is separate
- **Marcus customer-arc work** — different lane

## Timeline + first 24h plan

**First 24h:** Ship Phase 1 (3 small gaps). All three are `s` effort. Even at 11/hr autopilot baseline that's a half-day of focused work. After Phase 1 we have OBSERVATION; everything downstream depends on the data Phase 1 starts collecting.

**Week 1:** Phase 1 + early Phase 2 (silent-no-op alarm, hook stdin gate). Floor is starting to harden but no auto-HOLD yet.

**Week 2:** Phase 2 complete. Cluster auto-HOLD live. Single-pane pulse live. Silent-failure tax enforced.

**Week 3:** Phase 3. Recovery queue. Wedge catalog as state machine. By end of Week 3 the floor is solid enough that scaling agents BEYOND 2 stops introducing new pile-up classes.

**At Week 3 + 1 day:** scale-up trial to 4 agents. C-V3 measurement. If sustained 25+ merges/hr without a pile-up requiring Opus intervention, we know the floor held. If not — the diff from 11/hr to 25+ reveals the next floor crack, which becomes the next plan.

## The honest tradeoff

Each phase costs ~1 week. We can keep shipping individual wedge fixes in parallel — they're cheap (xs/s) and they keep the immediate floor functional. But the structural work is what unlocks scale. **If we skip the floor and scale to 4 agents now, we will spend the next 2 weeks firefighting pile-ups and net out worse than 2 agents on a solid floor.**

The pre-push hook silent-regression was a free preview of what happens at higher agent counts: multiple agents pushing through a hook that silently returns 0 = silent corruption of branch protection across the fleet. We got lucky it manifested as "Test 1 FAIL" instead of "sibling clobbered." The next class is one bad commit away from data loss.

## How this doc evolves

- Operator signs off (or revises) this plan; we adopt the canonical phasing
- Each shipped floor item gets a one-line entry in §Success criteria with the actual measured impact
- Wedge catalog updates ripple into §6 as detectors are added
- At the end of Week 3, write the FLOOR_RETROSPECTIVE.md companion doc with: what we learned, what we'd do differently, where the next crack is

## Refs

- `docs/process/WEDGE_CLASS_CATALOG.md` — current 13-class catalog
- `docs/case-studies/2026-05-25-wedge-recovery.md` — 4-hour wedge case study (MISSION-006)
- `docs/process/AUTOPILOT_MODEL.md` — current autopilot two-layer model (MISSION-007)
- `docs/process/CLAUDE_GOTCHAS.md` — runbook for operational gotchas
- Today's pile-up RCA: INFRA-1986 (the 3-day pre-push regression that catalyzed this plan)
