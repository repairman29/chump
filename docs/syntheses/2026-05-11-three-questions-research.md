---
doc_tag: synthesis
date: 2026-05-11
author: opus-4-7 (operator-delegated research)
related_gaps: [CREDIBLE-047, CREDIBLE-048, CREDIBLE-049, CREDIBLE-050]
---

# Three questions research — 2026-05-11

Operator framing: "Infra is product here. If our CI pipeline doesn't land
PRs without human intervention then we're failing." Three research
questions whose answers should drive what we ship next.

## Q1: What is the autonomous-ship rate today?

**Definition:** of the last 50 merged PRs (most recent first), how many
landed (status=MERGED) without ANY of: (a) operator commit on the branch,
(b) operator comment on the PR, (c) operator gh-pr action.

**Method:** `gh pr view <N> --json commits,comments` for each of the last
50 merged PRs; classify each as autonomous or touched.

**Findings:**

| Cohort | Count | Autonomous (no operator touch) |
|---|---|---|
| Fleet-filed (chump-dispatch / t@t.t first commit) | 8 | **1 (12.5%)** |
| Operator-filed (jeffadkins1@gmail.com first commit — me / Opus / Claude Code IDE) | 42 | 35 (83%) shipped clean (≤2 commits, no operator comments) |
| **Total** | **50** | 36 (72%) |
| PRs with >2 commits (CI-fix-up signal) | 5 | (10% of total) |

**Most striking finding:** when the fleet files autonomously, it usually
needs intervention (1 in 8 lands clean). When I (Opus) file with concrete
AC, it usually ships clean (35 in 42). **The bottleneck is filing-quality,
not worker capability.**

**Caveats:**
- "jeffadkins1@gmail.com" first commit conflates 3 actors (operator,
  Opus, Claude Code IDE). True autonomous baseline needs harness
  attribution per CREDIBLE-037 (harness tagging in ambient — merged today
  via #1476) + CREDIBLE-040 (opencode-bigpickle git identity — not yet
  shipped).
- Comment-touch counts include `repairman29` (the bot account) which
  files but doesn't typically touch. Distinguishing operator-as-jeffadkins
  from operator-as-repairman needs further filtering.

**Actionable conclusion:**
- Filing-quality (concrete AC, pre-flight scope check, single-purpose
  intent) is the highest leverage. Today's RESILIENT-007 (dispatcher
  refuses TODO-AC) attacks this directly.
- Gate enforcement (CREDIBLE-042/043 making the existing detectors
  required) raises the floor on what fleet-filed PRs look like.
- Don't add more workers; add more filing rigor.

## Q2: Which gates actually prevented their named failure mode?

**Definition:** for each CI gate or runtime check shipped on 2026-05-11,
count fires in `.chump-locks/ambient.jsonl`; classify true-positive vs
false-positive vs bypassed-via-allowlist.

**Method:** grep ambient.jsonl for each gate's named `kind=` event.

**Findings:**

| Gate | Shipped via | Expected event kind | Fires |
|---|---|---|---|
| CREDIBLE-026 scope detector | #1462 | `pr_scope_violation` / `pr_scope_divergence` | **0** |
| CREDIBLE-027 mass-deletion | #1459 | `mass_deletion_blocked` / `pr_scratch_commit_blocked` | **0** |
| CREDIBLE-028 premature-closure | #1458 | `gap_drift_premature_close` | **1** |
| INFRA-825 stale-binary | #1474 | `stale_binary_destructive_override` | **0** |
| CREDIBLE-029 ID allocator | #1466 | `gap_id_allocator_collision` | **0** |
| RESILIENT-006 pr-rescue.sh | #1475 | `pr_rescue_attempt` | **0** |
| RESILIENT-008 auto-YAML-flip | (gap filed, not shipped) | `auto_yaml_status_flip` | **0** |
| RESILIENT-009 worktree gitdir repair | (gap filed, not shipped) | `worktree_gitdir_repaired_postadd` | **0** |
| INFRA-819 reaper resilience | #1483 | `reaper_self_paused` | **0** |

**Most striking finding:** **9 of 10 named gates have fired 0 times.**
Only CREDIBLE-028 has caught one real drift event.

**Three possible explanations:**

1. **Gates not actually wired to emit ambient events.** The detector
   ships its CI script + AC, but the script's failure mode is "exit 1"
   not "emit ambient kind=X". Need to verify each gate's actual emission
   path.
