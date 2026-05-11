#!/usr/bin/env bash
# test-reaper-resurrect.sh — INFRA-819 unit tests.
#
# Verifies the ENOSPC-resilience additions to heartbeat-watcher.sh:
#
#   (1) disk-preflight triggers when available MB < CHUMP_HEARTBEAT_MIN_FREE_MB
#   (2) exits 1 (not 0) under disk pressure — enables KeepAlive:{Crashed:true}
#   (3) emits reaper_self_paused ambient event under disk pressure
#   (4) passes through to normal startup when disk is healthy
#   (5) CHUMP_HEARTBEAT_MIN_FREE_MB env var is respected
#   (6) ThrottleInterval=60 present in heartbeat-watcher.plist (not 10)
#   (7) KeepAlive dict (not simple bool) in heartbeat-watcher.plist
#   (8) synthesis-pass.plist has ThrottleInterval
#
# Run: ./scripts/ci/test-reaper-resurrect.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HW_SCRIPT="$REPO_ROOT/scripts/dev/heartbeat-watcher.sh"
HW_PLIST="$REPO_ROOT/launchd/com.chump.heartbeat-watcher.plist"
SP_PLIST="$REPO_ROOT/launchd/com.chump.synthesis-pass.plist"

echo "=== INFRA-819 reaper ENOSPC-resurrect unit tests ==="
echo

# ── Test 1+2+3: disk pressure triggers exit 1 + reaper_self_paused ────────────
echo "--- Test 1-3: disk preflight under simulated disk pressure ---"
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

# Create a fake LOCK_DIR and ambient log in tmpdir
_fake_lock="$_tmpdir/locks"
mkdir -p "$_fake_lock"

# Run start with artificially low threshold (999999 MB > any real disk)
set +e
_t123_out=$(
    CHUMP_LOCK_DIR="$_fake_lock" \
    CHUMP_AMBIENT_LOG="$_fake_lock/ambient.jsonl" \
    CHUMP_HEARTBEAT_MIN_FREE_MB=999999 \
    bash "$HW_SCRIPT" start 2>&1
)
_t123_rc=$?
set -e

# Test 1: preflight should have triggered (exit non-zero under 999999 MB threshold)
[[ $_t123_rc -ne 0 ]] \
    && ok "Test 1: exits non-zero under simulated disk pressure (rc=$_t123_rc)" \
    || fail "Test 1: expected non-zero exit under disk pressure, got rc=$_t123_rc"

# Test 2: exit code should be 1 specifically
[[ $_t123_rc -eq 1 ]] \
    && ok "Test 2: exit code is exactly 1 (enables KeepAlive:Crashed:true)" \
    || fail "Test 2: expected exit 1, got $__t123_rc; KeepAlive:Crashed:true requires non-zero"

# Test 3: reaper_self_paused event emitted (to stderr or ambient.jsonl)
if echo "$_t123_out" | grep -q "reaper_self_paused\|disk critically low"; then
    ok "Test 3: reaper_self_paused event / disk-critical message present in output"
elif [[ -f "$_fake_lock/ambient.jsonl" ]] && grep -q "reaper_self_paused" "$_fake_lock/ambient.jsonl" 2>/dev/null; then
    ok "Test 3: reaper_self_paused event written to ambient.jsonl"
else
    fail "Test 3: no reaper_self_paused event found in stderr or ambient.jsonl"
fi

# ── Test 4: healthy disk passes preflight ─────────────────────────────────────
echo "--- Test 4: healthy disk passes preflight ---"
# With min=0, the preflight should not trigger.
set +e
_t4_rc=0
CHUMP_LOCK_DIR="$_fake_lock" \
CHUMP_AMBIENT_LOG="$_fake_lock/ambient.jsonl" \
CHUMP_HEARTBEAT_MIN_FREE_MB=0 \
timeout 2 bash "$HW_SCRIPT" start 2>/dev/null &
_t4_pid=$!
sleep 0.5
# Kill the watcher; if it started, it should still be running (pid file exists).
_t4_pf="$_fake_lock/.heartbeat-watcher.pid"
if [[ -f "$_t4_pf" ]]; then
    kill "$(cat "$_t4_pf")" 2>/dev/null || true
    rm -f "$_t4_pf"
    ok "Test 4: preflight passed when min_free_mb=0; watcher started (PID file created)"
else
    # May have exited fast or PID file not created yet; check rc
    wait "$_t4_pid" 2>/dev/null; _t4_rc=$?
    [[ $_t4_rc -eq 0 ]] \
        && ok "Test 4: preflight passed cleanly (exit 0, no PID file needed in fast path)" \
        || fail "Test 4: expected healthy disk to pass preflight; got rc=$_t4_rc"
fi
wait 2>/dev/null || true
set -e

