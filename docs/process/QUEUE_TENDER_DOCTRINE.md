# Queue-tender doctrine (META-243)

The queue-tender is the curator role that keeps the PR merge queue moving. It
is a permanent loop, not an ad-hoc cron: `scripts/coord/queue-tender-loop.sh`
run every 5 minutes by launchd (`scripts/setup/install-queue-tender.sh`).

For the auto-processor's event taxonomy and cost accounting, see
[`QUEUE_TENDER_OBSERVABILITY.md`](QUEUE_TENDER_OBSERVABILITY.md).

## What it does

Each `tick`:

1. Lists open PRs and their merge state.
2. For each PR that is `BEHIND` its base, asks GitHub to update the branch
   (`gh pr update-branch`), so CI re-runs against current main.
3. Emits one `kind=queue_tend_tick` ambient event with the counts
   (`prs_seen`, `behind`, `updated`, `held`, `failed`, `dry_run`).

`heartbeat` emits `kind=queue_tend_heartbeat` for liveness audits.

## Safety rails

| Rail | Behavior |
|---|---|
| Dry-run default | `CHUMP_QUEUE_TENDER_DRY_RUN=1` logs intent only. The operator sets `0` after reading dry-run output. |
| Panic-stop | `CHUMP_SKIP_QUEUE_TENDER=1` makes the script exit 0 immediately. |
| Hysteresis | A PR updated in the last `CHUMP_QUEUE_TENDER_HYSTERESIS_S` seconds (default 300) is held, not re-updated. Prevents rebase ping-pong that resets CI. |
| Per-tick cap | At most `CHUMP_QUEUE_TENDER_MAX_PER_TICK` (default 5) updates per tick. |

## Lane discipline

The tender only brings open PR branches up to date. It does **not** merge,
bypass branch protection, close PRs, or touch gap state. Merging belongs to
the merge train; stuck-PR rescue belongs to the shepherd. A tender that merges
around a failing check defeats the queue it is meant to tend, so the loop's
source must never contain an admin-bypass merge call; `scripts/ci/test-queue-tender.sh`
enforces this.

## Operating it

```bash
bash scripts/setup/install-queue-tender.sh install     # render + load the launchd agent
bash scripts/setup/install-queue-tender.sh status
bash scripts/setup/install-queue-tender.sh check       # exit 0 only if installed (and loaded)
bash scripts/setup/install-queue-tender.sh uninstall
bash scripts/coord/queue-tender-loop.sh tick           # one manual cycle
```

The launchd template lives at `scripts/launchd/com.chump.queue-tender.plist`
(`StartInterval=300`).
