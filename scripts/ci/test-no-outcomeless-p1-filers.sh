#!/usr/bin/env bash
# INFRA-8043 guard: no auto-filer may write a P0/P1 gap without an outcome.
# Scans non-test scripts for `gap reserve` calls that combine P0/P1 with the
# --no-outcome-required bypass, and checks the gap_file filer demotes P0/P1.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1
fail=0
hits=$(grep -rnE 'gap reserve[^|]*--priority[ =]+"?P[01]|gap reserve[^|]*--no-outcome-required' scripts \
    --include=*.sh --include=*.py 2>/dev/null \
    | grep -vE '^scripts/ci/test-|^scripts/ci/.*fixture' | grep -E 'no-outcome-required' || true)
if [[ -n "$hits" ]]; then
    echo "FAIL: filer bypasses the outcome gate for P0/P1:"; echo "$hits"; fail=1
else
    echo "ok: no non-test filer uses --no-outcome-required"
fi
if grep -q 'Some(v) if matches!(v, "P0" | "P1"' src/gap_file.rs; then
    echo "FAIL: src/gap_file.rs lets P0/P1 through without an outcome"; fail=1
else
    echo "ok: gap_file filer demotes outcome-less P0/P1"
fi
exit $fail
