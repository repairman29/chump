#!/usr/bin/env bash
# CREDIBLE-1087 (CREDIBLE-274 slice): non-failing reporting wrapper around
# scripts/ci/check-grep-target-sweep.py.
#
# check-grep-target-sweep.py is the CI *gate* (exits 1 on a vacuous grep
# target so it can block a PR). This script is the advisory *report*
# variant: same detection logic (reused via --json, not re-implemented),
# but always exits 0 so it can be run ad hoc / from a dashboard / from a
# curator loop without risking a non-zero exit anywhere it's wired in.
#
# Usage:
#   scripts/ci/grep-target-sweep-report.sh
#
# Exit codes:
#   0 — always (per AC4), regardless of findings

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/check-grep-target-sweep.py"

REPORT_JSON="$(python3 "$CHECKER" --json)"

MISSING_COUNT="$(echo "$REPORT_JSON" | jq -r '.missing_count')"

echo "[grep-target-sweep-report] scanned scripts/ci for grep targets"
echo "[grep-target-sweep-report] vacuous_grep_count=${MISSING_COUNT}"

if [[ "$MISSING_COUNT" -gt 0 ]]; then
  echo "$REPORT_JSON" | jq -r '.missing[] | "  \(.source_file):\(.line) — missing grep target \x27\(.target)\x27"'
fi

exit 0
