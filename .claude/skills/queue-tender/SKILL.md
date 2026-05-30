---
name: queue-tender
description: Chump's PR-queue equilibrium curator (curator-opus-queue-tender role) — fire gh pr update-branch in parallel on all DIRTY PRs, snapshot queue state, verify daemon liveness, check trunk CI conclusion, and emit kind=queue_tend_tick. Use to (1) clear a DIRTY-PR backlog without waiting for shepherd's full classification cycle; (2) get a queue snapshot (open/blocked/dirty/behind/ships per hour); (3) spot-check daemon liveness for stale-pr-rebase-bot, integrator-daemon, trunk-red-detector, flake-detector; (4) emit a heartbeat so the orchestrator can confirm liveness. **This skill is a thin wrapper over `scripts/coord/queue-tender-loop.sh`** (the harness-neutral CLI). Examples that should trigger this skill: "rebase all dirty PRs", "clear the rebase backlog", "queue snapshot", "how many PRs are DIRTY right now", "heartbeat from queue-tender", "is trunk red", "check daemon liveness".
user-invocable: true
allowed-tools:
  - Bash
  - Read
---

# /queue-tender — PR-Queue Equilibrium Curator Loop

The queue-tender curator is one of the named Opus curators in Chump's role-scoped fleet. The canonical surface is the harness-neutral shell CLI at `scripts/coord/queue-tender-loop.sh`. Any harness (Claude Code, opencode, codex, manual operator) invokes it the same way.

This slash command is a thin Claude-Code convenience that runs the work-your-lane protocol. The discipline lives at [`.claude/agents/curator-opus-queue-tender.md`](../../agents/curator-opus-queue-tender.md). The operator directive is at [`docs/process/QUEUE_TENDER_DOCTRINE.md`](../../../docs/process/QUEUE_TENDER_DOCTRINE.md).

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → `scripts/coord/queue-tender-loop.sh tick`
- `heartbeat` → `scripts/coord/queue-tender-loop.sh heartbeat`
- `help` → `scripts/coord/queue-tender-loop.sh help`

```bash
scripts/coord/queue-tender-loop.sh $ARGUMENTS
```

Surface stdout from the script directly to the user — do not paraphrase. Exit codes are meaningful:
- `0` — success (tick fired and emitted, or heartbeat emitted)
- `1` — queue drained (0 open PRs; normal)
- `2` — bad subcommand or missing arg

## What one tick does

| Step | Action |
|---|---|
| 1 | `gh pr list --state open --limit 200` snapshot — counts open/blocked/dirty/behind/mergeable |
| 2 | Exits 1 + emits `queue_tender_queue_drained` if open=0 |
| 3 | Hysteresis filter — skips PRs rebased within last 300s |
| 4 | `gh pr update-branch <N> --rebase` in parallel (cap 20) on eligible DIRTY PRs |
| 5 | `launchctl list` liveness check for 4 expected fleet daemons |
| 6 | `gh run list --branch main --workflow ci.yml --limit 1` trunk conclusion read |
| 7 | Emits `kind=queue_tend_tick` with full payload to ambient.jsonl |

## Lane scope (hard boundary)

Queue-tender does NOT:

- Rescue stuck PRs — that is shepherd's lane
- Diagnose CI failures — that is ci-audit's lane (trunk RED is observed and emitted, not diagnosed)
- Pick gaps or file new ones — that is target/operator lane
- Admin-merge — that is operator authority (T1 gate)
- Dispatch Sonnet subagents — that is handoff's lane
- Re-arm auto-merge — that is auto-merge-rearm-daemon's lane

Refuses cross-lane work; emits `kind=queue_tender_lane_override` to ambient when override fires.

## Behavior rules

- **Surface text from the underlying script to the user directly.** Do not re-paraphrase `queue-tender-loop.sh` output.
- **Kill-switch is `CHUMP_SKIP_QUEUE_TENDER=1`.** If set, the tick exits 0 immediately with no side effects.
- **Daemon install is an operator action post-merge.** Do not run `install-queue-tender.sh` from within this skill invocation — that is a one-time operator step after the PR merges.
- **Cap each Claude-Code session at one explicit tick per invocation** unless the operator explicitly asks for repeated ticks. The launchd daemon handles recurrence; the skill is for on-demand operator use.

## Cross-references

- [`scripts/coord/queue-tender-loop.sh`](../../../scripts/coord/queue-tender-loop.sh) — canonical CLI
- [`.claude/agents/curator-opus-queue-tender.md`](../../agents/curator-opus-queue-tender.md) — full role discipline
- [`docs/process/QUEUE_TENDER_DOCTRINE.md`](../../../docs/process/QUEUE_TENDER_DOCTRINE.md) — operator directive
- [`scripts/setup/install-queue-tender.sh`](../../../scripts/setup/install-queue-tender.sh) — daemon install
- [`scripts/ci/test-queue-tender.sh`](../../../scripts/ci/test-queue-tender.sh) — 7-test CI gate
- [`.claude/skills/ci-audit/SKILL.md`](../ci-audit/SKILL.md) — sibling pattern (read for productization template)
