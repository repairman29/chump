#!/usr/bin/env bash
# test-fleet-auth-storm-detector.sh — INFRA-464
#
# Verifies worker.sh detects the 401-storm pattern (the 2026-05-03 Haiku
# fleet failure mode where 875/911 cycles silently 401'd for hours):
#  - tracks consecutive auth failures per worker in a counter file
#  - emits ALERT kind=fleet_auth_storm to ambient.jsonl after threshold
#  - resets the counter on any cycle whose log has no auth-failure marker

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -f "$WORKER" ]] || { echo "FATAL: worker.sh missing"; exit 2; }

echo "=== INFRA-464 fleet auth-storm detector test ==="
echo

# --- Test 1: detector code is present in worker.sh ---
if grep -q 'fleet_auth_storm' "$WORKER"; then
    ok "fleet_auth_storm detector present in worker.sh"
else
    fail "fleet_auth_storm detector missing"
fi

if grep -q 'Invalid authentication credentials' "$WORKER" \
   && grep -q 'API Error: 401' "$WORKER"; then
    ok "detector matches both 'Invalid authentication credentials' and 'API Error: 401'"
else
    fail "detector regex incomplete"
fi

# --- Test 2: extract the detector block as a sourceable snippet and run it ---
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build the test environment that the detector block reads:
FLEET_LOG_DIR="$TMPDIR_BASE/logs"
mkdir -p "$FLEET_LOG_DIR"
AMBIENT="$TMPDIR_BASE/ambient.jsonl"
cycle_log="$FLEET_LOG_DIR/agent-1-cycle1-INFRA-FAKE.log"

# Mock log helper (worker.sh uses `log "..."`).
LOG_FN='log() { printf "[test-log %s] %s\n" "$(date +%H:%M:%S)" "$*"; }'

# Extract the detector block. It starts at the comment '# ── INFRA-464:' and
# ends BEFORE 'if [ $rc -eq 0 ]; then'. Use awk with line-pattern matching.
DETECTOR="$TMPDIR_BASE/detector.sh"
awk '/^    # ── INFRA-464:/,/^    if \[ \$rc -eq 0 \]; then$/' "$WORKER" \
    | sed '$d' > "$DETECTOR"   # drop the trailing 'if [ $rc -eq 0 ]' line
# De-indent (strip the 4-space prefix from being inside the loop).
sed -i.bak 's/^    //' "$DETECTOR" && rm -f "$DETECTOR.bak"

# Wrap it in a function so we can call it multiple times in one shell.
WRAPPED="$TMPDIR_BASE/wrapped.sh"
{
    echo "$LOG_FN"
    echo 'run_detector() {'
    cat "$DETECTOR"
    echo '}'
} > "$WRAPPED"

# --- Test 3: 1 auth failure → counter=1, no ALERT ---
: > "$AMBIENT"
echo "Some random output. API Error: 401 {auth failed}" > "$cycle_log"
(
    set -e
    AGENT_ID=1
    REPO_ROOT="$REPO_ROOT"
    FLEET_LOG_DIR="$FLEET_LOG_DIR"
    cycle_log="$cycle_log"
    CHUMP_AMBIENT_LOG="$AMBIENT"
    CHUMP_AUTH_STORM_PAUSE=3
    CHUMP_AUTH_STORM_EXIT=5
    CHUMP_AUTH_STORM_PAUSE_SECS=0
    CHUMP_SESSION_ID=test-session
    # shellcheck disable=SC1090
    source "$WRAPPED"
    run_detector
) >/dev/null 2>&1

COUNTER=$(cat "$FLEET_LOG_DIR/agent-1.auth-fails" 2>/dev/null || echo "missing")
if [[ "$COUNTER" == "1" ]]; then
    ok "1st auth failure → counter=1"
else
    fail "expected counter=1, got '$COUNTER'"
fi
if [[ ! -s "$AMBIENT" ]]; then
    ok "no ALERT emitted at counter=1 (below threshold)"
else
    fail "ALERT emitted prematurely (ambient: $(cat "$AMBIENT"))"
fi

