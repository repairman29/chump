---
name: target
description: Chump's demo-target curator (curator-opus-target role) — execute the work-your-lane loop for the demo-target + INFRA-1318 Liaison Phase 2 + META-074 child A/B/C umbrella lane. Use to (1) read inbox + advance active claim + pick next-best in lane, (2) decompose an umbrella into N sub-slices, (3) dispatch N Sonnet subagents in parallel via Agent tool per META-069, (4) babysit + surgical-rescue in-flight PRs that fail audit gates, (5) emit DONE on each ship. **This skill is a thin wrapper over `scripts/coord/target-loop.sh`** (filed as INFRA-1917 follow-up; this skill body is the discipline source-of-truth until that script lands). Examples that should trigger this skill, "work-your-lane", "advance my active claim", "dispatch sub-fleet on the remaining INFRA-1861 slices", "babysit PR #NNNN audit failure", "claim next-best from META-074 child A".
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Agent
---

# /target — Demo-Target Curator Loop

The Target curator is one of ~5 named Opus curators in Chump's role-scoped fleet (target / ci-audit / handoff / shepherd / decompose). The canonical surface will be the harness-neutral shell CLI at `scripts/coord/target-loop.sh` (filed under INFRA-1917 as a follow-up to this productization PR). Any harness (Claude Code, opencode, codex, manual operator) will invoke it the same way.

This slash command is a thin Claude-Code convenience that runs the 5-step work-your-lane protocol. The discipline lives at [`.claude/agents/target.md`](../../agents/target.md). The role-scoped fleet vision is at [`docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md`](../../../docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md).

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `loop` / `tick` → run the standard 5-step work-your-lane protocol once
- `dispatch <GAP-IDs csv>` → launch N parallel Sonnet subagents on the named gaps (META-069)
- `rescue <PR-N>` → babysit + surgical-rescue protocol for a specific PR
- `status` → print lane scope + active claim + last DONE broadcasts

```bash
# Until scripts/coord/target-loop.sh lands, dispatch as Agent(subagent_type=target).
# Once shipped, simple pass-through:
scripts/coord/target-loop.sh $ARGUMENTS
```

## The 5-step work-your-lane protocol

| Step | What | Source |
|---|---|---|
| 1 | Read inbox via `CHUMP_SESSION_ID=<sid> bash scripts/coord/chump-inbox.sh read` | INFRA-1115 |
| 2 | Advance active claim — rebase if DIRTY, retrigger if audit-cancel, ship if ready | bot-merge.sh + INFRA-028 manual recovery |
| 3 | If no active claim, pick next-best from inbox / THE_PATH / META-074 child sub-slices in lane | Lane scope hard-bound to 3 umbrellas |
| 4 | For Rust/tests/>150 LOC: dispatch Sonnet via Agent tool per META-069 SUBAGENT_DISPATCH.md | Self-implement only ≤100 LOC bash/markdown/yaml |
| 5 | Emit `DONE` to orchestrator on each ship via broadcast.sh | A2A discipline (INFRA-1115) |

## Lane scope (hard boundary)

The target curator claims work only inside these three umbrellas:

1. **Column-A demo target** — `docs/strategy/COLUMN_A_DEMO_TARGET_2026-05-23.md`
2. **INFRA-1318 Liaison Phase 2** — `docs/design/GITHUB_LIAISON.md`
3. **META-074 children A/B/C** — `docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md`

Refuses claims outside scope unless `CHUMP_TARGET_SCOPE_OVERRIDE=1`; emits `kind=target_scope_override` to ambient.jsonl when override fires.

## Behavior rules

- **Surface text from underlying scripts to the user directly.** Don't re-paraphrase chump-inbox.sh output, gh pr view output, or bot-merge.sh progress markers. Exit codes are meaningful.
- **Use the target curator voice when reporting.** Concise. Each tick reports state in 3 lines max when quiet. Verbose only when shipping or rescuing.
- **If the user asks for cross-lane work** (e.g. "rescue a stuck PR outside my scope"), refuse politely and route to the right curator (shepherd / handoff / etc.) via inbox.
- **Never bypass `scripts/coord/chump-commit.sh` for committing.** The `--no-verify` audit guard (INFRA-1834) requires `CHUMP_NO_VERIFY_REASON=<text>`.

## Cross-references

- [`.claude/agents/target.md`](../../agents/target.md) — the agent body with full discipline + protocols
- [`docs/architecture/TEAM_OF_AGENTS.md`](../../../docs/architecture/TEAM_OF_AGENTS.md) — team hierarchy
- [`docs/process/OPERATOR_PLAYBOOK.md`](../../../docs/process/OPERATOR_PLAYBOOK.md) — operator's directive surface
- [`docs/process/SUBAGENT_DISPATCH.md`](../../../docs/process/SUBAGENT_DISPATCH.md) — META-069 dispatch epilogue
- [`.claude/skills/harvester/SKILL.md`](../harvester/SKILL.md) — sibling pattern (read this first for the productization template)
