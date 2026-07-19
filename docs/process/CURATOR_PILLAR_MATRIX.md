# Curator Pillar-Assignment Matrix

> MISSION-003. Filed after two operator directives 5 minutes apart on
> 2026-05-24: "we can't have lopsided focus" (18:18Z) and "not everyone on
> the team can play the same role" (18:20Z). The fleet had grown to ~8 alive
> curator sessions but pillar focus was ad-hoc — multiple sessions doing
> "general PR rescue" while CREDIBLE sat at 12% of pickable and ZERO-WASTE
> at 5%. This doc is the single canonical table: one primary pillar per
> named curator, no overlap, so pillar coverage is a property of the org
> chart, not luck.

## Scope

This matrix covers the **named curator roles** from the original 2026-05-24
directive — the ones with a dedicated wake loop and `.claude/agents/<role>.md`
role doc: `target`, `shepherd`, `ci-audit`, `handoff`, `decompose`,
`md-links`, `overnight`, `autopilot`, `orchestrator`. Roles productized later
under the META-097 sub-fleet umbrella (`curator-opus-architecture-coach`,
`curator-opus-context-keeper`, `curator-opus-historian`,
`curator-opus-incident-commander`, `curator-opus-roadmap-keeper`,
`curator-opus-scout`, `curator-opus-velocity-tracker`, `deliberator`,
`external-collab`, `fresh-eyes`, `harvester`, `infra-watcher`,
`observability`, `quartermaster`) are a separate cohort with their own lane
docs and are out of scope for the no-overlap enforcement below — they were
never part of the "8 alive sessions" the operator was pointing at.

## The table

| Curator | Primary pillar | Secondary pillar | Scope hard-boundary | Role doc |
|---|---|---|---|---|
| `target` | **EFFECTIVE** (Marcus arc) | — | Column-A demo target, INFRA-1318 Liaison Phase 2, META-074 children A/B/C, external-repo demo work. Does NOT do general PR rescue, CI decomposition, or handoff routing. | [`.claude/agents/target.md`](../../.claude/agents/target.md) |
| `shepherd` | **RESILIENT** (PR rescue + queue health) | — | General fleet rescue — stuck PRs, merge-queue wedges, cross-cutting drift. Not yet productized as a dedicated `.claude/agents/shepherd.md`; folded into `opus-shepherd-generalist` today. | — (pending META-097) |
| `ci-audit` | **CREDIBLE** (audit gates + agreement metrics) | — | CI failure decomposition, flake vs. logic-bug triage, trunk-red detection, grace-window/voice-lint policy. Does NOT rescue stuck PRs in general, route typed handoffs, or pick demo-target work. | [`.claude/agents/ci-audit.md`](../../.claude/agents/ci-audit.md) |
| `handoff` | *(null — coordination role, no pillar)* | — | Typed-contract routing (Decompose/CodeFix/GapReview), lease-collision discipline, META-069 dispatch decisions. Cross-lane by design; doesn't own a pillar outcome. | [`.claude/agents/handoff.md`](../../.claude/agents/handoff.md) |
| `decompose` | **EFFECTIVE-A2A** (META-074 child B + umbrella decomposition) | — | Two-phase decomposition pipeline — slicing umbrella gaps at claim time; stale-umbrella sweeps. | [`.claude/agents/decompose.md`](../../.claude/agents/decompose.md) |
| `md-links` | **RESILIENT-docs** (markdown + doc audits) | — | Broken internal/external link scans across `docs/**/*.md`, stale gap-ID reference audits. Reports and files gaps only — does not fix link targets itself. | [`.claude/agents/md-links.md`](../../.claude/agents/md-links.md) |
| `overnight` | **ZERO-WASTE** (legacy cleanup + staleness) | — | Off-hours cleanup sweeps, staleness audits, legacy-code retirement. Not yet productized as a dedicated `.claude/agents/overnight.md`. | — (pending META-097) |
| `autopilot` | **META-retirement** (META-090 endpoint) | — | Wizard-retirement criteria automation — the mechanism that eventually makes the `orchestrator` role operator-optional. Not yet productized as a dedicated `.claude/agents/autopilot.md`. | — (pending META-090/META-097) |
| `orchestrator` | **MISSION** (rank + dispatch + retire-self) | Coordinate/Retire/Command rings | Pulse-and-dispatch cycle management, keystone work, mission-ranking quality, self-retirement per OPERATOR_PLAYBOOK.md §8. Does NOT do lane-curator work or unilateral P0 promotion. | [`.claude/agents/orchestrator.md`](../../.claude/agents/orchestrator.md) |

## Enforcement

- **No-overlap CI gate**: [`scripts/ci/test-curator-pillar-no-overlap.sh`](../../scripts/ci/test-curator-pillar-no-overlap.sh) asserts no two role docs declare the same non-null `primary_pillar`. `handoff` is the one role allowed `null` (coordination, not a pillar owner).
- **Wake-logic uniformity**: [`scripts/ci/test-inbox-watcher-pattern.sh`](../../scripts/ci/test-inbox-watcher-pattern.sh) (INFRA-1936) asserts every present role doc arms a real-time inbox watcher as its first session action, per [`INBOX_WATCHER_PATTERN.md`](./INBOX_WATCHER_PATTERN.md) — no role should still be on a 5-minute cron poll.
- **Roles not yet productized** (`shepherd`, `overnight`, `autopilot`) are skipped (not failed) by both gates until their `.claude/agents/<role>.md` lands via a META-097 sub-fleet PR. When one lands, add its `primary_pillar` per the table above in the same PR.

## Done definition

Matrix doc shipped (this file) + CI gate enforces no-overlap + all checked-in agent `.md` files declare `primary_pillar` + `test-inbox-watcher-pattern.sh` green.
