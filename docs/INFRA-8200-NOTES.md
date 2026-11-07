# INFRA-8200 — close not-a-bug: auto-filed cluster-stuck gap (duplicate of INFRA-8116)

INFRA-8200 was auto-filed by `pr-stuck-cluster-detector` ("5 PRs blocked >2h"). It
is the same condition as INFRA-8116 (score 1.00 at reserve time), INFRA-8191 (#5817)
and INFRA-8196 (#5818): the detector re-filed a new gap each time the blocked-PR
*set* drifted.

## Diagnosis (2026-11-07)

- Blocked PRs fall into unrelated classes (stale PRs needing rebase + fresh CI,
  owned by `pr-repair-rebase` / queue-tender; recent PRs whose `fast-checks` hit
  the CI job ceiling). No shared code defect.
- The re-filing loop was fixed by INFRA-8182: #5810 (skip re-filing while an open
  cluster gap exists) and #5812 (global cooldown across PR-set drift).

## Disposition

Closed as duplicate of INFRA-8116 / superseded by INFRA-8182. No code change.
