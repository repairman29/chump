# Curator Pillar-Assignment Matrix (MISSION-003)

Canonical table mapping each named curator role to its primary pillar,
secondary pillar, and scope hard-boundary. Filed after two operator
directives 5 minutes apart on 2026-05-24: "we can't have lopsided focus"
(18:18Z) + "not everyone on the team can play the same role" (18:20Z) — the
fleet had grown to ~8 alive sessions with ad-hoc pillar focus (CREDIBLE at
12% of pickable, ZERO-WASTE at 5%, overlapping "general PR rescue" work).

Pillars: **EFFECTIVE** / **CREDIBLE** / **RESILIENT** / **ZERO-WASTE** (see
root `CLAUDE.md`). A role with primary_pillar `null` is a coordination role
(routes work between lanes, doesn't own a pillar itself).

| Role | Primary pillar | Secondary pillar | Scope hard-boundary | Status |
|---|---|---|---|---|
| `target` | EFFECTIVE | — | Column-A demo target, INFRA-1318 Liaison Phase 2, META-074 children A/B/C, external-repo demo work, mission-ranking quality | shipped (`.claude/agents/target.md`) |
| `shepherd` | RESILIENT | — | PR rescue + merge-queue health | not yet productized (META-097) |
| `ci-audit` | CREDIBLE | — | CI failure decomposition (flake/logic-bug/missing-gate), grace-window + voice-lint policy, trunk-red detection | shipped (`.claude/agents/ci-audit.md`) |
| `handoff` | null (coordination) | — | Typed-contract routing between lanes, collision-safe file edits, META-069 dispatch decisions | shipped (`.claude/agents/handoff.md`) |
| `decompose` | EFFECTIVE-A2A | EFFECTIVE | META-074 child B (A2A world-class) + umbrella-gap decomposition | shipped (`.claude/agents/decompose.md`) |
| `md-links` | RESILIENT | — | Markdown link integrity + doc audits (docs-as-substrate hygiene) | shipped (`.claude/agents/md-links.md`) |
| `overnight` | ZERO-WASTE | — | Legacy cleanup + staleness sweeps | not yet productized (META-097) |
| `autopilot` | null (coordination) | — | META-090 fleet-autopilot endpoint | not yet productized (META-097) |
| `orchestrator` | MISSION | — | Rank + dispatch + self-retirement (wizard role); cross-cutting, not lane-scoped | shipped (`.claude/agents/orchestrator.md`) |

Roles outside this list (`harvester`, `infra-watcher`, `observability`,
`quartermaster`, `fresh-eyes`, `external-collab`, `deliberator`, and the
`curator-opus-*` specialists) are out of scope for this matrix — they
predate or sit outside the 2026-05-24 operator directive's named 9-role
set and declare their own lanes in their respective `.claude/agents/*.md`
frontmatter.

## Enforcement

- **No-overlap gate**: `scripts/ci/test-curator-pillar-no-overlap.sh` — no
  two `.claude/agents/<role>.md` files in the 9-role set above may declare
  the same non-null `primary_pillar`. `handoff` and `autopilot` are exempt
  (coordination roles, `primary_pillar: null`).
- **Wake-logic uniformity**: `scripts/ci/test-inbox-watcher-pattern.sh`
  (INFRA-1936) — every present role file must declare the session-start
  Monitor-arm block per
  [`INBOX_WATCHER_PATTERN.md`](./INBOX_WATCHER_PATTERN.md). Roles not yet
  productized (`shepherd`, `overnight`, `autopilot`) are skipped, not
  failed, until their `.claude/agents/*.md` lands via META-097.

## Done definition

1. This matrix doc shipped.
2. `test-curator-pillar-no-overlap.sh` green.
3. Every checked-in `.claude/agents/*.md` in the 9-role set declares
   `primary_pillar` in frontmatter.
4. `test-inbox-watcher-pattern.sh` green for all present role files.
5. Linked from `OPERATOR_PLAYBOOK.md` §1 Hierarchy.
