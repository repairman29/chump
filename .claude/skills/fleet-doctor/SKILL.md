---
name: fleet-doctor
description: Strict Chump fleet health check — single command that exits non-zero if ANY of 7 health invariants fail (binary staleness, expired leases, low disk, dirty PRs, gap drift, P0 budget over 5, pillar coverage below 2). Use when you suspect the fleet is unhealthy and want a yes/no answer, OR as part of a pre-ship audit. Thin wrapper over harness-neutral CLI at `scripts/coord/fleet-doctor-strict.sh` (INFRA-1427). Supports `--json` (machine-readable) and `--verbose` (verbose per-check output). Per `.claude/README.md` pattern.
user-invocable: true
allowed-tools:
  - Bash
---

# /fleet-doctor — Strict Fleet Health Check

Canonical surface: [`scripts/coord/fleet-doctor-strict.sh`](../../../scripts/coord/fleet-doctor-strict.sh) (INFRA-1427). Any harness invokes the same script; this skill is the Claude Code adapter.

## Routing

Arguments passed: `$ARGUMENTS`. Optional flags: `--json`, `--verbose`.

```bash
scripts/coord/fleet-doctor-strict.sh $ARGUMENTS
```

The exit code IS the answer. **Surface that explicitly to the user** — don't bury it in prose.

## What it checks (exit non-zero if any fail)

1. **binary** — chump binary exists and is not stale vs source
2. **leases** — no expired leases older than `LEASE_STALE_HOURS` (default 2h)
3. **disk** — free disk ≥ `DISK_MIN_GB` (default 5 GB)
4. **dirty-prs** — no open PRs in DIRTY state for > `DIRTY_PR_HOURS` (default 24h)
5. **gap-drift** — no unresolved gap-drift (open gaps with closed PRs, etc.)
6. **p0-budget** — open P0 gap count ≤ `P0_MAX` (default 5)
7. **pillar-cover** — every pillar has ≥ `PILLAR_MIN` (default 2) pickable gaps

## When the user invokes this

- If exit 0: report "fleet healthy, all 7 checks pass" + summary of any borderline numbers
- If exit non-zero: **list which checks failed, in order**, and propose the next action (file a gap, rebuild binary, run a sweeper, etc.). The script's stdout has the diagnostic detail — surface it.

## When NOT to use this

- For a snapshot-style summary, use `/fleet-brief` (no pass/fail; just status)
- For halt-class emergencies, use `/operator-recall --check-only` (different signal class)
- For PR-specific diagnostics, use `gh pr view`, `pr-rescue.sh`, etc.

## Useful env overrides

```bash
LEASE_STALE_HOURS=4 DISK_MIN_GB=10 scripts/coord/fleet-doctor-strict.sh
```

Pass these via shell prefix when the user wants non-default thresholds.
