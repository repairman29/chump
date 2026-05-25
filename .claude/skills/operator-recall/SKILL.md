---
name: operator-recall
description: Detect halt-class conditions in the Chump fleet — AUTH_DEAD (auth-storm worker exits), COST_CAP (cost cap exceeded), CI_BROKEN (pr_stuck cluster with ci-reason), QUEUE_STARVE (pickable count zero for 24h+). Emits ambient `kind=operator_recall` and optionally POSTs to `CHUMP_OPERATOR_RECALL_URL` to page the operator. Use to (a) check whether the fleet currently has any halt-class condition active without paging anyone (`--check-only`), or (b) actively page the operator with a specific condition + reason. Thin wrapper over harness-neutral CLI at `scripts/dispatch/operator-recall.sh` (INFRA-626). Per `.claude/README.md` pattern.
user-invocable: true
allowed-tools:
  - Bash
---

# /operator-recall — Halt-Class Condition Detector + Pager

Canonical surface: [`scripts/dispatch/operator-recall.sh`](../../../scripts/dispatch/operator-recall.sh) (INFRA-626). Any harness invokes the same script.

## When to invoke this skill

- **Diagnostic mode (`--check-only`)** — silent check: "is any halt-class condition active right now?" Exit 1 if yes (with a reason printed). No side effects. **This is the default for agent use.**
- **Active page (no flag, or `--condition X --reason Y`)** — emits ambient `kind=operator_recall` AND POSTs to `CHUMP_OPERATOR_RECALL_URL` if set. **Use sparingly** — this pages a human.

## Routing

Arguments passed: `$ARGUMENTS`. Common forms:

```bash
# Diagnostic — check, exit 1 if any condition active (most common for agent use)
scripts/dispatch/operator-recall.sh --check-only

# Active page — operator-initiated, explicit
scripts/dispatch/operator-recall.sh --condition AUTH_DEAD --reason "fleet_auth_storm cluster: 5 workers exited in last hour"

# Auto-detect all conditions, emit + notify any that fire
scripts/dispatch/operator-recall.sh

scripts/dispatch/operator-recall.sh $ARGUMENTS
```

If `$ARGUMENTS` is empty, **default to `--check-only`** (the safe diagnostic mode). Confirm with the user before sending an active page.

## The four halt-class conditions

| Condition | Trigger | Tunable threshold |
|---|---|---|
| `AUTH_DEAD` | ≥ N `fleet_auth_storm` events with `action=worker_exit` in window | `CHUMP_AUTH_STORM_RECALL_THRESHOLD` (5), `CHUMP_AUTH_STORM_WINDOW_SECS` (3600) |
| `COST_CAP` | `cost_cap_exceeded` event in last 2h, OR `chump cost-watch --hard-cap` exits non-zero | (no override) |
| `CI_BROKEN` | ≥ N `pr_stuck` events with reason containing "ci" in window | `CHUMP_CI_BROKEN_THRESHOLD` (3), `CHUMP_CI_BROKEN_WINDOW_SECS` (7200) |
| `QUEUE_STARVE` | `fleet_queue_depth` with `pickable_count=0` AND no `gap_reserved` in window | `CHUMP_QUEUE_STARVE_SECS` (86400) |

## Behavior rules

- **Never call the active-page mode without explicit user instruction.** `--check-only` for any agent-initiated diagnostic.
- **If a condition fires in `--check-only` mode**, surface the condition name + reason to the user and propose next steps (page operator? auto-mitigate via a script? file a gap?).
- The recall emit is idempotent — cooldown-gated by `CHUMP_OPERATOR_RECALL_COOLDOWN_SECS` (default 1800) — so re-triggering on the same condition within 30 min won't double-page.

## When NOT to use this

- For non-halt-class issues (slow PR, single flake, one stuck check) — use `/fleet-doctor` or direct script invocation
- For status summaries — use `/fleet-brief`
- For "missing feature" investigation — use `/verify-existence`