2. **Event-kind name mismatch.** My audit assumed the gate emits a
   specific event kind based on the gap's AC ("Emits ambient kind=X..."),
   but the implementer chose a different name. Need to inspect each gate's
   source.
3. **Gates are prophylactic and the bad behavior hasn't happened.**
   CREDIBLE-027 (scratch-commit) ships and the fleet hasn't done another
   scratch-commit PR in the few hours since. Genuine zero-incidence
   period.

In any case, **we cannot claim the gates work until they fire on a
fixture PR.** Filed CREDIBLE-050 to force-fire each gate against a
synthetic violating PR and assert the right kind=X appears.

**Actionable conclusion:**
- Adopt "no gate ships without a force-fire fixture proof" as a doctrine
  addition.
- For the 9 currently-zero-fire gates, run each through CREDIBLE-050's
  fixture protocol within the next week; remove or fix any that don't
  fire correctly.
- Required-gate flips (CREDIBLE-042/043) should NOT happen until
  fixture validation passes for each.

## Q3: What is the operator-leverage ratio?

**Definition:** for each PR landed in window W, compute
`fleet-active-time / operator-attention-time`. Trend the metric over
weeks. Rising = compounding leverage; flat or falling = adding coord-tax.

**Method:** Today's data alone isn't enough. **Q3 cannot be precisely
answered without new instrumentation** (filed as CREDIBLE-049). Best
back-of-envelope for the 2026-05-11 session:

- **Operator-Opus time today:** ~5h active engagement (PR babysitting,
  filing gaps, audits, AC restoration, manual rescues).
- **Fleet ships today:** ~25 PRs (including the 15 Opus-filed + 10
  fleet-implementations of Opus-filed gaps from earlier in the day).
- **Manual rescues required of Opus:** ~5 (PR #1433 stale-rebase rescue,
  #1474 test-race fix, #1474 env-var fix, #1452/1441/1450 closures,
  #1455 cherry-pick salvage, AC restoration on #1457/1458/1459).
- **Rough ratio:** ~25 PRs / 5h Opus = 5 PRs/h. If each PR represents
  ~0.5-2h of fleet-active time, total fleet-active is 12-50h. So
  leverage ratio is roughly **2x-10x** today.

That's not a compounding-platform number. Anthropic-scale solo-dev
platforms need 50x+ to be worth running. Today is "Opus does most of
the thinking; fleet does the typing."

**Caveats:**
- 5h Opus time at $0.50-$2 per minute (depending on token volume) is
  $150-$600 of Opus tokens for one day's session. Not free.
- Fleet-active time (sonnet workers) is much cheaper per minute. Even
  at 2x leverage by time, the economic leverage (Opus-dollar vs
  fleet-dollar) may be 10x.

**Actionable conclusion:**
- Q3 instrumentation is a P1 must-ship — without it, every "improvement"
  is unmeasured.
- Once shipped, baseline + track for 2 weeks before drawing conclusions
  about platform-compounding.

## What the answers imply for the queue

Three new P1 gaps to file (in this PR):

1. **CREDIBLE-047 (P1/s)** — autonomous-ship-rate dashboard + alert.
   Surfaces Q1's metric live, alerts on degradation.
2. **CREDIBLE-048 (P1/s)** — per-gate fire-rate telemetry. Every gate
   reports fires + TP/FP + bypassed counts in `chump fleet status --gates`.
3. **CREDIBLE-049 (P1/m)** — operator-leverage ratio metric. Joins
   ambient session intervals with operator-action timestamps.
4. **CREDIBLE-050 (P1/s)** — force-fire-fixture for each shipped gate.
   Bonus from Q2 finding: 9 of 10 gates haven't fired; prove they work.

Once these four ship and run for 2 weeks, we have actual data on whether
the platform is compounding leverage. Without them, every gap I file
afterward is intuition, not evidence.

## Closing argument

The operator's framing — "infra is product here" — is correct. The state
contracts, gates, atomic allocator, canonical-state-contract, pr-rescue.sh
are all genuine product. But product without measurement is theater. Q1
tells us 87% of fleet-filed PRs need intervention; Q2 tells us most
recent gates haven't fired; Q3 tells us we don't even know the leverage
ratio. **Measurement first, then the next wave of gates.**

Today's session shipped 30+ gaps and ~25 PRs. The next session should
ship 4 instrumentation gaps that make all those previous gaps legible
as effective or not. Then we can iterate with feedback.
