#!/usr/bin/env bash
# test-almanac-census-summarize-pct-enforcement.sh — CREDIBLE-891 (CREDIBLE-300 slice)
#
# almanac-census.py's `--summarize-pct` mode used to only REPORT the
# summarized_pct metric, never enforce the >95% mission floor the rest of
# the CREDIBLE-300 slice already enforces elsewhere (almanac-vision-keeper.sh,
# almanac-summarize-watchdog.sh, board-vitals.sh). This closes that one
# remaining unenforced code path: at/below the floor must log an error and
# exit non-zero; above it must still exit 0 and print the metric.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SCRIPT="scripts/dev/almanac-census.py"
HIGH_FIXTURE="scripts/dev/fixtures/almanac-census-summarize-pct-high.json"
LOW_FIXTURE="scripts/dev/fixtures/almanac-census-summarize-pct-low.json"

[ -f "$HIGH_FIXTURE" ] || { echo "FAIL: fixture missing: $HIGH_FIXTURE"; exit 1; }
[ -f "$LOW_FIXTURE" ] || { echo "FAIL: fixture missing: $LOW_FIXTURE"; exit 1; }

# AC2/AC3: at/below the 95% floor must abort (non-zero exit) with an error
# logged to stderr naming the computed percentage.
set +e
LOW_OUT="$(python3 "$SCRIPT" --summarize-pct --fixture "$LOW_FIXTURE" 2>&1)"
LOW_EXIT=$?
set -e
[ "$LOW_EXIT" -ne 0 ] || { echo "FAIL: expected non-zero exit for below-floor coverage, got 0. Output: $LOW_OUT"; exit 1; }
echo "$LOW_OUT" | grep -qi "summarized_pct must be" \
  || { echo "FAIL: expected an enforcement error message, got: $LOW_OUT"; exit 1; }
echo "PASS: below-floor summarized_pct (90%) aborts with non-zero exit + logged error"

# AC2/AC4: above the 95% floor must exit 0 and still print the metric —
# no existing (reporting) behavior regresses.
HIGH_OUT="$(python3 "$SCRIPT" --summarize-pct --fixture "$HIGH_FIXTURE")"
echo "$HIGH_OUT" | grep -q "almanac_coverage_summarized_pct : 0.96" \
  || { echo "FAIL: expected metric line for above-floor coverage, got: $HIGH_OUT"; exit 1; }
echo "PASS: above-floor summarized_pct (96%) exits 0 and still emits the metric"
