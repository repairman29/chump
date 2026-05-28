# GitHub Merge Queue — Operator Runbook

> **INFRA-1377** (2026-05-16) — Enables GitHub's first-party convoy fix. Detection + adapter.
> **INFRA-2095** (2026-05-28) — Wave-1 CI scaling. Merge_group trigger coverage + pre-flip readiness gate.
> Maintained by the ZERO-WASTE pillar.
> CI gates: `scripts/ci/test-merge-queue-armed.sh`, `scripts/ci/test-merge-group-coverage.sh`.

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

## Pre-flip readiness check (INFRA-2095)

Before enabling merge queue, verify every required status check on `main`
fires on `merge_group:` events. A required check without a `merge_group`
trigger will block the queue forever — the queue waits for a check that
never runs against its synthetic merge commit.

```bash
bash scripts/ci/test-merge-group-coverage.sh
```

Sample passing output (as of 2026-05-28):

```
[2. Required status checks on main]
PASS Found 3 required status check(s):
    - ACP protocol smoke test (Zed / JetBrains compatible)
    - audit
    - test

[3. Source-workflow merge_group trigger audit]
PASS   ACP protocol smoke test (Zed / JetBrains compatible) → editor-integration.yml (job=acp-smoke) merge_group-wired
PASS   audit → ci.yml (job=audit) merge_group-wired
PASS   test → ci.yml (job=test) merge_group-wired

=== Summary: 4 pass, 0 fail, 0 warn (missing=0) ===
```

The test is wired into ci.yml's `pr-hygiene` job as advisory
(continue-on-error). To block PRs on coverage regressions instead:
set `CHUMP_MERGE_GROUP_STRICT=1` in the workflow env or flip the
`continue-on-error` to false in `.github/workflows/ci.yml`.

When this check goes RED on any future PR, the merge queue is unsafe
to enable (or will start blocking new PRs whose required-check
workflow was added without the merge_group trigger).

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
- **INFRA-2094**: cargo-nextest swap (Wave 1 sibling). 60% test speedup
  compounds with merge-queue batching — each queue batch finishes ~60% faster.
- **INFRA-2093**: sccache + R2 backend (Wave 1 sibling). 50-70% compile
  speedup compounds across the queue's serialized CI runs.
- **docs/process/CI_LANES.md**: CI lane configuration for path-filtered jobs.
- **docs/strategy/CI_SCALING_REFERENCE.md**: full Wave 1 + Wave 2 hardware
  decision tree (compounds shown together).

## Current readiness (2026-05-28)

| Component | Status |
|---|---|
| Required-check workflows wired for `merge_group:` | ✅ all 3 of 3 (ci.yml × 2 jobs + editor-integration.yml × 1) |
| `auto-merge-armer.sh` adapts when queue is active | ✅ INFRA-1377 |
| Coverage regression gate (`test-merge-group-coverage.sh`) | ✅ INFRA-2095 (advisory, wired into pr-hygiene job) |
| Live detection (`test-merge-queue-armed.sh`) | ✅ INFRA-1377 |
| Merge queue **enabled** in branch protection | ❌ Operator action |

**Next operator action** to activate (5 min, reversible in 30 sec):

1. https://github.com/repairman29/chump/settings/branches → Edit `main` → enable "Require merge queue" with settings from "Option A" above.
2. Watch one batch run end-to-end: `gh api graphql -f query='query{repository(owner:"repairman29",name:"chump"){mergeQueue(branch:"main"){entries(first:5){nodes{id headCommit{oid}}}}}}'`
3. If anything regresses: Web UI → uncheck "Require merge queue" → done.
