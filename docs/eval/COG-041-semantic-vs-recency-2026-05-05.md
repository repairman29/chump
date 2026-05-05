# EVAL-098: COG-041 semantic vs recency-frequency lesson rankings

Generated: 2026-05-05T18:21:09Z
Methodology: docs/eval/preregistered/EVAL-098.md

## Sampled gaps (n=10)

```
     1	INFRA-WORKTREE-STAGING
     2	INFRA-WORKTREE-REAPER-FIX
     3	INFRA-WORKTREE-REAPER
     4	INFRA-WORKTREE-PATH-CASE
     5	INFRA-WHITE-PAPERS-TRIGGER
     6	INFRA-WHITE-PAPERS-PANDOC
     7	INFRA-SYNTHESIS-CADENCE
     8	INFRA-STUCK-QUEUE-RUNBOOK
     9	INFRA-QUEUE-DRIVER-PERMS
    10	INFRA-QUEUE-DRIVER-APP-TOKEN
```

## Per-gap Jaccard overlap

| Gap | \|A∩B\| | \|A∪B\| | Jaccard | B-only top | A-only top |
|-----|--------|--------|---------|------------|------------|
| INFRA-WORKTREE-STAGING | 1 | 5 | 0.200 | - | Claim gaps via gap-claim.sh which writes lease fil |
| INFRA-WORKTREE-REAPER-FIX | 1 | 5 | 0.200 | - | Claim gaps via gap-claim.sh which writes lease fil |
| INFRA-WORKTREE-REAPER | 5 | 5 | 1.000 | - | - |
| INFRA-WORKTREE-PATH-CASE | 1 | 5 | 0.200 | - | Claim gaps via gap-claim.sh which writes lease fil |
| INFRA-WHITE-PAPERS-TRIGGER | 5 | 5 | 1.000 | - | - |
| INFRA-WHITE-PAPERS-PANDOC | 5 | 5 | 1.000 | - | - |
| INFRA-SYNTHESIS-CADENCE | 2 | 5 | 0.400 | - | GH Actions multi-line strings inside 'run: |' bloc |
| INFRA-STUCK-QUEUE-RUNBOOK | 5 | 5 | 1.000 | - | - |
| INFRA-QUEUE-DRIVER-PERMS | 5 | 5 | 1.000 | - | - |
| INFRA-QUEUE-DRIVER-APP-TOKEN | 2 | 5 | 0.400 | - | Claim gaps via gap-claim.sh which writes lease fil |

## Aggregate

| Metric | Value |
|--------|-------|
| Sample size (n) | 10 |
| Mean Jaccard | 0.640 |
| Fraction meaningfully different (Jaccard < 0.6) | 0.50 |
| Mode-B empty (fell back to recency-freq) | 0 / 10 |

## Decision (per prereg)

**Verdict:** ACCEPT H1 (semantic mode produces meaningfully different rankings on ≥ 50% of sampled gaps)

**What this eval can claim:** divergence only — not quality. A follow-up downstream
eval (e.g. ship-rate per lesson set) is required before flipping the default.
