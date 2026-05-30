#!/usr/bin/env bash
# scripts/ci/test-curator-sentinel-integration.sh — META-165
#
# Integration test for the curator-sentinel producer side.
#
# AC #14: exercises ci-audit-loop.sh tick in background, asserts sentinel
#         file created, kills loop, asserts sentinel removed via trap.
# AC #15: (recv-side v0 proof) when CHUMP_FLEET_RECV_SIDE_V0=1 is set,
#         broadcast FEEDBACK kind=proposal and assert
#         kind=feedback_fanout_delivered with recipient_count >= 1 in ambient.
#
# Usage:
#   bash scripts/ci/test-curator-sentinel-integration.sh
#   bash scripts/ci/test-curator-sentinel-integration.sh --ac14-only
#   bash scripts/ci/test-curator-sentinel-integration.sh --ac15-only
#
# Exit 0 on pass, 1 on failure.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
COORD="$REPO_ROOT/scripts/coord"
BROADCAST="$COORD/broadcast.sh"

# ── Test isolation: use a temp lock dir so we don't pollute the real fleet ──
TMPDIR_TEST="$(mktemp -d /tmp/chump-sentinel-test-XXXXXX)"
export CHUMP_LOCK_DIR="$TMPDIR_TEST"
export CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"
export CHUMP_SESSION_ID="curator-opus-test-e2e"

cleanup() {
    # Kill any background processes we started.
    [[ -n "${LOOP_PID:-}" ]] && kill "$LOOP_PID" 2>/dev/null || true
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

PASS=0
FAIL=0

_pass() { printf '[PASS] %s\n' "$*"; PASS=$(( PASS + 1 )); }
_fail() { printf '[FAIL] %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

AC14_ONLY=0
AC15_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --ac14-only) AC14_ONLY=1 ;;
        --ac15-only) AC15_ONLY=1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# AC #14: sentinel lifecycle — create on start, remove on exit
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$AC15_ONLY" == "0" ]]; then
    echo "=== AC#14: sentinel lifecycle ==="

    SENTINEL="$TMPDIR_TEST/.curator-opus-ci-audit.lock"

    # Run ci-audit-loop.sh tick in background (one tick, then exits).
    # We wrap in a subshell so the EXIT trap inside the loop fires on kill.
    CHUMP_SESSION_ID="curator-opus-ci-audit-test" \
    CHUMP_LOCK_DIR="$TMPDIR_TEST" \
    CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl" \
        bash "$COORD/ci-audit-loop.sh" tick >/dev/null 2>&1 &
    LOOP_PID=$!

    # Give the loop up to 3 seconds to create the sentinel.
    sentinel_created=0
    for _ in 1 2 3 4 5 6; do
        if [[ -e "$SENTINEL" ]]; then
            sentinel_created=1
            break
        fi
        sleep 0.5
    done

    if [[ "$sentinel_created" == "1" ]]; then
        _pass "sentinel created at $SENTINEL"
        pid_in_file="$(cat "$SENTINEL" 2>/dev/null || true)"
        if [[ -n "$pid_in_file" && "$pid_in_file" =~ ^[0-9]+$ ]]; then
            _pass "sentinel contains numeric PID ($pid_in_file)"
        else
            _fail "sentinel file exists but PID content invalid: '$pid_in_file'"
        fi
    else
        _fail "sentinel NOT created within 3s at $SENTINEL"
    fi

    # Wait for the loop to finish (tick is one-shot), then check removal.
    wait "$LOOP_PID" 2>/dev/null || true
    LOOP_PID=""

    # Give EXIT trap up to 2s to fire.
    sentinel_removed=0
    for _ in 1 2 3 4; do
        if [[ ! -e "$SENTINEL" ]]; then
            sentinel_removed=1
            break
        fi
        sleep 0.5
    done

    if [[ "$sentinel_removed" == "1" ]]; then
        _pass "sentinel removed after loop exit (EXIT trap fired)"
    else
        _fail "sentinel NOT removed after loop exit — trap may not have fired"
    fi

    # Check ambient events were emitted.
    if grep -q '"kind":"curator_sentinel_created"' "$TMPDIR_TEST/ambient.jsonl" 2>/dev/null; then
        _pass "curator_sentinel_created event in ambient.jsonl"
    else
        _fail "curator_sentinel_created NOT found in ambient.jsonl"
    fi

    if grep -q '"kind":"curator_sentinel_removed"' "$TMPDIR_TEST/ambient.jsonl" 2>/dev/null; then
        _pass "curator_sentinel_removed event in ambient.jsonl"
    else
        _fail "curator_sentinel_removed NOT found in ambient.jsonl (may be timing; check manually)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# AC #15: recv-side v0 end-to-end proof
