#!/usr/bin/env bash
# test-tmux-kill-cleanup.sh — INFRA-602: verify that raw `tmux kill-session`
# cascade-kills orphaned timeout+claude workers via the orphan-reaper sentinel.
#
# ACs:
#   (a) run-fleet.sh registers the sentinel watcher pattern (static check).
#   (b) Processes matching "timeout [0-9]*s claude -p " are killed within 5s
#       of tmux kill-session, via the sentinel mechanism.
#   (c) The sentinel exits cleanly after the session disappears.
#
# Requires tmux; skipped when not available.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not available — cannot run INFRA-602 tmux-kill-cleanup test"
    exit 0
fi

TEST_SESSION="chump-test-infra602-$$"
GRACE_SECS=5

cleanup() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    pkill -f "timeout [0-9]*s claude -p __infra602_stub__" 2>/dev/null || true
    [[ -n "${SENTINEL_PID:-}" ]] && kill "$SENTINEL_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== INFRA-602: tmux kill-session orphan-reaper sentinel test ==="

# ── Spawn stub processes mimicking fleet workers ──────────────────────────────
# exec -a renames the process so pkill -f "timeout [0-9]*s claude -p " matches.
STUB_PIDS=()
for i in 1 2 3; do
    bash -c "exec -a 'timeout 600s claude -p __infra602_stub__' sleep 3600" &
    STUB_PIDS+=($!)
done

echo "  spawned ${#STUB_PIDS[@]} stub processes: ${STUB_PIDS[*]}"

all_alive=1
for pid in "${STUB_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "  FAIL: stub PID $pid died before test started"
        all_alive=0
    fi
done
[[ "$all_alive" -eq 0 ]] && { echo "FAIL: stubs not all alive"; exit 1; }
echo "  pre-condition OK: all stubs alive"

# ── Create a minimal tmux session ────────────────────────────────────────────
tmux new-session -d -s "$TEST_SESSION" "sleep 3600"
echo "  created tmux session: $TEST_SESSION"

# ── Start the INFRA-602 sentinel watcher (same logic as run-fleet.sh) ─────────
(
    while tmux has-session -t "$TEST_SESSION" 2>/dev/null; do
        sleep 1
    done
    pkill -f "timeout [0-9]*s claude -p " 2>/dev/null || true
) &
SENTINEL_PID=$!
echo "  sentinel watcher started: PID $SENTINEL_PID"

# ── Simulate operator running: tmux kill-session ──────────────────────────────
echo "  running: tmux kill-session -t $TEST_SESSION"
tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true

# ── Wait up to GRACE_SECS for sentinel to fire ───────────────────────────────
echo "  waiting up to ${GRACE_SECS}s for sentinel to reap stubs..."
deadline=$(( $(date +%s) + GRACE_SECS ))
while (( $(date +%s) < deadline )); do
    any_alive=0
    for pid in "${STUB_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && any_alive=1 && break
    done
    [[ "$any_alive" -eq 0 ]] && break
    sleep 0.5
done

# ── Test (b): no stubs survive ────────────────────────────────────────────────
echo "=== Test (b): no stub processes survive tmux kill-session ==="
fail=0
for pid in "${STUB_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
        echo "  FAIL: stub PID $pid still alive after ${GRACE_SECS}s grace"
        fail=1
    fi
done
if [[ "$fail" -eq 0 ]]; then
    echo "  PASS: all ${#STUB_PIDS[@]} stubs killed by sentinel within ${GRACE_SECS}s"
else
    echo "  FAIL: orphans survived — sentinel did not fire in time"
    exit 1
fi

# ── Test (c): sentinel exits after session disappears ────────────────────────
echo "=== Test (c): sentinel exits after session disappears ==="
sentinel_deadline=$(( $(date +%s) + 5 ))
while (( $(date +%s) < sentinel_deadline )); do
    kill -0 "$SENTINEL_PID" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "  FAIL: sentinel PID $SENTINEL_PID still running after 5s"
    exit 1
fi
echo "  PASS: sentinel exited cleanly"

# ── Test (a): run-fleet.sh registers the sentinel (static check) ─────────────
echo "=== Test (a): run-fleet.sh contains INFRA-602 sentinel watcher ==="
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"
if grep -q 'tmux has-session.*FLEET_SESSION' "$RUN_FLEET" 2>/dev/null \
   && grep -q "timeout \[0-9\]\*s claude -p" "$RUN_FLEET" 2>/dev/null; then
    echo "  PASS: sentinel watcher found in $RUN_FLEET"
else
    echo "  FAIL: INFRA-602 sentinel not found in $RUN_FLEET"
    exit 1
fi

echo ""
echo "All INFRA-602 tmux-kill-cleanup tests passed."
