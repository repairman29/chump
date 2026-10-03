# Rule registry — self-pruning rulebook (ZERO-WASTE-125)

WHY: the rulebook outgrew what an agent can hold in context (measured
2026-09-29: CLAUDE.md 700 lines + AGENTS.md 1129 lines, 155 docs/process
files, 28 git hooks, 1500+ `scripts/ci/test-*.sh` gates, 29 workflows).
Rules get added after every incident and never removed. This is the
measurement + prune loop that puts the burden of proof on the rule instead
of on the agent reading it.

## The pieces

| Piece | Path | What it does |
|---|---|---|
| Registry | `docs/process/RULE_REGISTRY.json` | One entry per git hook + CI test gate + known gap-reserve gate: `id`, `source`, `signal` (the ambient kind or CI check name it fires), `protected` |
| Generator | `scripts/coord/rules-registry-gen.sh` | Regenerates the registry from what's actually on disk. Re-run after adding/removing a hook or `scripts/ci/test-*.sh` |
| Coverage gate | `scripts/ci/test-rules-registry-coverage.sh` | CI fails if the committed registry is stale vs. on-disk gates |
| Audit tool | `chump rules audit --window 30d [--json]` | Reports fires/bypasses per rule from `.chump-locks/ambient.jsonl` over the trailing window; ranks zero-fire rules as delete candidates |
| Budget gate | `scripts/ci/test-claude-md-budget.sh` | Hard cap: CLAUDE.md ≤ 150 lines, AGENTS.md ≤ 300 lines |

## What's measured today vs. deferred

`chump rules audit` reports **fires** and **bypasses** honestly from
ambient data. It does **not** fabricate **catches** (a fire followed by a
fix commit on the same PR) or **cost** (CI minutes, agent retries) — the
ambient schema has no PR-correlation field on gate-fire events yet, so
those columns print `not_instrumented` rather than a made-up number. Wiring
real catch/cost tracking is the natural next gap once gate-fire events
carry a `pr_number` field.

The weekly consensus-driven prune cycle (broadcast `FEEDBACK kind=proposal`
per delete-candidate batch, file the deletion gap on `PASSED`) is **not**
built yet — it needs real fire-rate history to accumulate first (today's
numbers are all zero because the registry only just started measuring).
Follow-up gap files the automation once there's 30 days of signal to act on.

## Protected floor — never auto-pruned

These are never proposed for deletion by the prune loop, regardless of
audit data:

- Never push directly to `main`.
- No secrets in the repo or in logs.
- `proprietary/` — never commit here.
- No destructive/irreversible operations without operator sign-off.
- The T1–T4 operator-escalation triggers (see `AGENTS.md`).

## Using the audit tool

```bash
chump rules audit --window 30d          # human-readable, delete candidates first
chump rules audit --window 30d --json   # full machine-readable report
```

A rule is a delete candidate when it has zero fires in the window and is
not on the protected floor. Zero fires with real history behind it is
real signal; zero fires right after the registry first went live is not —
give it a real window before acting on the count.
