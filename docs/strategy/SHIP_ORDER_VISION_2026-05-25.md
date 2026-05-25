# Ship Order Vision — Order the Gap Store by Wedge-Class Topology

**Authored:** 2026-05-25 by opus-curator-overnight
**Source evidence:** lived session 2026-05-24/25 — three trunk-RED waves, two duplicate PRs, one 18-hour ghost-work pile, six `graphql_exhausted` events in 60 seconds, a 4-day silent CI starvation, and ~6 retry-amend-rebase cycles personally observed.

## The thesis

**Priority (P0–P3) tells us _what matters_. Topology — dependency + wedge-class — tells us _in what order to ship_. We've been mixing them.**

When we file a P0 on top of broken infra, it sits BLOCKED, the queue grows, and the next P0 sits behind it. Convoy stall. The fix isn't more P0s; it's a shipping order that respects topology.

This doc proposes a 5-tier order, cited against today's lived evidence.

## Today's 10 confirmed wedge classes

| # | Wedge class | Evidence (this session) | Eliminator |
|---|---|---|---|
| 1 | Stale binary blocks destructive ops | INFRA-825 hit 2× — `chump gap ship` refused INFRA-1957 done-flip | JIT binary refresh OR scope INFRA-825 only to truly-destructive paths |
| 2 | `bot-merge` silent wedge on import title-similarity | bot-merge wedged 17 min after `chump gap import` returned "742 inserted, 2 blocked"; treated as fatal | INFRA-1939 (gap-import failure-class taxonomy) |
| 3 | `graphql_exhausted` debounce breaks when `resets_at:unknown` | 6 emits in 60s from `chump_gh` today | NEW gap: `chump_gh` debounce defaults to 60s when `resets_at:unknown` |
| 4 | Half-state required-checks | Voice-lint FAILED on PR #2561 but PR merged (not in required-checks); 2 banned terms now on main | INFRA-1395 grace window OR make Voice-lint required OR remove the check entirely — pick one |
| 5 | Force-push sweep by auto-rearm | PR #2561 closed mid-rebase by auto-merge re-evaluator | INFRA-1459 stale auto-merge detector + force-push intent signal |
| 6 | Repo-var stale-after-incident | `CHUMP_SELF_HOSTED_ENABLED=false` sat 4 days unrecovered after disk_critical | NEW gap: post-incident flag audit (or extend infra-watcher cadence) |
| 7 | Pre-push hook env-leak | INFRA-1950 (Guard 3 picked up Actions `GIT_DIR`) | **DONE today** as PR #2539 — this is the model fix |
| 8 | Duplicate PRs from claim race | #2539 (wizard) vs #2540 (shepherd Sonnet) both on INFRA-1950, 69s apart | META-105 RCA shipped today (#2550); next: PR-dedup-by-gap-id pre-claim check |
| 9 | Ghost work in main worktree | Harvester productize: 28 files / 6.4K LOC sat staged 18h, shipped as #2561 today | NEW gap: pre-session-end ghost detector (warn on staged work > 4h) |
| 10 | Subagent dispatch stalls | ci-audit + md-links subagents burned 144K + 157K tokens, zero artifacts | NEW gap: subagent watchdog — kill at wall-clock budget; emit `subagent_dispatch_timeout` |

**Rule:** before shipping any non-wedge gap from Tier 1+, the Tier-0 eliminators that share its infra dependency must already be on main.

## The 5-tier ship order

### Tier 0 — Wedge-class eliminators (ship FIRST regardless of priority)

A wedge class is a recurring failure mode that costs N follow-up gaps. Killing one eliminates the whole class. From the table above, the Tier-0 list (open, not yet shipped):

- INFRA-825 scope-narrow or JIT-refresh
- INFRA-1939 bot-merge silent wedge
- NEW: chump_gh debounce on unknown reset
- Voice-lint policy decision (Tier-2 overlap)
- INFRA-1459 stale auto-merge detector
- NEW: post-incident flag audit
- NEW: pre-session-end ghost detector
- NEW: subagent dispatch watchdog

**These are RESILIENT and ZERO-WASTE pillar work.** They don't add features. They prevent the next 5 ships from re-running the same wedges.

### Tier 1 — Cascade unblockers

A gap is Tier 1 if shipping it directly unblocks ≥3 other gaps in the queue.

- **INFRA-1923** ci-audit role productize — dormant. Once shipped, ci-audit owns INFRA-1395 + INFRA-1459 + voice-lint policy decision. Currently those sit unowned.
- **INFRA-1925** md-links role productize — dormant. Once shipped, doc-drift class becomes self-healing.
- **MISSION-005** PWA native A2A — filed today. Once shipped, the operator-facing surface stops being Claude-Code-only.

### Tier 2 — Half-state cleanups

A half-state gap is "feature shipped but its dependent / inverse / cleanup didn't ship." Zero per-day cost, but compounds.

