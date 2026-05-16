# Merge Queue migration (INFRA-1377)

> **Status:** design contract. Implementation pending.
> Filed 2026-05-15 after a paramedic session that observed **~800 CI-min/hr wasted on cancelled runs**
> across 30 auto-armed PRs with last-8 CI runs all cancelled.

## The problem

`gh pr merge --auto --squash` is the current path. When any PR lands on main, every other open PR's CI is invalidated and re-queued. With 30 PRs armed, every merge cascades 29 fresh CI cycles — most of which get cancelled when the next merge fires. The convoy pattern wastes:

- **CI runner minutes** (~800/hr observed)
- **GraphQL bucket** (each cancel + re-queue costs API calls)
- **Operator attention** (PRs sit BLOCKED forever; paramedic re-arms each one)

GitHub's first-party fix is **Merge Queue** (`required_pull_request_reviews.merge_queue.enabled`). PRs queue, CI runs **once** against the target merge state, no cross-PR invalidation.

## Migration shape

Six-step rollout. Steps 1–4 are code/config changes (this PR's scope); steps 5–6 are the operator flip-the-switch moments.

### Step 1 — `gh pr merge` wrapper

`scripts/coord/lib/merge-queue.sh` exposes one function:

```bash
merge_queue_or_auto_merge <pr-number> [--squash|--merge|--rebase]
```

Behavior:
- If `CHUMP_MERGE_QUEUE_ENABLED=1` (env, default off): call `gh pr merge "$pr" --merge-queue` (which respects the queue policy set on main).
- Else: call `gh pr merge "$pr" --auto --squash` (current behavior).

Single insertion point. Every script that currently calls `gh pr merge --auto --squash` is migrated to `merge_queue_or_auto_merge "$PR" --squash`.

### Step 2 — bot-merge.sh migration

`scripts/coord/bot-merge.sh` has three merge paths (auditable via `grep -n "pr merge" bot-merge.sh`):

1. **REST-direct fast path** (~line 2330) — `PUT /repos/X/pulls/N/merge` when all required checks already green. **Bypass the queue here** — these PRs are pre-validated and don't benefit from re-queuing. Keep as-is.
2. **GraphQL `enablePullRequestAutoMerge`** (default armed path) — replace with `gh pr merge --merge-queue` via the wrapper.
3. **Retry/recovery error path** (~line 2143) — operator instruction in error message; update text to mention `--merge-queue` when env enabled.

### Step 3 — chump gap claim flow

`scripts/coord/gap-claim.sh` and `chump claim` print operator hints suggesting `gh pr merge ... --auto --squash`. Replace with the wrapper invocation.

### Step 4 — branch-protection drift gate

The existing branch-protection audit (`scripts/ci/test-branch-protection-drift.sh`) gains one assertion:

```bash
[ "$(gh api repos/$REPO/branches/main/protection --jq '.required_pull_request_reviews.merge_queue.enabled // false')" = "true" ]
```

This fires only when `CHUMP_MERGE_QUEUE_REQUIRED=1` (CI env, set after step 5).

### Step 5 — Enable Merge Queue (operator flip)

```bash
gh api repos/repairman29/chump/branches/main/protection \
  --method PUT \
  --raw-field 'required_pull_request_reviews[merge_queue][enabled]=true' \
  --raw-field 'required_pull_request_reviews[merge_queue][grouping_strategy]=ALLGREEN' \
  --raw-field 'required_pull_request_reviews[merge_queue][merge_method]=SQUASH' \
  --raw-field 'required_pull_request_reviews[merge_queue][max_entries_to_build]=5' \
  --raw-field 'required_pull_request_reviews[merge_queue][max_entries_to_merge]=5' \
  --raw-field 'required_pull_request_reviews[merge_queue][min_entries_to_merge]=1' \
  --raw-field 'required_pull_request_reviews[merge_queue][min_entries_to_merge_wait_minutes]=1'
```

Then flip env: `export CHUMP_MERGE_QUEUE_ENABLED=1` in `scripts/setup/chump-fleet-bootstrap.sh`.

### Step 6 — Measure

Ambient counter `cancelled_ci_runs_24h` before vs after. Expected drop >80%. If <50%, investigate before turning off the auto-merge fallback (operator option to revert via `CHUMP_MERGE_QUEUE_ENABLED=0`).

## Bypass for emergency direct-merge

Some fixes need to skip the queue (e.g. hotfix for a CI-breaking change blocking the queue itself):

```bash
gh pr merge <N> --merge --no-merge-queue   # direct merge, bypass queue
```

Document at top of `scripts/coord/bot-merge.sh` operator section.

## Acceptance criteria (from INFRA-1377)

- [x] **AC 1** documented (this doc)
- [ ] **AC 2** wrapper + caller migration shipped
- [ ] **AC 3** branch-protection drift gate updated
- [ ] **AC 4** smoke test asserts merge-queue armed (gated on `CHUMP_MERGE_QUEUE_REQUIRED=1`)
- [x] **AC 5** this doc covers operator flow + emergency bypass
- [ ] **AC 6** measurement counter wired

## Related gaps

- **INFRA-1378**: `cancel-in-progress` cleanup on cancelled CI — belt-and-suspenders pairing.
- **INFRA-1389**: merge-driver coverage for hot files — reduces conflicts that would block the queue.
- **INFRA-1394**: hot-files claim-time collision check — prevents the conflicts upstream.
- **INFRA-1420**: keystone cascade auto-retrigger — becomes obsolete once Merge Queue runs CI once against the target state.

The Merge Queue is the keystone of the ZERO-WASTE pillar for the entire CI pipeline.
