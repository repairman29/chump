# PR Lifecycle Policy — Reopener + Stale-PR-Reaper Unification

> Canonical policy for when an open PR is allowed to stay alive, and when it
> must be closed/retired. Gap: INFRA-5032 (INFRA-3604 slice, sibling of
> INFRA-5031). Approved by infra lead (Jeff), 2026-09-06.

## The problem

Three independent actors mutate PR open/closed state from different signals,
with no shared source of truth:

| Actor | Signal it acts on | Effect |
|---|---|---|
| `scripts/coord/pr-rescue-false-close.sh` / `scripts/ops/closed-pr-watchdog.sh` (`CHUMP_WATCHDOG_REOPEN=1`) | PR closed, but its gap is still `status=open` in `docs/gaps/<ID>.yaml` on `origin/main` | Reopens the PR |
| `scripts/ops/stale-pr-reaper.sh` (INFRA-3803 retirement slice) | PR `mergeable=CONFLICTING` for `CHUMP_RETIRE_STALE_DAYS`+ days | Closes ("retires") the PR, gap left open for re-pick |
| `scripts/coord/orphan-pr-closer.sh` | Gap `status=done` but PR still open | Closes the PR |

INFRA-3604's receipt (2026-08-19): closing a stale+CONFLICTING, DIRTY, P2 PR
whose gap had been demoted did not stick — the reopener saw "gap still open"
and reopened it ~25 seconds later, because the reopener's check ("is the gap
open?") only inspects **one** of the two conditions that make a PR worth
keeping alive. The two actors disagreed, and the disagreement looped.

## The policy

**A PR remains alive only if BOTH hold:**

1. **The gap is open** — `docs/gaps/<ID>.yaml` on `origin/main` shows
   `status: open` (or the PR is a filing PR per
   `is_filing_pr_title()` in `stale-pr-reaper.sh`, which is always exempt).
2. **The branch is mergeable or rebaseable** — GitHub's `mergeable` field is
   `MERGEABLE` or `UNKNOWN` (not yet computed), **or** the branch is behind
   but a rebase (GH-side `gh pr update-branch` or local
   `git rebase origin/main`) is expected to resolve it cleanly per
   [`REAPER_DOCTRINE.md`](./REAPER_DOCTRINE.md). A branch with a real content
   conflict (`mergeable=CONFLICTING`) that has sat that way past
   `CHUMP_RETIRE_STALE_DAYS` (default 7 days) fails this condition — nothing
   auto-rebases a genuine conflict, so it will never resolve itself.

If either condition is false, the PR does **not** get to stay open, and —
critically — **no actor may reopen or re-close it against this joint
check**. Any actor that only evaluates condition (1) or only evaluates
condition (2) in isolation must not take a unilateral action; it defers to
the joint check below.

### Joint check (canonical, both actors must apply it)

```
gap_open      = gap_status(gid) == "open"        # from origin/main, INFRA-3604 gap_status()
branch_alive  = mergeable in {"MERGEABLE", "UNKNOWN"}
                or (mergeable == "CONFLICTING" and age_days < CHUMP_RETIRE_STALE_DAYS)

pr_should_stay_open = gap_open AND branch_alive
```

- **Reopener** (`pr-rescue-false-close.sh`, `closed-pr-watchdog.sh`
  `CHUMP_WATCHDOG_REOPEN`): before reopening a closed PR, it must confirm
  `pr_should_stay_open` is true — i.e. re-check `mergeable` via
  `gh pr view <N> --json mergeable`, not just gap status. If the branch is
  `CONFLICTING` and stale, the reopener **must not** reopen, even if the gap
  is open — the correct remediation is a fresh PR against a clean rebase,
  not resurrecting the conflicting branch.
- **Stale-PR-reaper** (`stale-pr-reaper.sh` INFRA-3803 retirement slice):
  already implements condition (2) (`mergeable=CONFLICTING` + age threshold)
  correctly. It must additionally honor a `retired` label as a standing
  signal to every other actor (including the reopener) that this PR failed
  the joint check and should not be resurrected — the label is the durable
  record of "both conditions were evaluated and the PR failed."
- **Orphan-PR-closer** (`orphan-pr-closer.sh`) is a degenerate case of the
  same check: `gap_open=false` always fails the joint check regardless of
  `branch_alive`, so closing is always correct there and needs no change.

### Enforcement point

The `retired` label (set by `stale-pr-reaper.sh`, INFRA-3803) is the shared
signal. Any reopener path (`pr-rescue-false-close.sh`,
`closed-pr-watchdog.sh`) **must** skip PRs carrying the `retired` label,
mirroring the existing `do-not-respawn` exemption check already present in
the reaper. This turns the race from "whoever runs next wins" into
"retirement is sticky by construction" — the exact fix for the INFRA-3604
receipt (reopen within ~25s of a deliberate close).

## Non-goals

- This policy does not change *how* mergeability is computed, only *which*
  signals gate reopen vs. close decisions.
- Rebase mechanics (GH-side vs. local, 3-strike escalation, trunk-RED hold)
  remain owned by [`REAPER_DOCTRINE.md`](./REAPER_DOCTRINE.md) — this doc
  only defines the alive/dead boundary those mechanics feed into.

## Related

- [`REAPER_DOCTRINE.md`](./REAPER_DOCTRINE.md) — rebase-before-reap mechanics for condition (2)
- `docs/gaps/INFRA-3604.yaml` — original reopener/reaper conflict receipt
- `scripts/ops/stale-pr-reaper.sh` (INFRA-3803 section) — retirement implementation
- `scripts/coord/pr-rescue-false-close.sh`, `scripts/ops/closed-pr-watchdog.sh` — reopener implementations
- `scripts/coord/orphan-pr-closer.sh` — gap-done closer (unaffected, degenerate case)
