#!/usr/bin/env bash
# test-worker-timeout-scale.sh — RESILIENT-135
#
# Behavioural regression test for the fleet worker timeout scaler. It sources
# the REAL compute_scaled_timeout() that worker.sh uses (not a hand-copied
# replica) and proves the death-spiral cannot recur:
#   - effort multipliers are correct
#   - deriving each cycle from the IMMUTABLE base does NOT compound, while the
#     old derive-from-previous-result pattern provably collapses below it
#   - a floor guarantees the budget can never reach ~0s
#   - worker.sh is wired to pass the immutable base (structural guard)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/dispatch/lib/worker-timeout.sh"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

if [ ! -r "$LIB" ]; then
    echo "FAIL: $LIB not found"; exit 1
fi
# shellcheck source=../dispatch/lib/worker-timeout.sh
source "$LIB"

fail=0
check() { # desc expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (expected '$2', got '$3')"; fail=1
    fi
}

echo "== effort multipliers (1800s base) =="
check "xs => base*0.5"      900  "$(compute_scaled_timeout 1800 xs)"
check "s  => base*1.0"      1800 "$(compute_scaled_timeout 1800 s)"
check "m  => base*1.5"      2700 "$(compute_scaled_timeout 1800 m)"
check "l  => base*2.0"      3600 "$(compute_scaled_timeout 1800 l)"
check "xl => base*3.0"      5400 "$(compute_scaled_timeout 1800 xl)"
check "unknown => base*1.0" 1800 "$(compute_scaled_timeout 1800 zzz)"

echo "== the death-spiral regression (6 consecutive xs gaps) =="
# BUG pattern: derive each cycle from the PREVIOUS RESULT (what worker.sh:851 did).
buggy=1800; for _ in 1 2 3 4 5 6; do buggy="$(compute_scaled_timeout "$buggy" xs)"; done
# FIX pattern: derive each cycle from the IMMUTABLE base.
fixed=1800; for _ in 1 2 3 4 5 6; do fixed="$(compute_scaled_timeout 1800 xs)"; done
check "fix: derive-from-base stays workable" 900 "$fixed"
check "bug: derive-from-result collapses below fix" yes \
    "$([ "$buggy" -lt "$fixed" ] && echo yes || echo no)"

echo "== floor (death-spiral guard) and cap =="
check "floor: tiny base xs => MIN(120)" 120  "$(compute_scaled_timeout 100 xs)"   # 50  -> 120
check "floor: zero base    => MIN(120)" 120  "$(compute_scaled_timeout 0 xl)"      # 0   -> 120
check "cap: huge base xl   => MAX(7200)" 7200 "$(compute_scaled_timeout 5000 xl)"  # 15000 -> 7200
check "explicit min override"           300  "$(compute_scaled_timeout 100 xs 7200 300)"
check "explicit max override"           50   "$(compute_scaled_timeout 1000 xl 50 10)"

echo "== worker.sh wiring (structural guard) =="
if grep -qF 'FLEET_TIMEOUT_BASE_S="$FLEET_TIMEOUT_S"' "$WORKER"; then
    echo "PASS: worker.sh defines the immutable base"
else
    echo "FAIL: worker.sh missing FLEET_TIMEOUT_BASE_S init"; fail=1
fi
if grep -qF 'compute_scaled_timeout "${FLEET_TIMEOUT_BASE_S' "$WORKER"; then
    echo "PASS: worker.sh scaler derives from the immutable base"
else
    echo "FAIL: worker.sh scaler not wired to FLEET_TIMEOUT_BASE_S"; fail=1
fi
if grep -qE '_scaled_timeout=\$\(\(+[[:space:]]*FLEET_TIMEOUT_S[[:space:]]*\*' "$WORKER"; then
    echo "FAIL: worker.sh still derives _scaled_timeout from mutable FLEET_TIMEOUT_S (death-spiral)"; fail=1
else
    echo "PASS: no derive-from-mutable-global pattern"
fi

if [ "$fail" -eq 0 ]; then
    echo "OK: worker timeout scaler — no death-spiral"
    exit 0
else
    echo "FAILED: worker timeout scaler regression"
    exit 1
fi
