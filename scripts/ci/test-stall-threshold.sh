#!/usr/bin/env bash
# test-stall-threshold.sh — RESILIENT-1739
#
# Behavioural regression test for the fleet stall-detector threshold scaler
# and kill classifier. Sources the REAL compute_stall_threshold() /
# stall_kill_classify() that worker.sh uses and proves:
#   - effort-based defaults (xs=300 s/m=600 l/xl=900)
#   - x1.5 load scaling when loadavg > cores*0.7
#   - a node.env CHUMP_STALL_THRESHOLD_S override wins, re-read fresh each
#     call (no worker.sh restart needed — AC3)
#   - process-env CHUMP_STALL_THRESHOLD_S is honored absent a node.env file
#   - stall_kill_classify never confuses a stall kill with a backend outage
#   - worker.sh is wired to skip classify_sub_failure on a stall kill
#     (structural guard for AC2)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/dispatch/lib/stall-threshold.sh"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

if [ ! -r "$LIB" ]; then
    echo "FAIL: $LIB not found"; exit 1
fi
# shellcheck source=../dispatch/lib/stall-threshold.sh
source "$LIB"

fail=0
check() { # desc expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (expected '$2', got '$3')"; fail=1
    fi
}

TMP_NODE_ENV="$(mktemp)"
trap 'rm -f "$TMP_NODE_ENV"' EXIT

echo "== effort defaults (no override, loadavg well under cores*0.7) =="
check "xs => 300s"      300 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold xs 0.1 4 /nonexistent)"
check "s  => 600s"      600 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold s 0.1 4 /nonexistent)"
check "m  => 600s"      600 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold m 0.1 4 /nonexistent)"
check "l  => 900s"      900 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold l 0.1 4 /nonexistent)"
check "xl => 900s"      900 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold xl 0.1 4 /nonexistent)"
check "unknown => 600s" 600 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold zzz 0.1 4 /nonexistent)"

echo "== load scaling: x1.5 when loadavg > cores*0.7 =="
check "4 cores, load 2.4 (> 2.8? no) => s stays 600"   600 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold s 2.4 4 /nonexistent)"
check "4 cores, load 3.0 (> 2.8 yes) => s scales to 900" 900 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold s 3.0 4 /nonexistent)"
check "4 cores, load 3.0 => xs scales to 450"           450 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold xs 3.0 4 /nonexistent)"
check "4 cores, load 3.0 => xl scales to 1350"         1350 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold xl 3.0 4 /nonexistent)"
check "exactly at boundary (2.8) does not scale"        600 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold s 2.8 4 /nonexistent)"

echo "== node.env override (AC3: re-read fresh, no restart needed) =="
printf 'CHUMP_STALL_THRESHOLD_S=600\n' > "$TMP_NODE_ENV"
check "node.env override wins over effort default" 600 "$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold xs 0.1 4 "$TMP_NODE_ENV")"
printf 'export CHUMP_STALL_THRESHOLD_S=333\n' > "$TMP_NODE_ENV"
_v1="$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold xs 0.1 4 "$TMP_NODE_ENV")"
printf 'export CHUMP_STALL_THRESHOLD_S=777\n' > "$TMP_NODE_ENV"
_v2="$(CHUMP_STALL_THRESHOLD_S= compute_stall_threshold xs 0.1 4 "$TMP_NODE_ENV")"
check "first read picks up 333"           333 "$_v1"
check "edit takes effect on next call (no restart)" 777 "$_v2"

echo "== process-env override (no node.env file present) =="
check "process env CHUMP_STALL_THRESHOLD_S honored" 450 \
    "$(CHUMP_STALL_THRESHOLD_S=450 compute_stall_threshold xs 0.1 4 /nonexistent)"

echo "== stall_kill_classify =="
check "marker present => stall_kill" "stall_kill" "$(stall_kill_classify 1)"
check "marker absent  => none"       "none"       "$(stall_kill_classify 0)"
check "default (no arg) => none"     "none"       "$(stall_kill_classify)"

echo "== worker.sh wiring (structural guard for AC2) =="
if grep -qF '_was_stall_killed=0' "$WORKER" && grep -qF 'if [[ -f "$_stall_kill_marker" ]]; then' "$WORKER"; then
    echo "PASS: worker.sh tracks whether this cycle was stall-killed"
else
    echo "FAIL: worker.sh missing stall-kill marker tracking"; fail=1
fi
if grep -qE '\[\[ "\$_orig_backend" == "claude" \]\] && \[\[ "\$rc" -ne 124 \]\] && \[\[ "\$\{_was_stall_killed:-0\}" -ne 1 \]\]' "$WORKER"; then
    echo "PASS: RESILIENT-575 backend-fallback classifier excludes stall kills"
else
    echo "FAIL: RESILIENT-575 backend-fallback classifier does not exclude stall kills"; fail=1
fi
if grep -qF '"kind":"cycle_stall_killed","class":"stall_kill"' "$WORKER"; then
    echo "PASS: cycle_stall_killed event carries class=stall_kill"
else
    echo "FAIL: cycle_stall_killed event missing class=stall_kill"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "OK: stall-detector threshold scaler + kill classifier"
    exit 0
else
    echo "FAILED: stall-threshold regression"
    exit 1
fi
