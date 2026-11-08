# INFRA-8214 — close not-a-bug: auto-filed cluster-stuck gap (duplicate of INFRA-8116)

INFRA-8214 was auto-filed by `pr-stuck-cluster-detector` ("6 PRs blocked >2h"). It is
the same condition as INFRA-8116, INFRA-8191, INFRA-8196, INFRA-8200, INFRA-8205,
INFRA-8206 and INFRA-8213: the detector re-filed a gap each time the blocked-PR set drifted.

## Diagnosis (2026-11-08)

- Blocked PRs are unrelated (distinct gaps: RESILIENT-1600/1602/1603, RESILIENT-2225/2226,
  ZERO-WASTE-153), waiting on required checks or rebase. No shared code defect.
- The re-filing loop was fixed by INFRA-8182: #5810 (skip re-filing while an open
  cluster gap exists) and #5812 (global cooldown across PR-set drift).

## Disposition

Closed as duplicate of INFRA-8116 / superseded by INFRA-8182. No code change.
