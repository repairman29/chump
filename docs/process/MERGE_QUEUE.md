# GitHub Merge Queue — Operator Runbook

> **INFRA-1377** (2026-05-16) — Enables GitHub's first-party convoy fix.
> Maintained by the ZERO-WASTE pillar; CI gate: `scripts/ci/test-merge-queue-armed.sh`.

## Problem: convoy CI thrash

Without merge queue, the fleet suffers a well-known convoy pattern:

1. 30 PRs are auto-merge-armed simultaneously.
2. PR #1 merges into `main`.
3. `main` advances; GitHub auto-rebases all 30 remaining PRs.
4. Their CI restarts from scratch — every run.
5. PR #2 merges → PRs #3-30 restart again.
6. Repeat. Observed: ~800 CI-min/hr burned with zero ships.

## Solution: GitHub Merge Queue

Merge Queue serializes merges. PRs enter a queue; CI runs **once** against the
simulated "already merged" state. No cross-PR invalidation. No convoy.

Chump's `auto-merge-armer.sh` automatically detects when merge queue is active
and adjusts its behavior:
- Skips the REST-direct fast-path (which would bypass queue ordering).
- Omits `--squash` from the arm call (the queue uses its own configured method).

## Enable merge queue (one-time setup)

### Option A: Web UI (works for all GitHub plans)

1. Go to **https://github.com/repairman29/chump/settings/branches**
2. Edit the `main` branch protection rule (or create one if absent).
3. Scroll to **"Require merge queue"** and enable it.
4. Recommended settings:
   - **Merge method**: Squash
   - **Grouping strategy**: All Green (safest; batch only when all PRs in a batch pass CI)
   - **Maximum PRs to build**: 5
   - **Maximum PRs to merge**: 5
   - **Minimum PRs before merging**: 1
   - **Wait time**: 0 minutes
5. Save.

### Option B: GitHub API (if available for your plan)

The `merge_queue` ruleset rule type is gated behind GitHub Enterprise plans.
If your repo is on a plan that supports it, use:

```bash
gh api repos/repairman29/chump/rulesets/<ruleset-id> --method PUT \
  --input - << 'JSON'
{
  "rules": [
    { "type": "merge_queue",
      "parameters": {
        "merge_method": "SQUASH",
        "grouping_strategy": "ALLGREEN",
        "max_entries_to_build": 5,
        "max_entries_to_merge": 5,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 0,
        "check_response_timeout_minutes": 60
      }
    }
  ]
}
JSON
```

Check your ruleset ID with: `gh api repos/repairman29/chump/rulesets --jq '.[].id'`

## Verify merge queue is active

```bash
bash scripts/ci/test-merge-queue-armed.sh            # advisory check
CHUMP_MERGE_QUEUE_STRICT=1 bash scripts/ci/test-merge-queue-armed.sh  # blocking
```

Or via GraphQL:
```bash
gh api graphql -f query='
query {
  repository(owner:"repairman29", name:"chump") {
    mergeQueue(branch:"main") { id entries(first:1){totalCount} }
  }
}'
```

## Normal operator workflow (post-enablement)

Nothing changes in day-to-day usage. `bot-merge.sh --auto-merge` continues to
work as before — `auto-merge-armer.sh` detects merge queue and adjusts the arm
call transparently.

PRs are merged in queue order. If your PR is behind in the queue, it waits for
the PRs ahead to merge (or be removed from the queue).

## Bypass: direct merge for emergencies

When merge queue is active and you need to bypass it (e.g., hotfix, rollback):

```bash
gh pr merge <PR#> --admin --squash    # bypass queue, merge directly
```

**Use sparingly.** Admin bypass skips the queue ordering and risks a cascade
restart on other queued PRs.

## Emergency: Disable merge queue

If merge queue causes hard blocks (e.g., all PRs stuck in queue):

1. **Web UI**: Settings → Branches → Edit main rule → disable "Require merge queue".
2. **Re-arm** all stuck PRs manually: `scripts/coord/auto-merge-armer.sh --pr <N>`.
3. File a bug gap in the Chump registry describing what broke.

After disabling, `auto-merge-armer.sh` will fall back to `--auto --squash`
automatically on the next invocation.

## Override env vars (for testing and emergency use)

| Var | Value | Effect |
|-----|-------|--------|
| `CHUMP_MERGE_QUEUE_ENABLED` | `1` | Force merge queue mode on (skip live detection) |
| `CHUMP_MERGE_QUEUE_ENABLED` | `0` | Force merge queue mode off (use `--auto --squash`) |
| `CHUMP_MERGE_QUEUE_STRICT` | `1` | Make CI test fail (not just warn) if queue is disabled |
| `CHUMP_AUTO_MERGE_REST_DIRECT` | `0` | Disable REST-direct fast-path globally |

## Pairs with

- **INFRA-1378**: `concurrency: cancel-in-progress` in CI workflows — kills old
  CI runs instantly on re-push. Belt-and-suspenders with merge queue.
- **INFRA-1076**: GitHub App installation split (separate mutation/read Apps).
- **docs/process/CI_LANES.md**: CI lane configuration for path-filtered jobs.
