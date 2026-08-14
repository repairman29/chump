#!/usr/bin/env bash
# test-worker-heartbeat-full-cycle.sh — RESILIENT-179
#
# The FLEET-042 heartbeat writer used to be a background subshell scoped to
# only the `claude -p` window: started right before the claude spawn, killed
# right after it exited. Every other phase of a cycle (worktree setup, model
# resolution, ship-phase gh/CI polling for chump-local backend, INFRA-771
# re-engagement scan, cycle_end bookkeeping) ran with a heartbeat frozen at
# pick time. Those phases routinely run 10-20 min — well past chumpd's 900s
# wedge threshold — so chumpd wedge-killed HEALTHY workers mid-ship (16/night
# on the first chumpd night).
#
# The fix: a single heartbeat daemon for the WHOLE worker process lifetime,
# started before the main pick loop and torn down only on process exit
# (RESILIENT-179 AC1). This test extracts the real heartbeat block out of
# worker.sh (not a reimplementation) and proves the file stays fresh across
# a simulated multi-minute "no claude call happening" phase.
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== RESILIENT-179 worker.sh full-cycle heartbeat test ==="
echo

# ── Static assertions ────────────────────────────────────────────────────
if grep -q "RESILIENT-179" "$WORKER"; then
    ok "RESILIENT-179 referenced in worker.sh"
else
    fail "RESILIENT-179 marker missing from worker.sh"
fi

if grep -q '_heartbeat_daemon_pid=\$!' "$WORKER"; then
    ok "lifetime heartbeat daemon pid captured"
else
    fail "lifetime heartbeat daemon pid capture missing"
fi

if grep -q "trap remove_heartbeat_and_daemon EXIT" "$WORKER"; then
    ok "EXIT trap tears down the lifetime daemon"
else
    fail "EXIT trap does not reference remove_heartbeat_and_daemon"
fi

# The daemon must be defined BEFORE the main `while :; do` pick loop so it
# spans pick/setup/ship/post-processing, not just the claude -p call.
_daemon_line=$(grep -n '_heartbeat_daemon_pid=\$!' "$WORKER" | head -1 | cut -d: -f1)
_loop_line=$(grep -n '^while :; do$' "$WORKER" | head -1 | cut -d: -f1)
if [[ -n "$_daemon_line" && -n "$_loop_line" && "$_daemon_line" -lt "$_loop_line" ]]; then
    ok "heartbeat daemon starts before the main pick loop (line $_daemon_line < $_loop_line)"
else
    fail "heartbeat daemon does not start before the main pick loop (daemon=$_daemon_line loop=$_loop_line)"
fi

# ── Functional: extract the real heartbeat block and run it ────────────────
# Pull the exact code between the write_heartbeat() def and the EXIT trap
# registration, so this test breaks if the mechanism regresses/drifts.
TMP="$(mktemp -d)"
trap 'kill "${_daemon_pid:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT

BLOCK="$TMP/heartbeat_block.sh"
sed -n '/^write_heartbeat() {/,/^trap remove_heartbeat_and_daemon EXIT$/p' "$WORKER" > "$BLOCK"
if [[ ! -s "$BLOCK" ]]; then
    fail "could not extract heartbeat block from worker.sh (markers moved?)"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

AGENT_ID="hbtest-$$"
_heartbeat_interval=2  # scaled down from prod's 60s for a fast test
HEARTBEAT_FILE="/tmp/chump-fleet-worker-${AGENT_ID}.heartbeat"
rm -f "$HEARTBEAT_FILE"

(
    AGENT_ID="$AGENT_ID"
    _heartbeat_interval="$_heartbeat_interval"
    # shellcheck disable=SC1090
    source "$BLOCK"
    # Simulate a long no-claude phase (worktree setup, ship polling, etc.)
    # with nothing else touching the heartbeat — just sleep like the real
    # gap between pick and the claude spawn (or after claude exits).
    sleep 20
) &
_daemon_pid=$!

# While the simulated no-claude phase runs, sample heartbeat freshness
# every second and confirm it never goes stale beyond 2x the interval.
# NOTE: check freshness INSIDE the loop, not after `wait` — the daemon's own
# EXIT trap (remove_heartbeat_and_daemon) deletes the file the instant the
# simulated phase's background job ends, so a post-wait check would always
# see a just-deleted file regardless of whether the daemon behaved correctly.
_stale_seen=0
_file_seen=0
_samples=0
for _ in $(seq 1 15); do
    sleep 1
    _samples=$((_samples + 1))
    if [[ -f "$HEARTBEAT_FILE" ]]; then
        _file_seen=1
        _hb_ts=$(awk '{print $1}' "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
        _age=$(( $(date +%s) - _hb_ts ))
        if [[ "$_age" -gt $(( _heartbeat_interval * 3 )) ]]; then
            _stale_seen=1
        fi
    else
        _stale_seen=1
    fi
done
wait "$_daemon_pid" 2>/dev/null

if [[ "$_file_seen" -eq 1 ]] && [[ "$_stale_seen" -eq 0 ]]; then
    ok "heartbeat stayed fresh across simulated no-claude phase ($_samples samples)"
else
    fail "heartbeat went stale during simulated no-claude phase (file_seen=$_file_seen stale_seen=$_stale_seen)"
fi

rm -f "$HEARTBEAT_FILE" "/tmp/chump-fleet-worker-${AGENT_ID}.heartbeat.gapid" 2>/dev/null || true

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
