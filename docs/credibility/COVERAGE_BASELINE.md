# Code Coverage Baseline (CREDIBLE-006)

Tracks line/function coverage measured by `cargo llvm-cov` in CI.

## Current baseline

| Metric            | Value              |
|-------------------|--------------------|
| Line coverage     | (pending first run) |
| Function coverage | (pending first run) |
| Measured at       | (pending first run) |
| Commit            | (pending first run) |

> **Note:** The baseline will be populated automatically by the first successful
> `coverage` CI job run after CREDIBLE-006 merges. Until then the threshold
> check is informational-only.

## Tracking policy (per CREDIBLE-006 design note)

1. **Baseline first.** Measure and record before enforcing any gate.
2. **PR warning.** CI warns (non-blocking) when a PR drops total line coverage
   by more than `CHUMP_COVERAGE_DROP_THRESHOLD` percentage points (default 2 pp).
3. **No hard gate yet.** Hard blocking deferred until baseline is stable for
   2 weeks. Prevents the "tests later" anti-pattern while the floor is unknown.
4. **Threshold env.** Set `CHUMP_COVERAGE_DROP_THRESHOLD=<N>` to adjust; 0
   disables the warning.

## How to update the baseline

After a PR lands and the coverage job runs successfully, update this file:

```bash
# From ci/coverage job output artifact coverage-summary.txt:
grep "lines\|functions" coverage-summary.txt
# Edit this file with the new numbers.
# Commit: git commit -m "chore: update COVERAGE_BASELINE.md after <commit-sha>"
```

## Related

- Gap: CREDIBLE-006
- CI job: `.github/workflows/ci.yml` → `coverage` job
- Artifact: `coverage-lcov` (lcov format, uploaded per run)
