# PR lifecycle policy — shared "keep alive vs. retire" condition (INFRA-3604 slice: INFRA-8009)

## Problem

Chump has several organs that independently decide whether an open (or
recently-closed) PR should stay alive: the reopener
(`scripts/coord/pr-rescue-false-close.sh`), the stale-PR reaper
(`scripts/ops/stale-pr-reaper.sh`), the rot-reaper
(`scripts/ops/rot-reaper.sh`), and `pr-shepherd-daemon.sh`'s classifier. Each
one grew its own ad-hoc condition for "is this PR worth keeping". The
receipt that motivated this (INFRA-3604, 2026-08-19): the reopener resurrected
`#3919`/`#3910` ~25s after `stale-pr-reaper` closed them, because the reopener
only checked branch mergeability and never asked whether the PR's gap was
still open or already demoted/closed — the two organs disagreed on the same
PR and re-jammed the merge queue.

This doc is the single policy both organs (and any future one) must read
off of, so "keep alive" and "retire" can never disagree again.

## Policy

**A PR is kept alive (open, eligible for reopen/rebase/auto-merge-arm) if
and only if BOTH of these hold:**

1. **Gap-open condition** — the gap the PR implements (parsed from the
   branch name / PR body `Gap:` trailer) has `status:open` in `state.db`
   (canonical source of gap status post-ZERO-WASTE-020; `docs/gaps/*.yaml`
   is a sync target, not authoritative). If the gap was closed, shipped
   under a different PR, or demoted/retired, the PR is **not** kept alive
   regardless of branch mergeability.
2. **Mergeable/rebaseable condition** — the branch's GitHub-reported
   `mergeable` and `rebaseable` fields are both truthy (i.e. not
   `CONFLICTING` / not blocked by a real content conflict against the
   current base). A PR whose branch cannot be cleanly merged or rebased is
   dead weight even if its gap is still open — see "Retirement" below for
   what happens to it instead of reopening/re-arming.

```
keep_alive(pr) := gap_open(pr.gap_id) AND mergeable(pr.branch) AND rebaseable(pr.branch)
```

Both conditions are **necessary**; neither is sufficient alone:

| gap open? | mergeable/rebaseable? | outcome |
|---|---|---|
| yes | yes | keep alive — reopen if closed, rebase if BEHIND, arm auto-merge if green |
| yes | no | **retire** (close, leave gap open for a clean re-pick on fresh base) — never reopen |
| no | yes | **retire** (close; work is either shipped elsewhere or no longer wanted) — never reopen |
| no | no | **retire** — doubly disqualified |

## Retirement of stale, conflicting, low-priority PRs

"Retire" means: close the PR (do not delete the branch — a human/fleet
worker may still want to inspect it), leave the underlying gap **open** so
it can be freshly re-picked and re-implemented against current `main`, and
label the PR so the reopener/reviver organs recognize this was a
*deliberate* close and refuse to resurrect it.

Retirement conditions (all three must hold — this is what keeps retirement
from being trigger-happy against a PR that's merely waiting its turn):

1. **Stale** — the PR has sat in a non-mergeable (CONFLICTING/DIRTY) state
   for ≥ `CHUMP_RETIRE_STALE_DAYS` (default 7 days). A PR that goes
   CONFLICTING for an hour during a busy rebase storm is not stale.
2. **Conflicting** — GitHub reports `mergeable=false` against the current
   base (a real content conflict, not just BEHIND — BEHIND is
   auto-fast-forwarded by the rebase organs and never reaches retirement).
3. **Low-priority relative to the queue** — retirement is a queue-health
   action, not a priority judgment call per se: it fires because the PR is
   unlandable as-is, and the gap re-pick path is strictly better than
   leaving a broken branch jamming the merge-queue view. (P0/P1 gaps are
   not exempt — an unlandable P0 branch is worse for the mission than a
   clean re-pick of the same P0 gap.)

### Non-reopen guarantee

Once a PR is retired under this policy, **the reopener must refuse to
revive it.** The mechanism: retirement always labels the PR (see
`RETIRE_LABEL` in `stale-pr-reaper.sh`) and leaves the gap open, so any
reviver that checks the gap-open condition alone (without checking for the
retirement label) would incorrectly try to reopen it — this is exactly the
INFRA-3604 failure mode. The reopener's check must therefore be:

```
should_reopen(pr) := keep_alive(pr) AND NOT has_retirement_label(pr)
```

## Current implementation status (as of 2026-09-26)

| Organ | Checks gap-open? | Checks mergeable/rebaseable? | Checks retirement label? |
|---|---|---|---|
| `scripts/coord/pr-rescue-false-close.sh` (reopener) | **no** — extracts `gap_id` from branch name but never queries `state.db` for its status (INFRA-5349 added the mergeability guard only) | yes (INFRA-5349) | no |
| `scripts/ops/stale-pr-reaper.sh` (retirement) | n/a (retirement leaves gap open by design) | yes (`mergeable=CONFLICTING` + age ≥ `RETIRE_STALE_DAYS`) | emits the label (`RETIRE_LABEL`) |
| `scripts/coord/pr-shepherd-daemon.sh` (classifier) | no | yes (BEHIND/MERGEABLE/DIRTY classification) | no |

**Gap:** the reopener implements half the policy (mergeability) but not the
gap-open half, and doesn't check the retirement label at all — it is the
literal INFRA-3604 receipt waiting to recur on the next stale-PR-reaper
retirement. This is tracked as a follow-up implementation gap (file via
`chump gap reserve --domain INFRA --title "pr-rescue-false-close.sh: add
gap-open + retirement-label checks per PR_LIFECYCLE_POLICY.md"`) rather than
folded into this design-only slice, per the two-phase decomposition rule
(design first, implementation sliced separately at claim time).

## References

- INFRA-3604 (parent umbrella, receipt + reopener/reaper disagreement)
- INFRA-3614 (sibling: CONFLICTING-PR terminal-state coverage, rot-reaper)
- INFRA-5349 (mergeability guard landed in the reopener)
- INFRA-3803 (retirement label + stale-PR-reaper conflicting-PR retirement)
- ZERO-WASTE-020 (state.db is canonical for gap status; YAML is sync-only)
