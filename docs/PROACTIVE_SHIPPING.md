# Proactive Shipping

Patterns for Chump to identify and ship valuable work without explicit user instruction. This is what separates an agent that executes commands from one that drives a project forward.

See [CHUMP_BRAIN.md](CHUMP_BRAIN.md) for the brain directory structure that enables this.

## What proactive shipping looks like

During a ship heartbeat round, Chump:
1. Reads `brain/notes/` for flagged items and pending ASK_JEFF responses
2. Reads `docs/gaps.yaml` for open P1 gaps with no active lease
3. Checks `ambient.jsonl` for recent failures or stuck agents
4. Picks the highest-leverage unblocked gap
5. Claims it, implements, ships without waiting to be asked

This is the behavior driven by the `ship` round in `heartbeat-ship.sh`.

## Conditions for proactive work

Chump picks up proactive work when:
- `CHUMP_AUTONOMY_MODE=1` (or `autonomy_once` flag set)
- No conflicting lease exists
- Gap is P1 or P2 with S/M effort
- `gap-preflight.sh` exits 0
- Session budget (`INFRA-COST-CEILING`) allows another run

## Guardrails

Proactive shipping is bounded by:
- **Gap preflight**: never start work on a done or actively-claimed gap
- **PR size limit**: ≤5 commits, ≤5 files per PR (CLAUDE.md hard rule)
- **Spend cap**: `INFRA-COST-CEILING` (in-queue) hard-stops runaway agents
- **Peer approval**: `CHUMP_PEER_APPROVE_TOOLS=git_push,merge_pr` requires Mabel sign-off before merge
- **Merge queue**: GitHub merge queue serializes auto-merges atomically

## What Chump proactively ships well

Based on soak run 1 (36h, 24 PRs):
- Documentation gaps (low risk, no build impact)
- Eval fixture runs (read-only until results land)
- Config and env fixes
- Test coverage for existing code

## What requires explicit authorization

- Changes to `src/` (risk of breaking build; triggers code-reviewer gate)
- Changes to `scripts/` (can affect all agents)
- Dependency bumps (`Cargo.toml`)
- Changes to `CLAUDE.md` or coordination docs

## Failure modes

| Failure | Cause | Prevention |
|---------|-------|------------|
| Duplicate gap work | Two sessions claim without checking | Lease files + gap-preflight |
| File stomp | Git pull overwrites uncommitted edits | Commit every 30 min; chump-commit.sh |
| Runaway spend | Long loop with cloud calls | INFRA-COST-CEILING (in-queue) |
| "Your Name" pushes | Non-agent identity outside coordination | Identity guard in pre-commit hook |

## See Also

- [AGENT_COORDINATION.md](AGENT_COORDINATION.md) — full coordination system
- [OPERATIONS.md](OPERATIONS.md) — heartbeat scripts
- [SOAK_72H_LOG.md](SOAK_72H_LOG.md) — observed proactive shipping behavior
- [CHUMP_BRAIN.md](CHUMP_BRAIN.md) — brain directory structure
