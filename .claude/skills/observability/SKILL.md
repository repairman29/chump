---
name: observability
description: Chump's telemetry-tuning curator (curator-opus-observability role) — audit ambient event-registry hygiene (zero-emit / high-volume kinds), reaper cadence coordination (launchd daemon interval incoherence), api-cost leaderboard (top-3 burners), and halt-class detector noise ranking. Use to (1) run one full observability tick, (2) audit event registry and propose removals, (3) check reaper cadences for incoherence, (4) roll up api-cost leaderboard, (5) rank detector noise. **This skill is a thin wrapper over `scripts/coord/observability-loop.sh`** (META-103). Examples that should trigger this skill: "audit event registry", "tune reapers", "cost leaderboard", "why is X firing so much", "run observability tick", "reaper cadence audit".
user-invocable: true
allowed-tools:
  - Bash
---

# /observability — Telemetry-Tuning Curator Loop

The Observability curator is one of the named Opus curators in Chump's role-scoped fleet. Its lane is MEASUREMENT/TUNING of fleet-internal telemetry — NOT infra-watcher (substrate) or opus-shepherd-generalist (cross-cutting). The canonical surface is the harness-neutral shell CLI at `scripts/coord/observability-loop.sh` (META-103). Any harness invokes the same script.

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → run one full observability cycle (all four subcommands in sequence)
- `audit-event-registry` → zero-emit / high-volume kind detection only
- `reaper-cadence-audit` → launchd daemon interval incoherence check only
- `cost-leaderboard-rollup` → top-3 api burners over last 24h
- `detector-noise-rank` → top-20 ambient kinds by emit-count last 24h
- `status` → print lane scope + last findings summary from ambient.jsonl

```bash
scripts/coord/observability-loop.sh ${ARGUMENTS:-tick}
```

Surface stdout verbatim. The script outputs structured findings — don't re-paraphrase.

## What each subcommand covers

| Subcommand | What it checks | Finding category |
|---|---|---|
| `audit-event-registry` | Parse `event-registry-reserved.txt` + last 7d ambient; zero-emit kinds → propose removal; >100/day → propose cadence tighten | `zero_emit_kind`, `high_volume_kind` |
| `reaper-cadence-audit` | `~/Library/LaunchAgents/com.chump.*reaper*.plist` + `*prune*.plist`; compare StartInterval across daemons targeting similar populations | `reaper_cadence_drift` |
| `cost-leaderboard-rollup` | Invoke `scripts/dev/api-cost-leaderboard.sh --window 24h --json`; flag scripts with >500 api_calls/24h | `api_burner` |
| `detector-noise-rank` | Count ambient kinds last 24h; top 20 sorted desc; flag >100/24h | `high_volume_kind` |

All findings emit `kind=observability_finding` with `{category, severity, kind_or_subject, detail}` to ambient.jsonl.

## When to use each subcommand

- **Routine:** run `tick` as part of session start or scheduled daily cron.
- **Investigating alert:** run the specific subcommand that matches the symptom (e.g. `cost-leaderboard-rollup` when GraphQL exhaustion fires).
- **Registry cleanup sprint:** `audit-event-registry` → review proposals → operator removes dead kinds from registry after confirmation.
- **Reaper incoherence:** `reaper-cadence-audit` → compare cadences → file a gap if StartInterval drift >4×.

## When NOT to use this

- For substrate health (disk, binary staleness, lease expiry) — use `/fleet-doctor`
- For "is feature X shipped?" — use `/verify-existence`
- For general fleet status — use `/fleet-brief`
- For halt-class paging — use `/operator-recall`

## Lane scope

The observability curator owns MEASUREMENT/TUNING only. It does not:
- Touch `src/` or `crates/`
- File infra-watcher substrate gaps (those are infra-watcher's lane)
- Perform cross-cutting PM work (opus-shepherd-generalist's lane)
- Autonomously remove event kinds from the registry (proposals only; operator confirms)

## Cross-references

- [`.claude/agents/observability.md`](../../agents/observability.md) — full agent body with discipline + protocols
- [`scripts/coord/observability-loop.sh`](../../../scripts/coord/observability-loop.sh) — canonical harness-neutral CLI
- [`scripts/ci/event-registry-reserved.txt`](../../../scripts/ci/event-registry-reserved.txt) — 60+ registered event kinds
- [`scripts/dev/api-cost-leaderboard.sh`](../../../scripts/dev/api-cost-leaderboard.sh) — api-cost attribution (INFRA-1077)
- [`docs/architecture/TEAM_OF_AGENTS.md`](../../../docs/architecture/TEAM_OF_AGENTS.md) — team hierarchy
