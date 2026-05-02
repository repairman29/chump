#!/usr/bin/env bash
# test-reaper-instrumentation.sh — INFRA-120 unit test for the reaper
# heartbeat / ambient-event / log-rotation library.
#
# Verifies:
#   1. reaper_setup resolves the main repo even when sourced from a worktree.
#   2. reaper_finish stamps /tmp/chump-reaper-<NAME>.heartbeat.
#   3. reaper_finish appends a single valid kind=reaper_run JSON to ambient.jsonl.
#   4. reaper_rotate_log truncates files over the cap and leaves them under cap.
#   5. The watchdog ALERTs when a heartbeat is missing AND when it's stale.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/reaper-instrumentation.sh"
WATCHDOG="$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f /tmp/chump-reaper-citest-*.heartbeat' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Set up an isolated fake repo so we don't pollute the real .chump-locks.
git -C "$TMP" init -q
mkdir -p "$TMP/.chump-locks"

# Test 1: setup + emit + heartbeat
NAME="citest-$$"
HB="/tmp/chump-reaper-${NAME}.heartbeat"
rm -f "$HB"

(
    cd "$TMP"
    # shellcheck disable=SC1090
    source "$LIB"
    reaper_setup "$NAME"
    reaper_finish ok '{"closed":2,"warned":0}'
)

[[ -f "$HB" ]] || fail "heartbeat file not created at $HB"
grep -q '^ts=' "$HB" || fail "heartbeat missing ts= line"
grep -q '^status=ok' "$HB" || fail "heartbeat missing status=ok"
grep -q '^counts={"closed":2,"warned":0}$' "$HB" || fail "heartbeat counts wrong: $(cat "$HB")"
ok "heartbeat written with expected fields"

# Test 2: ambient.jsonl line is valid JSON with the right shape
LAST=$(tail -1 "$TMP/.chump-locks/ambient.jsonl")
echo "$LAST" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['kind'] == 'reaper_run', f'wrong kind: {d}'
assert d['reaper'] == '$NAME', f'wrong reaper: {d}'
assert d['status'] == 'ok'
assert d['counts'] == {'closed': 2, 'warned': 0}, f'wrong counts: {d}'
assert isinstance(d['duration_secs'], int)
" || fail "ambient.jsonl line malformed: $LAST"
ok "ambient.jsonl reaper_run event is valid JSON"

# Test 3: log rotation
LOG_TMP="$TMP/big.log"
# Create a 6 MB file (over default 5 MB cap).
dd if=/dev/zero of="$LOG_TMP" bs=1024 count=6144 status=none
(
    cd "$TMP"
    source "$LIB"
    reaper_setup "$NAME"
    reaper_rotate_log "$LOG_TMP"
)
[[ -f "${LOG_TMP}.1" ]] || fail "rotation did not create .1 archive"
SIZE_NEW=$(stat -f%z "$LOG_TMP" 2>/dev/null || stat -c%s "$LOG_TMP")
[[ "$SIZE_NEW" -eq 0 ]] || fail "rotated file should be truncated, got $SIZE_NEW bytes"
ok "log rotation moved oversize file to .1 and reset live file"

# Test 4: rotation no-op for under-cap file
SMALL="$TMP/small.log"
echo "tiny" > "$SMALL"
(
    cd "$TMP"
    source "$LIB"
    reaper_setup "$NAME"
    reaper_rotate_log "$SMALL"
)
[[ ! -f "${SMALL}.1" ]] || fail "rotation should not have rotated under-cap file"
ok "log rotation is a no-op for under-cap files"

# Test 5: watchdog ALERTs when heartbeat is missing
MISSING="watchdog-missing-$$"
rm -f "/tmp/chump-reaper-${MISSING}.heartbeat"
WATCHDOG_OUT=$("$WATCHDOG" "$MISSING" 2>&1 || true)
echo "$WATCHDOG_OUT" | grep -q "ALERT \[reaper_silent\] reaper $MISSING has never heartbeated" \
    || fail "watchdog did not ALERT on missing heartbeat. Got:\n$WATCHDOG_OUT"
ok "watchdog ALERTs on missing heartbeat"

# Test 6: watchdog OK when heartbeat is fresh
HB_FRESH="/tmp/chump-reaper-${NAME}.heartbeat"
WATCHDOG_OUT=$("$WATCHDOG" "$NAME" 2>&1 || true)
echo "$WATCHDOG_OUT" | grep -q "ok: $NAME heartbeated" \
    || fail "watchdog did not see fresh heartbeat. Got:\n$WATCHDOG_OUT"
ok "watchdog reports OK on fresh heartbeat"

# Test 7: watchdog ALERTs on stale heartbeat (backdated > 4h for worktree threshold).
STALE="worktree"
HB_STALE="/tmp/chump-reaper-${STALE}.heartbeat"
TS_STALE=$(date -u -v-10H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 hours ago' +%Y-%m-%dT%H:%M:%SZ)
{
    echo "ts=$TS_STALE"
    echo "status=ok"
    echo "duration=1"
    echo "counts={}"
} > "$HB_STALE"
WATCHDOG_OUT=$("$WATCHDOG" "$STALE" 2>&1 || true)
echo "$WATCHDOG_OUT" | grep -q "ALERT \[reaper_silent\] reaper $STALE has not run in" \
    || fail "watchdog did not ALERT on stale heartbeat. Got:\n$WATCHDOG_OUT"
ok "watchdog ALERTs on stale heartbeat"
rm -f "$HB_STALE"

echo ""
printf '\033[0;32m=== all reaper instrumentation tests passed ===\033[0m\n'