# ── Test 5: CHUMP_HEARTBEAT_MIN_FREE_MB env var respected ─────────────────────
echo "--- Test 5: CHUMP_HEARTBEAT_MIN_FREE_MB env var respected ---"
# With min=1, the preflight should pass (any real disk has >1 MB).
# We use a tmpdir2 for isolation and kill the watcher immediately after.
_tmpdir2=$(mktemp -d)
trap 'rm -rf "$_tmpdir2"' EXIT
_fake2="$_tmpdir2/locks"
mkdir -p "$_fake2"
set +e
CHUMP_LOCK_DIR="$_fake2" CHUMP_AMBIENT_LOG="$_fake2/ambient.jsonl" \
    CHUMP_HEARTBEAT_MIN_FREE_MB=1 bash "$HW_SCRIPT" start >"$_tmpdir2/t5.out" 2>&1 &
_t5_bg=$!
sleep 0.8   # give the watcher time to write its PID file and start
_t5_pf="$_fake2/.heartbeat-watcher.pid"
if [[ -f "$_t5_pf" ]]; then
    kill "$(cat "$_t5_pf")" 2>/dev/null || true
    rm -f "$_t5_pf"
    ok "Test 5: CHUMP_HEARTBEAT_MIN_FREE_MB=1 allows start (PID file created)"
else
    # If no PID file, the start script might have exited non-zero (preflight triggered)
    kill "$_t5_bg" 2>/dev/null || true
    wait "$_t5_bg" 2>/dev/null; _t5_rc=$?
    [[ $_t5_rc -eq 0 ]] \
        && ok "Test 5: CHUMP_HEARTBEAT_MIN_FREE_MB=1 passed (exit 0)" \
        || fail "Test 5: CHUMP_HEARTBEAT_MIN_FREE_MB=1 should pass; rc=$_t5_rc out=$(cat "$_tmpdir2/t5.out" 2>/dev/null)"
fi
kill "$_t5_bg" 2>/dev/null || true
wait "$_t5_bg" 2>/dev/null || true
set -e

# ── Test 6: heartbeat-watcher plist has ThrottleInterval >= 60 ───────────────
# Use grep/awk to parse the XML plist — plistlib's pyexpat may be unavailable.
echo "--- Test 6: heartbeat-watcher.plist ThrottleInterval >= 60 ---"
if [[ ! -f "$HW_PLIST" ]]; then
    fail "Test 6: $HW_PLIST not found"
else
    # Extract the integer value that follows a <key>ThrottleInterval</key> line.
    _throttle=$(awk '/<key>ThrottleInterval<\/key>/{getline; gsub(/[^0-9]/,"",$0); print; exit}' "$HW_PLIST" 2>/dev/null || echo "0")
    [[ "${_throttle:-0}" -ge 60 ]] \
        && ok "Test 6: ThrottleInterval=${_throttle} >= 60 in heartbeat-watcher.plist" \
        || fail "Test 6: ThrottleInterval=${_throttle} too low (need >=60 to avoid crash-loop throttle)"
fi

# ── Test 7: heartbeat-watcher plist uses KeepAlive dict (not simple bool) ─────
echo "--- Test 7: heartbeat-watcher.plist KeepAlive is a dict ---"
if [[ ! -f "$HW_PLIST" ]]; then
    fail "Test 7: $HW_PLIST not found"
else
    # After <key>KeepAlive</key> the value should be a <dict> (not <true/> or <false/>).
    # Use grep: look for <dict> within 3 lines after <key>KeepAlive</key>.
    _ka_is_dict=$(grep -A 3 '<key>KeepAlive</key>' "$HW_PLIST" 2>/dev/null | grep -c '<dict>' || echo "0")
    [[ "${_ka_is_dict:-0}" -gt 0 ]] \
        && ok "Test 7: KeepAlive value is a <dict> (conditional restart config)" \
        || fail "Test 7: <dict> not found within 3 lines after <key>KeepAlive</key>; KeepAlive must be a conditional dict"
fi

# ── Test 8: synthesis-pass.plist has ThrottleInterval ────────────────────────
echo "--- Test 8: synthesis-pass.plist has ThrottleInterval ---"
if [[ ! -f "$SP_PLIST" ]]; then
    fail "Test 8: $SP_PLIST not found"
else
    _sp_throttle=$(awk '/<key>ThrottleInterval<\/key>/{getline; gsub(/[^0-9]/,"",$0); print; exit}' "$SP_PLIST" 2>/dev/null || echo "0")
    [[ "${_sp_throttle:-0}" -gt 0 ]] \
        && ok "Test 8: synthesis-pass.plist has ThrottleInterval=${_sp_throttle}" \
        || fail "Test 8: synthesis-pass.plist missing ThrottleInterval"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
