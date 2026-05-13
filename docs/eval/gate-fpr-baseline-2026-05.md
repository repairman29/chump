# CI Gate False-Positive Rate Baseline — 2026-05

**Gap:** EVAL-124
**Date:** 2026-05-13T19:10:02Z
**PRs analyzed:** 30 most-recently merged PRs
**Method:** Automated script applying simplified gate logic to PR metadata and file lists via GitHub REST API. Note: full gate scripts need git context; this is an approximation. See CREDIBLE-048 for production telemetry.

## Summary

| Gate | PRs | Fires | Fire rate | Notes |
|---|---|---|---|---|
| check-pr-scope.sh | 30 | 0 | 0.0% | Rule A=0 C=0 |
| check-mass-deletion.sh | 30 | 0 | 0.0% | Rule A=0 B=0 |

**Overall fire rate:** 0.0% across both gates

## Interpretation

All fires where the PR merged without title/label changes are counted as FP candidates.
This baseline is for comparison with CREDIBLE-048 production telemetry, which will
give per-gate fire/TP/FP counts with operator-provided classifications.

## Per-PR Results

| PR | Title (truncated) | check-pr-scope | check-mass-deletion |
|---|---|---|---|
| #1678 | fix(INFRA-1001): CREDIBLE — restore green-main signal by f | pass | pass |
| #1680 | feat(EFFECTIVE-021): chump gap show renders AC as ✓/□ ch | pass | pass |
| #1677 | fix(INFRA-976): CREDIBLE — pr-hygiene title-lookup priorit | pass | pass |
| #1679 | docs(INFRA-958): RESILIENT — write force-push invariants d | pass | pass |
| #1676 | feat(INFRA-999): CREDIBLE — GitHub API cost telemetry via  | pass | pass |
| #1675 | feat(EFFECTIVE-020): chump gap set --add-note appends timest | pass | pass |
| #1665 | fix(INFRA-969): RESILIENT — worktree_root() rejects corrup | pass | pass |
| #1674 | docs(DOC-036): CHANGELOG v0.1.0 — reconcile module count w | pass | pass |
| #1669 | feat(INFRA-944): chump gap dep-clean subcommand — strips s | pass | pass |
| #1650 | feat(INFRA-964): RESILIENT — chump fleet daemon (OS-owned  | pass | pass |
| #1668 | feat(INFRA-975): RESILIENT — pre-claim + worker disk-low g | pass | pass |
| #1666 | feat(CREDIBLE-045): generic agent attribution in ship-rate � | pass | pass |
| #1662 | feat(CREDIBLE-041): no-bundle-PR policy — Rule C in check- | pass | pass |
| #1663 | docs(CREDIBLE-042): PR_HYGIENE.md — document all 6 require | pass | pass |
| #1660 | fix(CREDIBLE): ship_quality infra537 tests time-bomb on fixe | pass | pass |
| #1661 | feat(INFRA-983): MISSION — curator Decision 2 (gap_ac_fill | pass | pass |
| #1659 | feat(CREDIBLE-040): opencode-bigpickle commits as bigpickle@ | pass | pass |
| #1651 | fix(INFRA-973): worktree reaper continues on disk_critical ( | pass | pass |
| #1658 | feat(CREDIBLE-038): add Rule C (file-count-blast) to mass-de | pass | pass |
| #1652 | feat(INFRA-970): CREDIBLE — audit-gap-state-drift.sh tool | pass | pass |
| #1657 | fix(INFRA-977): RESILIENT — serialize doctor env-mutation  | pass | pass |
| #1656 | feat(INFRA-979): MISSION — curator's 3 file-a-gap decision | pass | pass |
| #1649 | fix(ship_quality): rolling-window-safe infra537 test timesta | pass | pass |
| #1653 | chore(INFRA-977): register doctor env-race flake to unblock  | pass | pass |
| #1648 | fix(ship_quality): rolling-window test fix + sync 10 shipped | pass | pass |
| #1570 | CREDIBLE: velocity + quality trending — 7d ship_rate/waste | pass | pass |
| #1605 | feat(credible-005): CREDIBLE — error-path tests for gap_st | pass | pass |
| #1597 | feat(credible-023): CREDIBLE — PWA gap endpoint security h | pass | pass |
| #1609 | feat(resilient-001): RESILIENT — per-worktree stale binary | pass | pass |
| #1580 | ZERO-WASTE(INFRA-931): worktree-contamination-check.sh + 14  | pass | pass |

## Calibration Update

Based on this baseline:
- **check-pr-scope.sh**: fire rate 0.0% — gate is appropriately calibrated (0 fires in last 30 PRs)
- **check-mass-deletion.sh**: fire rate 0.0% — gate is appropriately calibrated (0 fires in last 30 PRs)

See [docs/process/PR_HYGIENE.md](../process/PR_HYGIENE.md) for the calibration table.
