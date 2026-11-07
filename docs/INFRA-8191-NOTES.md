# INFRA-8191 — close not-a-bug: auto-filed cluster-stuck gap (duplicate of INFRA-8116)

INFRA-8191 was auto-filed by `pr-stuck-cluster-detector` ("3 PRs blocked >2h"). It
is the same condition as INFRA-8116 (score 1.00 at reserve time, "6 PRs blocked
>2h"): the detector re-filed a new gap each time the blocked-PR *set* drifted.

## Diagnosis (2026-11-07)

- Blocked PRs split into two unrelated classes, neither a shared code defect:
  1. Stale PRs (opened 10-28..11-01) with red `audit-shard`/`audit` or
     `fast-checks` runs from old base commits. They need rebase + fresh CI,
     which `pr-repair-rebase` / queue-tender own.
  2. Recent PRs (e.g. #5813) whose `fast-checks` hit the ~21 min job ceiling
     with a ~17 min silent gap after the last test-parity step — runner/CI
     timeout, not a PR-specific failure.
- The re-filing loop itself (the actual defect) was fixed by INFRA-8182:
  #5810 (skip re-filing while an open cluster gap exists) and #5812 (global
  cooldown across PR-set drift). No new code path is needed here.

## Disposition

Closed as duplicate of INFRA-8116 / superseded by INFRA-8182. Remaining stale-PR
recovery stays with the existing rebase/rescue organs.
