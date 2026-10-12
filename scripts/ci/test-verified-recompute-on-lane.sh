#!/usr/bin/env bash
# test-verified-recompute-on-lane.sh — RESILIENT-1562
set -euo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/ci/verified-recompute-on-lane.sh"
fail=0
run() { # $1=job json  -> output
    JOB="$1" bash -c '
      gh() {
        case "$*" in
          *workflows/ci.yml/runs*) echo 42 ;;
          *actions/runs/42/jobs*) echo "$JOB" ;;
          *"run rerun"*) echo "RERUN $*" ;;
        esac
      }
      export -f gh
      bash '"$S"' --sha abc --dry-run'
}
out="$(run '{"id":7,"status":"completed","conclusion":"failure"}')"
grep -q "would 'gh run rerun 42 --job 7'" <<<"$out" || { echo "FAIL: failed verified not rerun: $out"; fail=1; }
out="$(run '{"id":7,"status":"completed","conclusion":"success"}')"
grep -q "nothing to do" <<<"$out" || { echo "FAIL: success rerun: $out"; fail=1; }
out="$(run '{"id":7,"status":"in_progress","conclusion":null}')"
grep -q "still running" <<<"$out" || { echo "FAIL: in-progress: $out"; fail=1; }
[[ $fail -eq 0 ]] && echo "PASS: verified-recompute-on-lane" || exit 1