# Requires CHUMP_FLEET_RECV_SIDE_V0=1 and broadcast.sh to exist.
# Skipped automatically if CHUMP_FLEET_RECV_SIDE_V0 is not set.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$AC14_ONLY" == "0" ]]; then
    echo "=== AC#15: recv-side v0 end-to-end ==="

    if [[ "${CHUMP_FLEET_RECV_SIDE_V0:-0}" != "1" ]]; then
        echo "[SKIP] AC#15: CHUMP_FLEET_RECV_SIDE_V0 not set — skipping recv-side proof"
        echo "  Set CHUMP_FLEET_RECV_SIDE_V0=1 to run the full end-to-end test."
    elif [[ ! -x "$BROADCAST" ]]; then
        echo "[SKIP] AC#15: broadcast.sh not found/executable at $BROADCAST"
    else
        # Use the real lock dir so broadcast.sh sees the fleet's sentinels.
        # Temporarily restore real lock dir for the broadcast step.
        REAL_LOCK_DIR="${CHUMP_LOCK_DIR_REAL:-$REPO_ROOT/.chump-locks}"
        REAL_AMBIENT="${CHUMP_AMBIENT_LOG_REAL:-$REAL_LOCK_DIR/ambient.jsonl}"

        BEFORE_COUNT=0
        if [[ -f "$REAL_AMBIENT" ]]; then
            BEFORE_COUNT=$(grep -c '"kind":"feedback_fanout_delivered"' "$REAL_AMBIENT" 2>/dev/null || true)
        fi

        # Broadcast a FEEDBACK proposal into the real fleet.
        CHUMP_LOCK_DIR="$REAL_LOCK_DIR" \
        CHUMP_AMBIENT_LOG="$REAL_AMBIENT" \
        CHUMP_SESSION_ID="curator-opus-test-e2e" \
        CHUMP_FLEET_RECV_SIDE_V0=1 \
            "$BROADCAST" FEEDBACK proposal \
                "META-165-e2e-test" \
                "end-to-end recv-side v0 proof from test-curator-sentinel-integration.sh" \
                0 >/dev/null 2>&1 || true

        # Wait up to 10s for feedback_fanout_delivered to appear.
        fanout_found=0
        recipient_count=0
        for _ in $(seq 1 20); do
            if [[ -f "$REAL_AMBIENT" ]]; then
                AFTER_COUNT=$(grep -c '"kind":"feedback_fanout_delivered"' "$REAL_AMBIENT" 2>/dev/null || true)
                if (( AFTER_COUNT > BEFORE_COUNT )); then
                    # Extract recipient_count from the newest fanout event.
                    recipient_count=$(grep '"kind":"feedback_fanout_delivered"' "$REAL_AMBIENT" \
                        | tail -1 \
                        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('recipient_count',0))" \
                        2>/dev/null || echo 0)
                    fanout_found=1
                    break
                fi
            fi
            sleep 0.5
        done

        if [[ "$fanout_found" == "1" ]]; then
            if (( recipient_count >= 1 )); then
                _pass "feedback_fanout_delivered with recipient_count=${recipient_count} >= 1"
            else
                _fail "feedback_fanout_delivered found but recipient_count=${recipient_count} (need >= 1 — are curators running?)"
            fi
        else
            _fail "feedback_fanout_delivered NOT found within 10s — broadcast.sh may not fan out, or no sentinels exist"
            echo "  Check: ls .chump-locks/.curator-opus-*.lock" >&2
            echo "  Check: grep feedback_fanout .chump-locks/ambient.jsonl | tail -5" >&2
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" == "0" ]]
