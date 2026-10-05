---
name: shepherd
description: Chump's PR-rescue curator (curator-opus-shepherd role) — execute the shepherd work-your-lane loop. Use to (1) read inbox for shepherd-addressed DMs and operator-paged alerts; (2) run session-start triage (ghost-gap sweep, ambient signature stats, sibling-lease inventory, pickable diff, written game-plan); (3) run a PR-rescue tick (classify BEHIND/BLOCKED/DIRTY PRs and act — rebase, re-arm, file follow-up gap); (4) diagnose a cross-PR failure cluster and broadcast A2A to the owning lane before falling back to a GitHub comment; (5) emit a heartbeat so the orchestrator can audit shepherd liveness. **This skill is a thin wrapper over `scripts/coord/shepherd-loop.sh`** (the harness-neutral CLI). Examples that should trigger this skill: "rescue this stuck PR", "run shepherd triage", "unwedge the queue", "why is this PR BEHIND", "heartbeat from shepherd curator".
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

# /shepherd — PR-Rescue Curator Loop

The shepherd curator is one of ~5 named Opus curators in Chump's role-scoped fleet (target / ci-audit / handoff / shepherd / decompose). The canonical surface is the harness-neutral shell CLI at `scripts/coord/shepherd-loop.sh`. Any harness (Claude Code, opencode-bigpickle, codex, manual operator) invokes it the same way.

This slash command is a thin Claude-Code convenience that runs the work-your-lane protocol. The discipline lives at [`.claude/agents/shepherd.md`](../../agents/shepherd.md). Full protocol details at [`docs/process/SHEPHERD_LOOP_PLAYBOOK.md`](../../../docs/process/SHEPHERD_LOOP_PLAYBOOK.md).

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → `scripts/coord/shepherd-loop.sh tick`
- `audit` → `scripts/coord/shepherd-loop.sh audit` (triage only, no rescue actions)
- `rescue` → `scripts/coord/shepherd-loop.sh rescue` (PR-rescue tick only)
- `heartbeat` → `scripts/coord/shepherd-loop.sh heartbeat`
- `help` → `scripts/coord/shepherd-loop.sh help`

```bash
scripts/coord/shepherd-loop.sh $ARGUMENTS
```

Surface stdout from the script directly to the user — don't paraphrase. Exit codes are meaningful (0 = actionable / success; 1 = quiet / no result; 2 = bad subcommand).

## The work-your-lane protocol

| Step | What | Source |
|---|---|---|
| 1 | Read inbox for shepherd-addressed DMs and WARN/STUCK broadcasts | `shepherd-loop.sh tick` phase 1 |
| 2 | Session-start triage: ghost-gaps, ambient stats, leases, pickable diff, game-plan | `shepherd-loop.sh audit` |
| 3 | Classify + act on open PRs (BEHIND rebase, BLOCKED_GREEN re-arm, BLOCKED_REAL_FAIL follow-up gap) | `shepherd-loop.sh rescue` |
| 4 | On cross-PR cluster: A2A broadcast to lane owner first, GH comment fallback after 1 cycle | Pattern 0 (INFRA-1932) |
| 5 | Heartbeat periodically so orchestrator can audit liveness | `shepherd-loop.sh heartbeat` |

## Lane scope (hard boundary)

The shepherd curator owns general PR rescue. It does NOT:

- Decompose CI failure clusters into flake/logic-bug/missing-gate buckets (ci-audit's lane)
- Route typed-handoff contracts (handoff's lane)
- Pick demo-target work (target's lane)
- Slice umbrella gaps into sub-gaps (decompose's lane)

## Behavior rules

- **Surface text from the underlying script to the user directly.** Don't re-paraphrase `shepherd-loop.sh` output.
- **A2A first, GitHub comment fallback** (Pattern 0, INFRA-1932) — never open with a public GH comment when the lane owner has an inbox.
- **If the user asks for cross-lane work** (e.g. "decompose this CI cluster" — ci-audit's lane), refuse politely and route to the right curator via inbox.
- **Respect per-tick action caps** — `pr-shepherd-daemon.sh` enforces max rebases/arms/gaps/admin-merges per tick; don't bypass by calling `gh` directly.

## Cross-references

- [`scripts/coord/shepherd-loop.sh`](../../../scripts/coord/shepherd-loop.sh) — canonical CLI; thin dispatcher
- [`.claude/agents/shepherd.md`](../../agents/shepherd.md) — agent body with full discipline
- [`docs/process/SHEPHERD_LOOP_PLAYBOOK.md`](../../../docs/process/SHEPHERD_LOOP_PLAYBOOK.md) — full protocol (Pattern 0 A2A-first, wedge taxonomy)
- [`docs/process/OPUS_SHEPHERD_PLAYBOOK.md`](../../../docs/process/OPUS_SHEPHERD_PLAYBOOK.md) — Opus-specific triage protocol
- [`docs/architecture/TEAM_OF_AGENTS.md`](../../../docs/architecture/TEAM_OF_AGENTS.md) — team hierarchy
- [`.claude/skills/ci-audit/SKILL.md`](../ci-audit/SKILL.md) — sibling pattern (read for the productization template)
