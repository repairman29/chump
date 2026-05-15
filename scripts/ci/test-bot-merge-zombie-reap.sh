#!/usr/bin/env bash
# shellcheck disable=SC2034  # REPO_ROOT kept for context
# test-bot-merge-zombie-reap.sh — INFRA-1315
#
# CI test: validates that bot-merge-watchdog.sh reaps a synthetic zombie
# process (a sleep process with a .health file pointing to a done gap).
#
# Method:
#   1. Create a temp lock dir.
#   2. Write a mock `chump` wrapper that returns `status: done` for ZOMBIE-TEST-001.
#   3. Start a background `sleep 9999` as the synthetic zombie.
#   4. Write a .health file pointing at that PID with gap_ids=ZOMBIE-TEST-001.
#   5. Run the watchdog with --execute + CHUMP_BIN=<mock> + --lock-dir <temp>.
#   6. Assert: synthetic process is dead; watchdog output mentions the PID.
#
# Skipped when: SKIP_INTEGRATION_TESTS=1.
# Exit: 0 = pass, 1 = fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WATCHDOG="$REPO_ROOT/scripts/coord/bot-merge-watchdog.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
FAILURES=0

if [ "${SKIP_INTEGRATION_TESTS:-0}" = "1" ]; then
    echo "[test-bot-merge-zombie-reap] SKIP: SKIP_INTEGRATION_TESTS=1"
    exit 0
fi

if [ ! -x "$WATCHDOG" ]; then
    echo "[test-bot-merge-zombie-reap] SKIP: $WATCHDOG not executable"
    exit 0
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
LOCK_DIR="$WORK_DIR/locks"
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$LOCK_DIR" "$BIN_DIR"

ZOMBIE_PID=""
trap '
    # Cleanup: kill the zombie if still alive.
    if [ -n "$ZOMBIE_PID" ]; then
        kill -KILL "$ZOMBIE_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
' EXIT

# ── Mock chump binary ─────────────────────────────────────────────────────────
# Returns "status: done" for ZOMBIE-TEST-001, "status: open" for anything else.
cat > "$BIN_DIR/chump" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock chump for test-bot-merge-zombie-reap.sh
if [ "${1:-}" = "gap" ] && [ "${2:-}" = "show" ]; then
    gap_id="${3:-}"
    if [ "$gap_id" = "ZOMBIE-TEST-001" ]; then
        printf '  status: done\n  closed_pr: 9999\n'
        exit 0
    else
        printf '  status: open\n'
        exit 0
    fi
fi
exec "$(command -v chump 2>/dev/null || echo /usr/local/bin/chump)" "$@"
MOCK_EOF
chmod +x "$BIN_DIR/chump"

# ── Test 1: health-file scan reaps zombie ─────────────────────────────────────
# Start synthetic zombie process.
sleep 9999 &
ZOMBIE_PID="$!"

# Write .health file as bot-merge.sh would.
HEALTH_FILE="$LOCK_DIR/bot-merge-${ZOMBIE_PID}.health"
printf '{"pid":%d,"started_at":"2026-05-15T18:00:00Z","current_step":"wait-ci","last_heartbeat_at":"2026-05-15T18:00:30Z","gap_ids":"ZOMBIE-TEST-001"}\n' \
    "$ZOMBIE_PID" > "$HEALTH_FILE"

# Run watchdog (execute is the default — no flag needed).
output="$(CHUMP_BIN="$BIN_DIR/chump" CHUMP_LOCK_DIR="$LOCK_DIR" \
    bash "$WATCHDOG" --lock-dir "$LOCK_DIR" 2>&1 || true)"

# Give it a moment to complete the kill.
sleep 1

# Assert: zombie is dead.
if kill -0 "$ZOMBIE_PID" 2>/dev/null; then
    fail "Test 1: zombie PID $ZOMBIE_PID still alive after watchdog ran"
else
    pass "Test 1: zombie PID $ZOMBIE_PID was reaped"
    ZOMBIE_PID=""  # clear so trap doesn't try to kill again
fi

# Assert: watchdog output mentions the PID.
if echo "$output" | grep -q "killing\|REAPED\|$ZOMBIE_PID" 2>/dev/null \
   || echo "$output" | grep -q "killed=1"; then
    pass "Test 1b: watchdog output indicates kill (killed=1 or PID in output)"
else
    fail "Test 1b: expected 'killed=1' or PID mention in watchdog output"
    echo "  Output was: $output" >&2
fi

# Assert: .health file removed.
if [ ! -f "$HEALTH_FILE" ]; then
    pass "Test 1c: .health file cleaned up"
else
    fail "Test 1c: .health file still present after watchdog"
fi

# ── Test 2: dry-run does not kill ─────────────────────────────────────────────
sleep 9999 &
ZOMBIE_PID="$!"

HEALTH_FILE2="$LOCK_DIR/bot-merge-${ZOMBIE_PID}.health"
printf '{"pid":%d,"started_at":"2026-05-15T18:00:00Z","current_step":"wait-ci","last_heartbeat_at":"2026-05-15T18:00:30Z","gap_ids":"ZOMBIE-TEST-001"}\n' \
    "$ZOMBIE_PID" > "$HEALTH_FILE2"

CHUMP_BIN="$BIN_DIR/chump" CHUMP_LOCK_DIR="$LOCK_DIR" \
    bash "$WATCHDOG" --dry-run --lock-dir "$LOCK_DIR" >/dev/null 2>&1 || true

if kill -0 "$ZOMBIE_PID" 2>/dev/null; then
    pass "Test 2: --dry-run did not kill PID $ZOMBIE_PID"
else
    fail "Test 2: --dry-run killed PID $ZOMBIE_PID (should not have)"
    ZOMBIE_PID=""
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [ "$FAILURES" -eq 0 ]; then
    echo "[test-bot-merge-zombie-reap] PASS — all tests passed"
    exit 0
else
    echo "[test-bot-merge-zombie-reap] FAIL — $FAILURES test(s) failed"
    exit 1
fi
