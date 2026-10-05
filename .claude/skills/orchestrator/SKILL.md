---
name: orchestrator
description: Chump's wizard / orchestrator-opus role — execute the pulse-and-dispatch loop. Use to (1) read inbox for DMs from curator-opus-* sessions and the operator; (2) pulse the open-PR queue for a WEDGED/SATURATED/HEALTHY verdict; (3) check roadmap alignment against docs/ROADMAP.md; (4) emit a role-card so peer sessions can dedupe this physical session; (5) emit a heartbeat for liveness audit. **This skill is a thin wrapper over `scripts/coord/orchestrator-loop.sh`** (the harness-neutral CLI). The orchestrator does NOT do lane-curator work itself — it dispatches to target/handoff/ci-audit/shepherd/decompose/md-links via A2A directed dispatch. Examples that should trigger this skill: "run the wizard loop", "pulse the queue", "rank the gap store", "dispatch curators on roadmap-aligned work", "heartbeat from orchestrator".
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Agent
  - Monitor
---

# /orchestrator — Wizard Pulse-and-Dispatch Loop

The orchestrator (wizard) is the coordination role in Chump's role-scoped fleet — peer to 6 named curators (target / handoff / ci-audit / shepherd / decompose / md-links). The canonical surface is the harness-neutral shell CLI at `scripts/coord/orchestrator-loop.sh`. Any harness (Claude Code, opencode-bigpickle, codex, manual operator) invokes it the same way.

This slash command is a thin Claude-Code convenience that runs the pulse-and-dispatch protocol. The discipline lives at [`.claude/agents/orchestrator.md`](../../agents/orchestrator.md). Full operating model at [`docs/process/OPERATOR_PLAYBOOK.md`](../../../docs/process/OPERATOR_PLAYBOOK.md).

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → `scripts/coord/orchestrator-loop.sh tick`
- `pulse` → `scripts/coord/orchestrator-loop.sh pulse` (PR-queue verdict only)
- `inbox` → `scripts/coord/orchestrator-loop.sh inbox` (inbox triage only)
- `role-card` → `scripts/coord/orchestrator-loop.sh role-card`
- `heartbeat` → `scripts/coord/orchestrator-loop.sh heartbeat`
- `help` → `scripts/coord/orchestrator-loop.sh help`

```bash
scripts/coord/orchestrator-loop.sh $ARGUMENTS
```

Surface stdout from the script directly to the user — don't paraphrase. Exit codes are meaningful (0 = actionable — inbox items pending or queue non-HEALTHY; 1 = quiet; 2 = bad subcommand).

## The pulse-and-dispatch protocol

| Step | What | Source |
|---|---|---|
| 1 | Read inbox cursor for DMs from curators/operator | `orchestrator-loop.sh tick` phase 1 |
| 2 | Pulse the PR queue for WEDGED/SATURATED/HEALTHY verdict | `orchestrator-loop.sh pulse` |
| 3 | Check roadmap alignment against `docs/ROADMAP.md` | `orchestrator-loop.sh tick` phase 3 |
| 4 | If WEDGED: diagnose + rescue, OR directed-dispatch to the lane curator | Directed dispatch format (agent body) |
| 5 | If HEALTHY + slack: pull from `docs/process/WIZARD_STRATEGIC_BACKLOG.md` §1 | Loop-slack discipline |
| 6 | Emit role-card + heartbeat for liveness audit | `orchestrator-loop.sh role-card` / `heartbeat` |

## Lane scope (hard boundary)

The orchestrator owns gap-store ranking, directed A2A dispatch, keystone shipping, and self-retirement work. It does NOT:

- Free-claim lane-curator work (target/handoff/ci-audit/shepherd/decompose/md-links own their PRs)
- Solo-rescue a PR when the lane curator is alive
- Pick up novel work without operator or roadmap authorization

## Behavior rules

- **Surface text from the underlying script to the user directly.** Don't re-paraphrase `orchestrator-loop.sh` output.
- **Directed dispatch, never absorb.** For curator-lane work found during a pulse, send an A2A DM in the directed-dispatch format (see agent body) rather than doing the work yourself.
- **Roll-call before assuming curator availability.** Check ambient for recent curator-opus-* emits before dispatching into a possibly-dead inbox.
- **Cap each iteration at 12 minutes wall-clock.** If hit, broadcast STUCK and let the next tick retry.

## Cross-references

- [`scripts/coord/orchestrator-loop.sh`](../../../scripts/coord/orchestrator-loop.sh) — canonical CLI; thin dispatcher
- [`.claude/agents/orchestrator.md`](../../agents/orchestrator.md) — agent body with full discipline (4 rings, directed-dispatch format, retirement criteria)
- [`docs/process/OPERATOR_PLAYBOOK.md`](../../../docs/process/OPERATOR_PLAYBOOK.md) — operating model
- [`docs/process/WIZARD_STRATEGIC_BACKLOG.md`](../../../docs/process/WIZARD_STRATEGIC_BACKLOG.md) — loop-slack backlog
- [`docs/process/INBOX_WATCHER_PATTERN.md`](../../../docs/process/INBOX_WATCHER_PATTERN.md) — wake-on-message
- [`docs/architecture/TEAM_OF_AGENTS.md`](../../../docs/architecture/TEAM_OF_AGENTS.md) — team hierarchy
- [`.claude/skills/ci-audit/SKILL.md`](../ci-audit/SKILL.md) — sibling pattern (read for the productization template)
