#!/usr/bin/env bash
# test-fleet-state-mutex.sh — INFRA-847 smoke test
#
# Verifies:
#   1. reset creates valid JSON
#   2. read returns valid JSON
#   3. write stores a field correctly
#   4. set-field merges a key
#   5. Concurrent writes produce valid (non-torn) JSON
#   6. CHUMP_FLEET_STATE_MUTEX=0 bypass works
#   7. kind=fleet_state_lock_timeout emitted on lock timeout
#   8. opus-curator.sh --once --dry-run completes without error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAST_PATH="$REPO_ROOT/scripts/coord/emergency-fast-path.sh"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"

pass=0; fail=0
check_ok()   { echo "  [ok]  $1"; pass=$((pass+1)); }
check_fail() { echo "  [FAIL] $1" >&2; fail=$((fail+1)); }

TMPDIR_TEST="$(mktemp -d)"
AMB_LOG="$TMPDIR_TEST/ambient.jsonl"
# fleet-state.json lives in same dir as ambient.jsonl (dirname of CHUMP_AMBIENT_LOG)
STATE_FILE="$TMPDIR_TEST/fleet-state.json"
LOCK_FILE="$TMPDIR_TEST/fleet-state.lock"

trap 'rm -rf "$TMPDIR_TEST"' EXIT

export CHUMP_AMBIENT_LOG="$AMB_LOG"
export REPO_ROOT="$TMPDIR_TEST"
export CHUMP_FLEET_STATE_LOCK_TIMEOUT_S=5

mkdir -p "$TMPDIR_TEST"

echo "=== INFRA-847: fleet-state.json mutex smoke test ==="

# 1. reset creates valid JSON
"$FAST_PATH" reset >/dev/null
if [[ -f "$STATE_FILE" ]] && python3 -c "import json; json.load(open('$STATE_FILE'))" 2>/dev/null; then
    check_ok "reset creates valid JSON"
else
    check_fail "reset: state file missing or invalid JSON"
fi

# 2. read returns valid JSON
output="$("$FAST_PATH" read)"
if echo "$output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    check_ok "read returns valid JSON"
else
    check_fail "read: invalid JSON output"
fi

# 3. write stores a field correctly
"$FAST_PATH" write '{"ts":"2026-01-01T00:00:00Z","fleet_size":2,"health":"healthy","workers":[]}'
val="$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['fleet_size'])")"
if [[ "$val" == "2" ]]; then
    check_ok "write stores field correctly"
else
    check_fail "write: fleet_size wrong (got '$val')"
fi

# 4. set-field merges a key
"$FAST_PATH" set-field health testing
val="$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['health'])")"
if [[ "$val" == "testing" ]]; then
    check_ok "set-field merges key"
else
    check_fail "set-field: health wrong (got '$val')"
fi

# 5. Concurrent writes don't corrupt JSON (10 parallel writers)
"$FAST_PATH" reset >/dev/null
for i in $(seq 1 10); do
    "$FAST_PATH" write "{\"ts\":\"2026-01-01T00:00:00Z\",\"fleet_size\":$i,\"health\":\"ok\",\"workers\":[]}" &
done
wait
if python3 -c "import json; json.load(open('$STATE_FILE'))" 2>/dev/null; then
    check_ok "concurrent writes produce valid JSON"
else
    check_fail "concurrent writes: torn JSON"
fi

# 6. CHUMP_FLEET_STATE_MUTEX=0 bypass works
if CHUMP_FLEET_STATE_MUTEX=0 "$FAST_PATH" read > /dev/null; then
    check_ok "mutex=0 bypass works"
else
    check_fail "mutex=0 bypass failed"
fi

# 7. kind=fleet_state_lock_timeout emitted when lock is held past timeout
# Hold the lock externally for 3s while fast-path tries with 1s timeout
# INFRA-1600 follow-up: self-discover flock (brew util-linux is keg-only).
_FLOCK_BIN=""
if command -v flock >/dev/null 2>&1; then
    _FLOCK_BIN="flock"
elif [[ -x /opt/homebrew/opt/util-linux/bin/flock ]]; then
    _FLOCK_BIN="/opt/homebrew/opt/util-linux/bin/flock"
elif [[ -x /usr/local/opt/util-linux/bin/flock ]]; then
    _FLOCK_BIN="/usr/local/opt/util-linux/bin/flock"
else
    echo "[test-fleet-state-mutex] ERROR: flock not found" >&2
    exit 1
fi
(
    "$_FLOCK_BIN" -x 9
    sleep 3
) 9>"$LOCK_FILE" &
HOLDER_PID=$!
CHUMP_FLEET_STATE_LOCK_TIMEOUT_S=1 "$FAST_PATH" read > /dev/null 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
if grep -q '"kind":"fleet_state_lock_timeout"' "$AMB_LOG" 2>/dev/null; then
    check_ok "fleet_state_lock_timeout event emitted on timeout"
else
    check_fail "fleet_state_lock_timeout event NOT found in ambient.jsonl"
fi

# 8. opus-curator --once --dry-run completes without error
# Run with REPO_ROOT pointing at the actual worktree (curator needs git);
# keep CHUMP_AMBIENT_LOG pointing at isolated temp ambient.jsonl.
if CHUMP_CURATOR_DRY_RUN=1 REPO_ROOT="$SCRIPT_DIR/../.." "$CURATOR" --once --dry-run 2>/dev/null; then
    check_ok "opus-curator --once --dry-run succeeds"
else
    check_fail "opus-curator --once --dry-run failed"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]] && exit 0 || exit 1
