# INFRA-8196 — close not-a-bug: auto-filed cluster-stuck gap (duplicate of INFRA-8116)

INFRA-8196 was auto-filed by `pr-stuck-cluster-detector` ("5 PRs blocked >2h"). It
is the same condition as INFRA-8116 (score 1.00 at reserve time, "6 PRs blocked
>2h") and INFRA-8191 (closed the same way in #5817): the detector re-filed a new
gap each time the blocked-PR *set* drifted.

## Diagnosis (2026-11-07)

- Open PRs show BLOCKED/DIRTY in two unrelated classes, neither a shared code defect:
  stale PRs (opened 10-24..11-01) needing rebase + fresh CI, owned by
  `pr-repair-rebase` / queue-tender; and recent PRs whose `fast-checks` hit the
  CI job ceiling (runner/CI timeout, not PR-specific).
- The re-filing loop (the actual defect) was fixed by INFRA-8182: #5810 (skip
  re-filing while an open cluster gap exists) and #5812 (global cooldown across
  PR-set drift). No new code path is needed here.

## Disposition

Closed as duplicate of INFRA-8116 / superseded by INFRA-8182.