# --- Test 4: 3rd auth failure → ALERT pause, counter=3 ---
: > "$AMBIENT"
# Two more failure cycles (counter starts at 1 from above)
for i in 2 3; do
    echo "more output. Invalid authentication credentials" > "$cycle_log"
    (
        AGENT_ID=1
        REPO_ROOT="$REPO_ROOT"
        FLEET_LOG_DIR="$FLEET_LOG_DIR"
        cycle_log="$cycle_log"
        CHUMP_AMBIENT_LOG="$AMBIENT"
        CHUMP_AUTH_STORM_PAUSE=3
        CHUMP_AUTH_STORM_EXIT=5
        CHUMP_AUTH_STORM_PAUSE_SECS=0   # don't actually sleep in tests
        CHUMP_SESSION_ID=test-session
        # shellcheck disable=SC1090
        source "$WRAPPED"
        run_detector
    ) >/dev/null 2>&1
done

COUNTER=$(cat "$FLEET_LOG_DIR/agent-1.auth-fails" 2>/dev/null || echo "missing")
if [[ "$COUNTER" == "3" ]]; then
    ok "3 consecutive failures → counter=3"
else
    fail "expected counter=3, got '$COUNTER'"
fi
if grep -q '"kind":"fleet_auth_storm"' "$AMBIENT" \
   && grep -q '"action":"worker_pause"' "$AMBIENT" \
   && grep -q '"consecutive_failures":3' "$AMBIENT"; then
    ok "ALERT kind=fleet_auth_storm action=worker_pause emitted at threshold"
else
    fail "expected pause-ALERT not in ambient: $(cat "$AMBIENT")"
fi

# --- Test 5: clean cycle resets counter ---
: > "$AMBIENT"
echo "All clean. PR #1234 created." > "$cycle_log"
(
    AGENT_ID=1
    REPO_ROOT="$REPO_ROOT"
    FLEET_LOG_DIR="$FLEET_LOG_DIR"
    cycle_log="$cycle_log"
    CHUMP_AMBIENT_LOG="$AMBIENT"
    CHUMP_AUTH_STORM_PAUSE=3
    CHUMP_AUTH_STORM_EXIT=5
    CHUMP_AUTH_STORM_PAUSE_SECS=0
    CHUMP_SESSION_ID=test-session
    # shellcheck disable=SC1090
    source "$WRAPPED"
    run_detector
) >/dev/null 2>&1

if [[ ! -f "$FLEET_LOG_DIR/agent-1.auth-fails" ]]; then
    ok "clean cycle resets the counter (file removed)"
else
    fail "counter file still exists after clean cycle: $(cat "$FLEET_LOG_DIR/agent-1.auth-fails")"
fi

# --- Test 6: 5th consecutive failure → exit threshold ---
# Reset and simulate 5 consecutive failures, capturing exit
: > "$AMBIENT"
rm -f "$FLEET_LOG_DIR/agent-1.auth-fails"
echo "auth failure: API Error: 401" > "$cycle_log"

EXIT_RC=0
set +e
for i in 1 2 3 4 5; do
    (
        AGENT_ID=1
        REPO_ROOT="$REPO_ROOT"
        FLEET_LOG_DIR="$FLEET_LOG_DIR"
        cycle_log="$cycle_log"
        CHUMP_AMBIENT_LOG="$AMBIENT"
        CHUMP_AUTH_STORM_PAUSE=3
        CHUMP_AUTH_STORM_EXIT=5
        CHUMP_AUTH_STORM_PAUSE_SECS=0
        CHUMP_SESSION_ID=test-session
        # shellcheck disable=SC1090
        source "$WRAPPED"
        run_detector
    ) >/dev/null 2>&1
    EXIT_RC=$?
    [[ $EXIT_RC -ne 0 ]] && break
done
set -e

if [[ $EXIT_RC -eq 3 ]] && grep -qE '"action":"worker_exit"' "$AMBIENT"; then
    ok "5 consecutive failures → exit rc=3 + ALERT action=worker_exit"
else
    fail "expected exit rc=3 with worker_exit ALERT; got rc=$EXIT_RC, ambient: $(grep -c worker_exit "$AMBIENT" 2>/dev/null || echo 0) match(es)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
