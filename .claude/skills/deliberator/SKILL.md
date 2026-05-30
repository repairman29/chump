---
name: deliberator
description: Chump's vote-tally curator (curator-opus-deliberator role) — execute the deliberator work-your-lane loop. Use to (1) read inbox for proposal broadcasts and operator-paged alerts; (2) scan ambient.jsonl for unresolved FEEDBACK kind=proposal events; (3) tally accumulated votes per corr_id and emit kind=consensus_result when verdict is PASSED or FAILED; (4) escalate NO_QUORUM proposals to the operator via operator-recall after deadline+24h; (5) emit a heartbeat so the orchestrator can audit deliberator liveness. **This skill is a thin wrapper over `scripts/coord/deliberator-loop.sh`** (the harness-neutral CLI). Examples that should trigger this skill: "tally votes for this proposal", "has META-999 reached quorum?", "check pending proposals for consensus", "force tally corr_id X", "heartbeat from deliberator curator".
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

# /deliberator — Vote-Tally Curator Loop

The deliberator curator is one of the named Opus curators in Chump's role-scoped fleet. The canonical surface is the harness-neutral shell CLI at `scripts/coord/deliberator-loop.sh`. Any harness (Claude Code, opencode, codex, manual operator) invokes it the same way.

This slash command is a thin Claude-Code convenience that runs the work-your-lane protocol. The discipline lives at [`.claude/agents/deliberator.md`](../../agents/deliberator.md). The role-scoped fleet vision is at [`docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md`](../../../docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md).

Feature gated: `CHUMP_FLEET_RECV_SIDE_V0=1` must be set for `tick` to perform real work. Without it, tick emits a heartbeat only.

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → `scripts/coord/deliberator-loop.sh tick`
- `audit` / `audit --corr-id <id>` → `scripts/coord/deliberator-loop.sh audit [--corr-id <id>]`
- `heartbeat` → `scripts/coord/deliberator-loop.sh heartbeat`
- `help` → `scripts/coord/deliberator-loop.sh help`

```bash
scripts/coord/deliberator-loop.sh $ARGUMENTS
```

Surface stdout from the script directly to the user — don't paraphrase. Exit codes are meaningful (0 = success / actionable; 1 = quiet / no result; 2 = bad subcommand or missing arg; 3 = state missing or ambient unreadable).

## The work-your-lane protocol

| Step | What | Source |
|---|---|---|
| 1 | Read inbox for deliberator-addressed DMs and WARN/STUCK broadcasts | `deliberator-loop.sh tick` inbox phase |
| 2 | Scan ambient for `FEEDBACK kind=proposal` events without matching `consensus_result` | `deliberator-loop.sh tick` proposal scan phase |
| 3 | For each unresolved proposal, call `chump consensus-tally --corr-id X --since 24h` or inline verdict logic | `deliberator-loop.sh tick` verdict phase |
| 4 | Emit `kind=consensus_result` for PASSED/FAILED verdicts | `deliberator-loop.sh tick` emit phase |
| 5 | Escalate NO_QUORUM via operator-recall when deadline+24h elapsed | `deliberator-loop.sh tick` escalation phase |
| 6 | Heartbeat periodically so orchestrator can audit liveness | `deliberator-loop.sh heartbeat` |

## Lane scope (hard boundary)

The deliberator curator owns vote tallying and consensus. It does NOT:

- Emit the original vote or proposal events (that's `chump vote` / `chump broadcast` — META-158/159)
- Route typed-handoff contracts (handoff's lane)
- Decompose umbrella gaps into sub-gaps (decompose's lane)
- Audit CI failures (ci-audit's lane)

Refuses cross-lane work unless `CHUMP_DELIBERATOR_LANE_OVERRIDE=1`; emits `kind=deliberator_lane_override` to ambient when override fires.

## Verdict logic (canonical from META-159)

| Condition | Verdict |
|---|---|
| yes >= 3 AND yes > no | PASSED |
| no > yes AND no >= 2 | FAILED |
| total < 3 | NO_QUORUM |
| PASSED/FAILED/NO_QUORUM but deadline > now | EXTENDED |

## Behavior rules

- **Surface text from the underlying script to the user directly.** Don't re-paraphrase `deliberator-loop.sh` output. Exit codes 0/1/2/3 are meaningful.
- **Use the deliberator curator voice when reporting.** Concise. Three lines max when quiet. Verbose only when emitting a consensus_result or escalating to operator.
- **If the user asks for cross-lane work** (e.g. "emit a vote" — chump vote's lane), refuse politely and route to the right tool.
- **Never emit a consensus_result twice for the same corr_id.** The idempotency guard in `deliberator-loop.sh` prevents duplicates; trust it.

## Historical failure patterns (institutional memory)

The deliberator role was created because these consensus failure classes repeated:
- **Ghost proposals** — proposal emitted but zero votes followed; corr_id silently aged out past deadline without operator awareness
- **Duplicate consensus_result** — two ticks ran concurrently for same corr_id, emitting conflicting results
- **Vote without proposal** — vote events present for a corr_id but no matching proposal (no deadline to anchor tally window)
- **Verdict drift** — META-159 changed thresholds after first result was emitted

When you see a new cluster, check whether it matches one of these patterns before diagnosing from scratch.

## Cross-references

- [`scripts/coord/deliberator-loop.sh`](../../../scripts/coord/deliberator-loop.sh) — canonical CLI; all subcommands invoke here
- [`.claude/agents/deliberator.md`](../../agents/deliberator.md) — agent body with full discipline
- [`docs/architecture/TEAM_OF_AGENTS.md`](../../../docs/architecture/TEAM_OF_AGENTS.md) — team hierarchy
- [`docs/process/SUBAGENT_DISPATCH.md`](../../../docs/process/SUBAGENT_DISPATCH.md) — META-069 dispatch epilogue
- [`docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md`](../../../docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md) — productization AC
- [`docs/gaps/META-159.yaml`](../../../docs/gaps/META-159.yaml) — sibling: chump vote + consensus-tally CLI
- [`.claude/skills/ci-audit/SKILL.md`](../ci-audit/SKILL.md) — sibling pattern (read for the productization template)
