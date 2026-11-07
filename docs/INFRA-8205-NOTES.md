# INFRA-8205 — close not-a-bug: auto-filed cluster-stuck gap (duplicate of INFRA-8116)

INFRA-8205 was auto-filed by `pr-stuck-cluster-detector` ("5 PRs blocked >2h"). It
is the same condition as INFRA-8116, INFRA-8191 (#5817), INFRA-8196 (#5818) and
INFRA-8200 (#5819): the detector re-filed a gap each time the blocked-PR set drifted.

## Diagnosis (2026-11-07)

- Blocked PRs are unrelated (stale PRs needing rebase + fresh CI, owned by
  `pr-repair-rebase` / queue-tender; recent PRs waiting on required checks). No shared
  code defect.
- The re-filing loop was fixed by INFRA-8182: #5810 (skip re-filing while an open
  cluster gap exists) and #5812 (global cooldown across PR-set drift).

## Disposition

Closed as duplicate of INFRA-8116 / superseded by INFRA-8182. No code change.
