---
name: infra-watcher
description: Chump's SRE-lane substrate health curator — one full audit tick or targeted subcheck for launchd daemon plists, self-hosted runner ghost-online, disk pressure, and claude process bloat. Thin wrapper over `scripts/coord/infra-watcher-loop.sh`. Use to (1) run a full audit cycle, (2) check a specific substrate dimension, (3) investigate a specific incident class ("why is /tmp full", "is the runner stuck?"). The infra-watcher does NOT rescue PRs (shepherd's lane), decompose CI gates (ci-audit's lane), or manage gap registry (generalist's lane).
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Grep
---

# /infra-watcher — SRE-Lane Substrate Health Audit

The infra-watcher curator monitors substrate health proactively. The canonical surface is the harness-neutral shell CLI at `scripts/coord/infra-watcher-loop.sh`. Any harness (Claude Code, opencode, codex, manual operator) invokes it the same way.

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → run one full audit cycle (all four subchecks in order)
- `audit-daemons` → launchd plist health only
- `check-runners` → self-hosted runner ghost-online detection only
- `check-disk` → disk pressure only (`/tmp`, `/private/tmp`, `.chump-locks`)
- `check-procs` → claude process count + load avg only
- `status` → print last 10 `infra_watcher_finding` events from ambient.jsonl

```bash
bash scripts/coord/infra-watcher-loop.sh ${ARGUMENTS:-tick}
```

## What each subcheck catches

| Subcheck | Category emitted | Threshold |
|---|---|---|
| `audit-daemons` | `daemon_plist_missing_interval` | Any `com.chump.*.plist` without `StartInterval` OR `StartCalendarInterval` |
| `check-runners` | `runner_ghost_online` | ≥1 job queued >5 min AND ≥1 runner online+idle |
| `check-disk` | `disk_pressure` | Any watched path >85% used |
| `check-procs` | `process_bloat` | claude proc count >100 OR load_avg_1m >10 |

## Severity levels

- `critical` — immediate operator action required (emit + broadcast WARN)
- `warning` — degraded but not blocking (emit only)
- `ok` — no finding (silent, no emit)

## Baseline incidents caught (2026-05-24)

All four of today's incidents would have surfaced within 5 minutes under a 300s `StartInterval` schedule:

1. `daemon_plist_missing_interval` — prune-worktrees plist missing `StartInterval` → 321 orphan worktrees (17h lag)
2. `runner_ghost_online` — runner ghost-online → PR queue wedged 17h (17h lag)
3. `process_bloat` — load avg 36 / 154 claude procs (hours lag)
4. `daemon_plist_missing_interval` — reaper_silent for branch + distill daemons (hours lag)

## Behavior rules

- **Surface infra-watcher-loop.sh output directly** — don't re-paraphrase findings.
- **On critical severity**: after emitting ambient, broadcast a `WARN` to the operator.
- **On daemon plist finding**: read the offending plist, determine the fix (usually adding `<key>StartInterval</key><integer>300</integer>`). If safe and bounded — apply the fix. If structural — file a gap.
- **Never cross lane boundaries** — any PR rescue, gap decomposition, or application-code change belongs to another curator.

## Cross-references

- [`.claude/agents/infra-watcher.md`](../../agents/infra-watcher.md) — agent body with full discipline + protocols
- [`scripts/coord/infra-watcher-loop.sh`](../../../scripts/coord/infra-watcher-loop.sh) — harness-neutral CLI (the capability)
- [`docs/process/OPERATOR_PLAYBOOK.md`](../../../docs/process/OPERATOR_PLAYBOOK.md) — Section 5 productize-curator pattern
- [`.claude/skills/target/SKILL.md`](../target/SKILL.md) — sibling skill pattern
