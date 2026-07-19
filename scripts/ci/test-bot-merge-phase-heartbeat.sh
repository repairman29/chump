#!/usr/bin/env bash
# shellcheck disable=SC2034  # REPO_ROOT kept for context
# test-bot-merge-phase-heartbeat.sh — INFRA-1732
#
# bot-merge.sh's health file only ever carried last_heartbeat_at (rewritten
# every 30s regardless of whether the *phase* changed) plus total process
# age — so bot-merge-watchdog.sh could only tell a stalled run from a
# legitimately-slow one by comparing raw process age to MAX_AGE_S
# (elapsed-time-only; silent stall observed 2026-05-22). This test verifies:
#   1. bot-merge.sh's health file now carries step_started_at (when the
#      *current* phase began, from stage_start()).
#   2. bot-merge-watchdog.sh reads step_started_at and, when a phase has
#      run longer than CHUMP_BOT_MERGE_PHASE_STALL_S, emits
#      kind=bot_merge_phase_stalled to ambient.jsonl — a programmatic
#      phase-progress signal, distinct from the process-age-only warn.
#   3. A healthy (recently-started) phase does NOT trip the stall emit.
#   4. kind=bot_merge_phase_stalled is registered in EVENT_REGISTRY.yaml.
#
# Skipped when: SKIP_INTEGRATION_TESTS=1.
# Exit: 0 = pass, 1 = fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
WATCHDOG="$REPO_ROOT/scripts/coord/bot-merge-watchdog.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
FAILURES=0

if [ "${SKIP_INTEGRATION_TESTS:-0}" = "1" ]; then
    echo "[test-bot-merge-phase-heartbeat] SKIP: SKIP_INTEGRATION_TESTS=1"
    exit 0
fi

# ── Static checks ─────────────────────────────────────────────────────────────
bash -n "$BOT_MERGE" && pass "bot-merge.sh parses (bash -n)" || fail "bot-merge.sh SYNTAX ERROR"
bash -n "$WATCHDOG"  && pass "bot-merge-watchdog.sh parses (bash -n)" || fail "bot-merge-watchdog.sh SYNTAX ERROR"

grep -q 'step_started_at' "$BOT_MERGE" 2>/dev/null \
    && pass "bot-merge.sh health writer emits step_started_at" \
    || fail "step_started_at missing from bot-merge.sh health writer"

grep -q 'CHUMP_BOT_MERGE_PHASE_STALL_S' "$WATCHDOG" 2>/dev/null \
    && pass "phase-stall threshold tunable via CHUMP_BOT_MERGE_PHASE_STALL_S" \
    || fail "CHUMP_BOT_MERGE_PHASE_STALL_S not wired into watchdog"

grep -q 'kind: bot_merge_phase_stalled' "$REGISTRY" 2>/dev/null \
    && pass "bot_merge_phase_stalled registered in EVENT_REGISTRY.yaml" \
    || fail "bot_merge_phase_stalled NOT registered in EVENT_REGISTRY.yaml"

if [ ! -x "$WATCHDOG" ]; then
    echo "[test-bot-merge-phase-heartbeat] SKIP functional checks: $WATCHDOG not executable"
    echo "=== $FAILURES failed ==="
    [ "$FAILURES" -eq 0 ] && exit 0 || exit 1
fi

# ── Functional: stale phase trips the emit ────────────────────────────────────
WORK_DIR="$(mktemp -d)"
LOCK_DIR="$WORK_DIR/locks"
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$LOCK_DIR" "$BIN_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$BIN_DIR/chump" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock chump for test-bot-merge-phase-heartbeat.sh — everything is "open".
if [ "${1:-}" = "gap" ] && [ "${2:-}" = "show" ]; then
    printf '  status: open\n'
    exit 0
fi
exec "$(command -v chump 2>/dev/null || echo /usr/local/bin/chump)" "$@"
MOCK_EOF
chmod +x "$BIN_DIR/chump"

# Self ($$) is a real, alive PID — stands in for the "bot-merge process".
STALE_PID="$$"
STALE_STARTED="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
HEALTH_FILE="$LOCK_DIR/bot-merge-${STALE_PID}.health"
printf '{"pid":%d,"started_at":"%s","current_step":"wait_ci","step_started_at":"%s","last_heartbeat_at":"%s","gap_ids":"PHASE-TEST-001"}\n' \
    "$STALE_PID" "$STALE_STARTED" "$STALE_STARTED" "$STALE_STARTED" > "$HEALTH_FILE"

AMBIENT="$LOCK_DIR/ambient.jsonl"
: > "$AMBIENT"
CHUMP_BIN="$BIN_DIR/chump" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_BOT_MERGE_PHASE_STALL_S=60 \
    bash "$WATCHDOG" --dry-run --lock-dir "$LOCK_DIR" >/dev/null 2>&1 || true

if grep -q '"kind":"bot_merge_phase_stalled"' "$AMBIENT" 2>/dev/null \
   && grep -q '"step":"wait_ci"' "$AMBIENT" 2>/dev/null; then
    pass "stale phase (30m in wait_ci, threshold 60s) emits bot_merge_phase_stalled"
else
    fail "stale phase did NOT emit bot_merge_phase_stalled"
    echo "  ambient.jsonl was: $(cat "$AMBIENT" 2>/dev/null)" >&2
fi

# ── Functional: fresh phase does NOT trip the emit ────────────────────────────
FRESH_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEALTH_FILE2="$LOCK_DIR/bot-merge-${STALE_PID}.health"
printf '{"pid":%d,"started_at":"%s","current_step":"push","step_started_at":"%s","last_heartbeat_at":"%s","gap_ids":"PHASE-TEST-001"}\n' \
    "$STALE_PID" "$FRESH_STARTED" "$FRESH_STARTED" "$FRESH_STARTED" > "$HEALTH_FILE2"

: > "$AMBIENT"
CHUMP_BIN="$BIN_DIR/chump" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_BOT_MERGE_PHASE_STALL_S=600 \
    bash "$WATCHDOG" --dry-run --lock-dir "$LOCK_DIR" >/dev/null 2>&1 || true

if grep -q '"kind":"bot_merge_phase_stalled"' "$AMBIENT" 2>/dev/null; then
    fail "fresh phase incorrectly emitted bot_merge_phase_stalled"
else
    pass "fresh phase (just started, threshold 600s) does not emit bot_merge_phase_stalled"
fi

echo "=== $FAILURES failed ==="
[ "$FAILURES" -eq 0 ] && exit 0 || exit 1
