# Role-scoped fleet — migration vision (2026-05-23)

> **Decision-of-record.** Operator-set top strategic priority,
> 2026-05-23. Three-goal mandate kicks off the next 6 weeks of
> coordination-layer work and supersedes the per-PR tactical lease
> patching that dominated the prior 72 hours. Drafted by Opus curator
> (curator-opus-target-2026-05-23) under META-069 discipline.

## Operator priority statement (verbatim, 2026-05-23)

> *"we need 1) CI/QA to be 100% 2) a2a world class 3) owner by scope
> and role type/skill etc."*

Three goals, in priority order. This doc carries them through to a
6-week migration plan + 3 child gaps + an honest sunset clause.

## TL;DR

| Goal | Child gap | Owner role | Ship by |
|---|---|---|---|
| 1. CI/QA = 100% | [INFRA-1861](../gaps/INFRA-1861.yaml) | `curator-opus-ci-audit` | Week 4 |
| 2. A2A world-class | [INFRA-1862](../gaps/INFRA-1862.yaml) | `curator-opus-a2a` (promote from -handoff) | Week 5 |
| 3. Owner by role/skill | [INFRA-1863](../gaps/INFRA-1863.yaml) | `curator-opus-fleet` (new) | Week 6 |

Umbrella: [META-074](../gaps/META-074.yaml). Migration is strict-order
because each layer's correctness depends on the layer below being
trustworthy.

## Why now — the math

Today's 6-worker session produced **3 lease collisions in 4 hours** —
~50% collision rate. The collision count scales roughly as **N² / F**
(N = workers, F = unique hot files):

| Workers | Hot files | Predicted collisions/hr |
|---|---|---|
| 6 (today) | ~20 | 0.7–1.0 (matches observation) |
| 10 (near-term) | ~20 | 1.8 |
| 25 (mid-term) | ~20 | 11 |
| 50 (roadmap target) | ~20 | **45** |

At 50 workers the file-lease model is mathematically dead — we'd hit
collisions faster than the conflict-resolver could clear them. The
emergent **curator-opus-{role}** session split from today's sprint
(target / ci-audit / handoff / decompose / shepherd) IS the answer
pattern. This doc formalises it.

## Migration order (strict)

```
Week 1-4:   Child A — CI/QA 100% (INFRA-1861)
Week 4-5:   Child B — A2A world-class (INFRA-1862)
Week 5-6:   Child C — Owner-by-scope (INFRA-1863)
```

**Why this order is non-negotiable:**

1. **A2A coordination needs trustworthy CI signal.** If a peer agent
   reports "done" and CI was a false-positive, the receiver believes a
   lie. Coordination on false signal is worse than no coordination.
   → Child A must reach ≥95% before Child B starts.

2. **Owner-by-scope claims need A2A to coordinate the conflict-resolver
   outputs across agents.** Today's conflict-resolver (INFRA-1488,
   shipped) operates per-PR. To scale it across role-scoped overlapping
   work, we need delivery-guaranteed messaging (Child B) so the
   resolver's output reaches the right peer in time.
   → Child B must be live before Child C flips advisory-by-default.

3. **Skipping order = building on quicksand.** History rhymes: we
   filed INFRA-1687/1688/1689 on 2026-05-22 (the file-level tactical
   fixes) and they sat for 24-36h because every individual collision
   was small enough to patch tactically. Order discipline is the
   anti-tactical-drift forcing function.

## Child A — CI/QA = 100% (INFRA-1861)

**What "100%" concretely means**:

- Every CI failure represents a real defect (no flakes, no
  heuristic-false-positives like tonight's pr-hygiene PR-body regex)
- Every defect surfaces locally before push (`chump preflight` catches
  what CI catches, in <60s warm)
- When CI fails, the cause is immediately legible (no spelunking
  through cascade-cancellations)
- Audit-allowlist drift auto-detected + auto-fixed (no manual orphan-
  batch PRs like #2363, #2367, #2381 from tonight)

**Today's reproducer pain (3 examples)**:

1. PRs #2398 / #2399 / #2416 all failed cargo-test on **one
   root-cause syntax error** in `src/preflight.rs`. The 8-12 min CI
   cycle ran all 3 in parallel before surfacing the same error.
   Local preflight would have caught it in <60s.
2. PR #2418's `pr-hygiene` check failed on a regex that doesn't
   recognize PR-body mentions of deleted files — false positive.
3. Pre-push hook hangs forced `--no-verify` across the night.

**Measurement**: `kind=ci_qa_score` emitted hourly. Target ≥95% by
Week 4, 100% by Week 8.

## Child B — A2A world-class (INFRA-1862)

**What "world class" concretely means**:

- Typed events with strict schemas (today's `broadcast.sh` accepts the
  right event names but the field shapes drift — my STUCK at 18:54Z
  defaulted `reason` to "unspecified" on positional-arg misuse)
- Role-based capability discovery (Opus instances publish role + skills
  to a known KV; routers dispatch by skill match, not first-claim)
- Delivery guarantees (NATS push, replacing polling inboxes — partly
  staged by INFRA-1118 A2A Layer 1a)
- Atomic claim-handoff (no 10-30s hand-over gap)
- Audit trail for post-hoc analysis

**Today's reproducer pain**: cross-curator dispatch from
`curator-opus-ci-audit` to me at 21:33Z worked, but there's no
capability discovery — the dispatcher had no way to know if
`curator-opus-handoff` was a better fit. Lucky routing isn't
world-class routing.

## Child C — Owner by scope + role/skill (INFRA-1863)

**What "owner by scope and role/skill" concretely means**:

- `chump claim --role <role> --scope <module-or-concern>` — paths
  become **optional and advisory**, not the unit of ownership
- Append-only metadata files (`event-registry-reserved.txt`,
  `env-vars-internal.txt`, `EVENT_REGISTRY.yaml`) **never get leased**
  — the append-only merge driver already handles them
- Broad-scope leases (>1 directory in `--paths`) require explicit
  `--broad --reason '<text>'` — fixes tonight's META-071 trap
- Role registry at `docs/process/AGENT_ROLES.yaml` enumerates
  legitimate roles + their skill profiles
- Conflict-resolver (INFRA-1488, shipped) wired into `bot-merge.sh`
  auto-invoke on every conflicting push
- Migration: existing path-based claims continue to work; new
  role-based claims opt-in via `--role`; flip to advisory-by-default
  after 100 successful auto-resolutions

**Today's reproducer pain**: I needed a 5-line edit to
`scripts/coord/chump-commit.sh` for INFRA-1834; INFRA-1853 held a
4-hour lease on the file. Blocked. Meanwhile META-071 held three
directories at once. Both stops would be no-ops under role-scoped
claims.

## How tonight's sprint already proves the pattern works

The session log from 2026-05-23 had 5 Opus curators dispatched on
disjoint roles:

- `curator-opus-target` — Column A demo target selection
- `curator-opus-ci-audit` — CI gates inventory
- `curator-opus-handoff` — HandoffContract crate
- `curator-opus-shepherd` — PR queue shepherding
- `curator-opus-decompose` — chump ingest decomposition

Cross-curator dispatches succeeded (e.g. -ci-audit → -target for
INFRA-1834). Inbox/broadcast worked even with its rough edges. **The
hard part — agreeing on roles + dispatching by role — is already
empirically demonstrated.** Child C just turns this into the default.

## Honest sunset clause

If at the 6-week mark fewer than 2 children are done, file
META-NEXT-074 to re-scope and demote META-074 to P2. We do not let
this gap haunt the roadmap as a perpetual P0. The whole point is to
escape tactical-patch-only drift; the META gap itself can't be a
patch.

## Cross-references

- **Prior file-level tactical work** (still ships in parallel):
  - [INFRA-1687](../gaps/INFRA-1687.yaml) — decompose `src/main.rs`
  - [INFRA-1688](../gaps/INFRA-1688.yaml) — lease-as-advisory + auto-resolver
  - [INFRA-1689](../gaps/INFRA-1689.yaml) — AST-region claims
  - [INFRA-1748](../gaps/INFRA-1748.yaml) — main.rs decomposition pilot
- **Already-shipped substrate**:
  - INFRA-1115 — broadcast/inbox A2A channel
  - INFRA-1118 — A2A Layer 1a NATS-primary delivery (partial)
  - INFRA-1488 — conflict-resolver agent (Marcus M-C)
  - INFRA-1454 — agent-bash sandbox pilot
  - INFRA-1714 — pr-rescue v0
  - INFRA-1751 — pr-rescue v1b dirty-conflict handler
  - INFRA-1777 — pr-auto-rebase daemon
- **Roadmap context**: [docs/ROADMAP.md](../ROADMAP.md), Phase 4
  (Wave 4 — Customer-facing / agent quality)

## Process notes

META-069 discipline: this vision doc is Opus synthesis. The 3 child
implementations will delegate per-AC slices to Sonnet (CI/QA's
preflight-parity smoke; A2A's NATS push subscriber; OWNER's role
registry parser), with Opus reviewing the role-shape decisions. Each
child gap names its owning curator role in `notes:` so the dispatch
table is unambiguous.