- **INFRA-1962** voice-lint follow-up — my fix-commit `1f8fa47b6` was on a branch that got squashed without it; 2 banned terms now on main
- Voice-lint gate policy decision (overlaps Tier-0 #4) — currently fails-but-doesn't-block, the worst state

### Tier 3 — Foundation deliverables (new capability)

- META-097 umbrella — 4 curator productizations: **handoff DONE today** (#2514), **decompose DONE today** (#2529), **ci-audit OPEN**, **md-links OPEN**
- INFRA-1864 — Harvester per-file primitive indexing (follow-on to #2561 shipped today)

### Tier 4 — Velocity multipliers

Don't gate other tiers, but make daily picking faster:

- **Topology-aware picker:** `chump gap next` ranks by `(downstream-unblock-count × priority)` instead of priority alone
- **Wedge-class tag on gaps:** `chump gap set --wedge-class=binary-staleness` so reviewers can spot "this is the 4th gap of this class — file an eliminator instead"
- **PR-dedup-by-gap-id pre-claim:** before any curator claims a gap referenced in an active ALERT, check whether the gap already has an open PR (closes the META-105 collision class structurally)

## Daily picking heuristics

1. **Don't pick more than 3 PRs that touch a hot file** (`scripts/git-hooks/pre-push`, `.chump/state.db`, `scripts/coord/bot-merge.sh`, `.chump-locks/ambient.jsonl`) — rebase storm risk
2. **Don't start a feature whose Tier-0 dependency PR is BLOCKED** — wait or pick the eliminator instead
3. **Prefer claiming an already-failing PR's fix over filing new work** — closes the loop on someone else's wedge rather than adding to the queue
4. **Trunk RED → docs-only PRs only** — they bypass rust gates via the `changes` paths-filter (INFRA-1957 used this path today after WAVE 2 hit)
5. **End of session: verify no staged work older than 4h** — would have caught the 18-hour Harvester ghost

## What we explicitly STOP doing

- Filing P0s that depend on broken infra. The dependency check is the rule, not the priority field.
- Treating Voice-lint as both required-and-not-required. Pick one direction.
- Letting `chump claim` start a worktree without committing intent within 30 minutes — that's how ghost work accumulates.
- Force-pushing during an active auto-rearm window without explicitly dropping auto-merge first (gh pr merge --disable-auto, then push, then re-arm). Today's PR #2561 was force-pushed mid-rebase and got swept by the rearm daemon.

## Suggested next 5 ships (in order, with rationale)

1. **INFRA-1962** voice-lint cleanup — 2-line text fix, ships in 5 min, clears Tier-2 half-state from #2561
2. **NEW gap** — `chump_gh` debounce when `resets_at:unknown` — Tier-0 wedge-class eliminator. Today's 6-emit-per-minute noise burns operator attention and prompt cache.
3. **Voice-lint policy decision** — Tier-2 → resolve to "required" (and fix the 2 violations from today) OR "removed" (and drop the gate). Either is better than half-state.
4. **INFRA-1923** ci-audit role productize — Tier-1 cascade unblocker. Once ci-audit owns its lane, INFRA-1395 + INFRA-1459 + voice-lint policy + INFRA-1939 + future test-CI gates get owned by a single role instead of being orphaned.
5. **INFRA-1459** stale auto-merge detector — Tier-0 wedge-class eliminator for the force-push sweep that bit #2561 today. If ci-audit (from step 4) is alive, they own this; otherwise dispatch a Sonnet.

## Operator-facing measurement

After 1 week of this order, expect:
- Median PR `opened → merged` wall-clock drops (because cascade unblockers reduce convoy queues)
- `pr_stuck` events per day trend toward zero (because Tier-0 eliminators kill the recurrence)
- Ghost-work files at session start trend to zero (because heuristic #5 catches them)
- Duplicate PRs per week → 0 (because PR-dedup-by-gap-id structurally prevents the META-105 class)

The single-number health check operator can run any time:

```
chump health --slo-check && bash scripts/dev/wedge-cadence-chart.sh --since 7d
```

If both green, the order is working.

## What this doc is NOT

- Not a roadmap (see ROADMAP.md for that)
- Not a sprint plan (see ROADMAP_SPRINTS.md)
- Not a complete priority re-ranking (priorities are still operator-set)
- This is a **sequencing overlay** on top of the existing priority field

## Related docs

- `docs/strategy/PRODUCTIZATION_PLAN_2026-05-22.md` — what we're productizing
- `docs/strategy/DELIVERY_PLAN_2026-05-23.md` — critical-path framing
- `docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md` — lane assignments
- `docs/process/COLLISION_RCA_2026-05-24.md` (#2550) — the collision class this doc's Tier-4 PR-dedup-by-gap-id closes
- `docs/process/CURATOR_OPUS_LESSONS_2026-05-23.md` — verify-at-source discipline (cited inline)
- `docs/arsenal/HARVESTER.md` — Harvester role (the productize this doc cites as the model for finishing the other 4 curator lanes)
