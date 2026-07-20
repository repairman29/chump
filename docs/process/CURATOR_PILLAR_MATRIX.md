# Curator Pillar Matrix (MISSION-003)

> **Status**: shipped 2026-07-19 (MISSION-003). Canonical single-table mapping
> from every checked-in curator role to its primary pillar, secondary scope,
> and hard boundary — plus the uniform event-driven wake-logic requirement.
> **Why it exists**: 2026-05-24 the fleet grew to ~8 alive sessions with
> ad-hoc pillar focus — overlap on "general PR rescue," gaps on CREDIBLE
> (12% of pickable) and ZERO-WASTE (5%). Operator: *"we can't have lopsided
> focus"* (18:18Z) + *"not everyone on the team can play the same role"*
> (18:20Z). This doc + its enforcing CI gate are the fix.

## The table

`primary_pillar` is the exact frontmatter value declared in each
`.claude/agents/<role>.md`. `null` is reserved for coordination roles that
route work across lanes rather than owning a pillar outcome.

| Role (`.claude/agents/<role>.md`) | `primary_pillar` | Scope hard-boundary |
|---|---|---|
| `target` | `EFFECTIVE` | Demo-target lane, Marcus arc, mission-ranking quality. NOT general PR rescue, CI decomposition, or handoff routing. |
| `ci-audit` | `CREDIBLE` | CI/test-gate decomposition, audit gates, agreement metrics, trunk-red detection. NOT general PR rescue or demo-target picks. |
| `handoff` | `null` (coordination) | Typed-contract dispatch routing + collision-safe leases. Cross-lane by design — no pillar owned. |
| `decompose` | `EFFECTIVE-A2A` | Umbrella → sub-gap slicing (META-074 child B + two-phase decomposition doctrine). NOT general fleet rescue or CI decomposition. |
| `md-links` | `RESILIENT-docs` | docs/**/*.md link + reference integrity. NOT content authoring — reports and files gaps only. |
| `orchestrator` | `MISSION` | Pulse-and-dispatch, keystone unwedging, self-retirement criteria. NOT lane-curator work — never solo-rescues a PR when a curator is alive on that lane. |
| `harvester` | `EFFECTIVE-cartography` | 76-repo arsenal catalog, Cross-Pollination Briefs, prior-art surveys. Does not write new product code. |
| `infra-watcher` | `RESILIENT-substrate` | Launchd daemon health, runner ghost-online, disk pressure, process bloat. Substrate only — not PR rescue or CI gates. |
| `observability` | `ZERO-WASTE-telemetry` | Ambient event-registry hygiene, reaper cadence coherence, api-cost leaderboard, detector-noise ranking. |
| `quartermaster` | `ZERO-WASTE-shelfware` | Shipped-but-unwired daemon/CLI/event audits, role-doc sync, PROCEDURES authoring. NOT PR rescue, CI gates, or gap slicing. |
| `external-collab` | `EFFECTIVE-customer` | Marcus customer-arc, operator-facing doc voice/freshness audits, partnership pipeline. Drafts only — operator decides. |
| `fresh-eyes` | `CREDIBLE-consistency` | Self-report vs. ground-truth mirror; one ranked finding per cycle. Read-only — never picks gaps or rescues PRs. |
| `deliberator` | `null` (coordination) | A2A vote tally + consensus_result emission. Cross-lane by design. |
| `curator-opus-architecture-coach` | `CREDIBLE-arch-fit` | Arch-fit rating (fit / stretch / fork) on queried gaps. Does not survey prior art (harvester's lane) or block without operator sign-off. |
| `curator-opus-context-keeper` | `RESILIENT-external-memory` | External-repo delta scans + maintainer-signal memory files. Does not file gaps (scout's lane). |
| `curator-opus-historian` | `ZERO-WASTE-lessons` | Structured lessons from shipped/reverted PRs + closed-as-not-a-bug gaps — prevents re-litigating solved problems. |
| `curator-opus-incident-commander` | `RESILIENT-incident` | Trunk-red incident coordination point. Does not decompose (decompose's lane) or write post-mortems (external-collab's lane). |
| `curator-opus-roadmap-keeper` | `MISSION-roadmap` | Roadmap priority-drift detection + re-ranking proposals via FEEDBACK. Never edits `docs/ROADMAP.md` directly — consensus required. |
| `curator-opus-scout` | `EFFECTIVE-external-discovery` | First-touch external-repo reads, proposes N gaps with confidence + source citation. Does not claim work or dispatch subagents. |
| `curator-opus-velocity-tracker` | `CREDIBLE-metrics` | P50 ship-time, throughput, flake-rate digests. Does not act on regressions (orchestrator's lane) or file gaps (decompose's lane). |

### Roles named in the operator's original 2026-05-24 directive without a checked-in `.claude/agents/*.md` file

These were part of the ~8-session background that triggered this gap but
run as loop scripts / cron sessions rather than declared subagent files —
tracked here so the intent isn't lost, not enforced by the CI gate (which
only scans `.claude/agents/*.md`):

| Role | Proposed `primary_pillar` | Notes |
|---|---|---|
| shepherd | `RESILIENT` | PR rescue + queue health. No `.claude/agents/shepherd.md` exists yet — productize via META-097 if a durable subagent file is warranted. |
| overnight | `ZERO-WASTE` | Legacy cleanup + staleness sweeps. |
| autopilot | `MISSION` (retirement-tracking) | META-090 endpoint — tracks wizard self-retirement criteria. |

## No-overlap rule

No two `.claude/agents/*.md` files may declare the same non-`null`
`primary_pillar` value. `null` is allowed to repeat (coordination roles).
Enforced by [`scripts/ci/test-curator-pillar-no-overlap.sh`](../../scripts/ci/test-curator-pillar-no-overlap.sh).

## Wake-logic uniformity

Every checked-in curator arms a session-start inbox watcher per
[`INBOX_WATCHER_PATTERN.md`](./INBOX_WATCHER_PATTERN.md) instead of relying
on a 5-minute cron poll. Enforced by
[`scripts/ci/test-inbox-watcher-pattern.sh`](../../scripts/ci/test-inbox-watcher-pattern.sh).

## Done definition

- [x] This matrix doc shipped
- [x] `scripts/ci/test-curator-pillar-no-overlap.sh` — CI gate, no two curators share a primary pillar
- [x] Every checked-in `.claude/agents/*.md` declares `primary_pillar` frontmatter
- [x] `scripts/ci/test-inbox-watcher-pattern.sh` — green across all checked-in agents
