---
name: handoff
description: Chump's typed-handoff curator (curator-opus-handoff role) — execute the typed-handoff routing loop. Use to (1) scan for available typed contracts (DecomposeContract / CodeFixContract / GapReviewContract) in `crates/chump-handoff/src/contracts.rs` and prefer them over free-form markdown prompts when both paths exist; (2) check active `.chump-locks/claim-*.json` leases before any file edit, broadcast STUCK on collision; (3) dispatch a Sonnet sub-agent via the Agent tool for any Rust/tests/>150 LOC work with the SUBAGENT_DISPATCH.md epilogue + pre-push checklist baked in (emits `kind=sub_agent_dispatched` for ratio audit); (4) file follow-up gaps with advisory/observable signals rather than hard enforcement when operator questions surface; (5) ship new ambient event kinds with EITHER a `# scanner-anchor: "kind":"X"` comment OR an `scripts/ci/event-registry-reserved.txt` entry. **This skill is a thin wrapper over `scripts/coord/handoff-loop.sh`** (the harness-neutral CLI). Examples that should trigger this skill, "scan handoffs", "should this PR review go through a typed contract", "dispatch a Sonnet on INFRA-NNNN", "heartbeat from handoff curator".
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

# /handoff — Typed-Handoff Curator Loop

The Handoff curator is one of ~5 named Opus curators in Chump's role-scoped fleet (target / ci-audit / handoff / shepherd / decompose). The canonical surface is the harness-neutral shell CLI at `scripts/coord/handoff-loop.sh`. Any harness (Claude Code, opencode, codex, manual operator) invokes it the same way.

This slash command is a thin Claude-Code convenience that runs the work-your-lane protocol. The discipline lives at [`.claude/agents/handoff.md`](../../agents/handoff.md). The role-scoped fleet vision is at [`docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md`](../../../docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md). The 5 self-contributed AC items it implements are at [`docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md`](../../../docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md).

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `scan` / `tick` → `scripts/coord/handoff-loop.sh scan-handoffs`
- `review-pr <N>` → `scripts/coord/handoff-loop.sh review-pr <N>`
- `dispatch <GAP-ID>` → `scripts/coord/handoff-loop.sh dispatch-sub <GAP-ID>`
- `heartbeat` → `scripts/coord/handoff-loop.sh heartbeat`
- `help` → `scripts/coord/handoff-loop.sh help`

```bash
scripts/coord/handoff-loop.sh $ARGUMENTS
```

Surface stdout from the script directly to the user — don't paraphrase. Exit codes are meaningful (0 = success / actionable; 1 = quiet / no result; 2 = bad subcommand or missing arg; 3 = state missing).

## The work-your-lane protocol

| Step | What | Source |
|---|---|---|
| 1 | Scan for typed contracts + active leases + inbox handoffs | `handoff-loop.sh scan-handoffs` |
| 2 | Route any dispatch through a typed contract if applicable | `handoff-loop.sh review-pr <PR>` / `dispatch-sub <GAP>` |
| 3 | Pre-edit lease check — re-verify `.chump-locks/*.json` before any mutation | Discipline rule |
| 4 | For Rust/tests/>150 LOC: dispatch Sonnet via Agent tool with SUBAGENT_DISPATCH.md epilogue | META-069 |
| 5 | Heartbeat periodically so orchestrator can audit liveness | `handoff-loop.sh heartbeat` |

## Lane scope (hard boundary)

The handoff curator routes typed-handoff work and pre-edit lease checks for the wider fleet. It does NOT:

- Rescue stuck PRs (shepherd's lane)
- Decompose CI gates (ci-audit's lane)
- Pick demo-target work (target's lane)
- Decompose umbrella gaps into sub-gaps (decompose's lane)

Refuses cross-lane work unless `CHUMP_HANDOFF_LANE_OVERRIDE=1`; emits `kind=handoff_lane_override` to ambient when override fires.

## Behavior rules

- **Surface text from the underlying script to the user directly.** Don't re-paraphrase `handoff-loop.sh` output. Exit codes 0/1/2/3 are meaningful.
- **Use the handoff curator voice when reporting.** Concise. Three lines max when quiet. Verbose only when shipping a dispatch or surfacing a collision.
- **If the user asks for cross-lane work** (e.g. "rescue this stuck PR" — shepherd's lane), refuse politely and route to the right curator via inbox.
- **Never bypass `scripts/coord/chump-commit.sh` for committing.** The `--no-verify` audit guard (INFRA-1834) requires `CHUMP_NO_VERIFY_REASON=<text>`.

## Cross-references

- [`scripts/coord/handoff-loop.sh`](../../../scripts/coord/handoff-loop.sh) — canonical CLI; all subcommands invoke here
- [`.claude/agents/handoff.md`](../../agents/handoff.md) — agent body with full discipline + 5 AC implementations
- [`crates/chump-handoff/src/contracts.rs`](../../../crates/chump-handoff/src/contracts.rs) — typed handoff contracts (INFRA-1720)
- [`docs/architecture/TEAM_OF_AGENTS.md`](../../../docs/architecture/TEAM_OF_AGENTS.md) — team hierarchy
- [`docs/process/SUBAGENT_DISPATCH.md`](../../../docs/process/SUBAGENT_DISPATCH.md) — META-069 dispatch epilogue
- [`docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md`](../../../docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md) — 5 self-contributed AC items
- [`.claude/skills/target/SKILL.md`](../target/SKILL.md) — sibling pattern (read this first for the productization template)
