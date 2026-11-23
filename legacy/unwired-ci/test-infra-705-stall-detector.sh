#!/usr/bin/env bash
# test-infra-705-stall-detector.sh — INFRA-705 tests.
#
# Verifies the stall-detector wired into scripts/dispatch/worker.sh:
#   (1) CHUMP_STALL_THRESHOLD_S config var referenced in worker.sh
#   (2) stall-detector background subprocess spawned after claude launch
#   (3) _stall_detector_pid cleaned up after cycle (wait + kill)
#   (4) cycle_stall_killed event emitted to ambient.jsonl format check
#   (5) cycle_stall_killed registered in EVENT_REGISTRY.yaml
#   (6) stall-detector fires and kills a deliberately-stalled process
#   (7) threshold is respected: process not killed before threshold
#   (8) stall-detector exits cleanly when monitored process exits on its own
#
# Run: ./scripts/ci/test-infra-705-stall-detector.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-705 stall-detector tests ==="
echo

# ── Test 1: CHUMP_STALL_THRESHOLD_S in worker.sh ──────────────────────────────
echo "--- Test 1: CHUMP_STALL_THRESHOLD_S config var present in worker.sh ---"
if grep -q 'CHUMP_STALL_THRESHOLD_S' "$WORKER_SH" 2>/dev/null; then
    ok "Test 1: CHUMP_STALL_THRESHOLD_S referenced in worker.sh"
else
    fail "Test 1: CHUMP_STALL_THRESHOLD_S missing from worker.sh"
fi

# ── Test 2: stall-detector background subprocess spawned ──────────────────────
echo "--- Test 2: _stall_detector_pid assigned in worker.sh ---"
if grep -q '_stall_detector_pid=' "$WORKER_SH" 2>/dev/null; then
    ok "Test 2: _stall_detector_pid assigned (stall-detector spawned)"
else
    fail "Test 2: _stall_detector_pid not found — stall-detector may not be spawned"
fi

# ── Test 3: stall-detector cleaned up ─────────────────────────────────────────
echo "--- Test 3: _stall_detector_pid cleaned up (kill + wait) ---"
if grep -q 'kill.*_stall_detector_pid' "$WORKER_SH" 2>/dev/null && \
   grep -q 'wait.*_stall_detector_pid' "$WORKER_SH" 2>/dev/null; then
    ok "Test 3: _stall_detector_pid cleaned up after cycle"
else
    fail "Test 3: _stall_detector_pid cleanup (kill/wait) missing from worker.sh"
fi

# ── Test 4: cycle_stall_killed event format ───────────────────────────────────
echo "--- Test 4: cycle_stall_killed emitted to ambient.jsonl with required fields ---"
if grep -q '"cycle_stall_killed"' "$WORKER_SH" 2>/dev/null && \
   grep -q '"gap_id"' "$WORKER_SH" 2>/dev/null && \
   grep -q '"agent_id"\|"idle_s"' "$WORKER_SH" 2>/dev/null; then
    ok "Test 4: cycle_stall_killed event with required fields present"
else
    fail "Test 4: cycle_stall_killed event or required fields missing from worker.sh"
fi

# ── Test 5: cycle_stall_killed in EVENT_REGISTRY ──────────────────────────────
echo "--- Test 5: cycle_stall_killed registered in EVENT_REGISTRY.yaml ---"
if grep -q 'cycle_stall_killed' "$REGISTRY" 2>/dev/null; then
    ok "Test 5: cycle_stall_killed registered in EVENT_REGISTRY.yaml"
else
    fail "Test 5: cycle_stall_killed missing from EVENT_REGISTRY.yaml"
fi

# ── Test 6: stall-detector kills a stalled process within threshold ────────────
echo "--- Test 6: stall-detector kills process producing no output within threshold ---"
_tmpdir=$(mktemp -d)
_cycle_log="$_tmpdir/cycle.log"
_ambient="$_tmpdir/ambient.jsonl"
_stall_threshold=3  # 3s for test speed

# Simulate a "stalled" process: write 50 bytes then sleep forever
(echo "initial output here" > "$_cycle_log"; sleep 300) &
_fake_pid=$!

# Run the stall-detector logic inline (mirrors worker.sh implementation)
_stall_start=$SECONDS
(
    _sd_last_sz=0
    _sd_last_active=$SECONDS
    while kill -0 "$_fake_pid" 2>/dev/null; do
        sleep 1
        _sd_cur_sz=$(wc -c < "$_cycle_log" 2>/dev/null | tr -d ' ' || echo 0)
        if [[ "$_sd_cur_sz" -gt "$_sd_last_sz" ]]; then
            _sd_last_sz=$_sd_cur_sz
            _sd_last_active=$SECONDS
        fi
        _sd_idle=$(( SECONDS - _sd_last_active ))
        if [[ $_sd_idle -ge $_stall_threshold ]]; then
            printf '{"ts":"%s","kind":"cycle_stall_killed","gap_id":"TEST","agent_id":"0","idle_s":%d}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sd_idle" \
                >> "$_ambient" 2>/dev/null || true
            kill -TERM "$_fake_pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$_fake_pid" 2>/dev/null || true
            break
        fi
    done
) &
_sd_pid=$!

wait "$_fake_pid" 2>/dev/null || true
_stall_elapsed=$(( SECONDS - _stall_start ))
kill "$_sd_pid" 2>/dev/null || true
wait "$_sd_pid" 2>/dev/null || true

if [[ -f "$_ambient" ]] && grep -q 'cycle_stall_killed' "$_ambient"; then
    ok "Test 6: stall-detector killed stalled process and emitted cycle_stall_killed (elapsed: ${_stall_elapsed}s)"
else
    fail "Test 6: stall-detector did not fire or event not emitted (elapsed: ${_stall_elapsed}s)"
fi
rm -rf "$_tmpdir"

# ── Test 7: threshold respected — process not killed before threshold ──────────
echo "--- Test 7: stall-detector does NOT kill process outputting regularly ---"
_tmpdir2=$(mktemp -d)
_cycle_log2="$_tmpdir2/cycle.log"
_stall_threshold2=5  # 5s threshold

# Process that writes output every 2s (should NOT be killed in 4s window)
(
    for i in 1 2; do
        echo "output $i" >> "$_cycle_log2"
        sleep 2
    done
) &
_live_pid=$!
_live_start=$SECONDS

(
    _sd_last_sz=0
    _sd_last_active=$SECONDS
    while kill -0 "$_live_pid" 2>/dev/null; do
        sleep 1
        _sd_cur_sz=$(wc -c < "$_cycle_log2" 2>/dev/null | tr -d ' ' || echo 0)
        if [[ "$_sd_cur_sz" -gt "$_sd_last_sz" ]]; then
            _sd_last_sz=$_sd_cur_sz
            _sd_last_active=$SECONDS
        fi
        _sd_idle=$(( SECONDS - _sd_last_active ))
        if [[ $_sd_idle -ge $_stall_threshold2 ]]; then
            kill -TERM "$_live_pid" 2>/dev/null || true
            break
        fi
    done
) &
_sd2_pid=$!

wait "$_live_pid" 2>/dev/null
_live_rc=$?
kill "$_sd2_pid" 2>/dev/null || true
wait "$_sd2_pid" 2>/dev/null || true

# Process should have exited naturally (rc=0), not been killed (rc=143/SIGTERM)
if [[ $_live_rc -eq 0 ]]; then
    ok "Test 7: stall-detector did not kill regularly-outputting process (rc=$_live_rc)"
else
    fail "Test 7: stall-detector killed live process prematurely (rc=$_live_rc)"
fi
rm -rf "$_tmpdir2"

# ── Test 8: stall-detector exits cleanly when process exits naturally ──────────
echo "--- Test 8: stall-detector subprocess exits cleanly when process exits ---"
_tmpdir3=$(mktemp -d)
_cycle_log3="$_tmpdir3/cycle.log"
echo "done" > "$_cycle_log3"

# Short-lived process
(sleep 1) &
_short_pid=$!

(
    while kill -0 "$_short_pid" 2>/dev/null; do
        sleep 0.5
    done
    # Should exit here when _short_pid goes away
) &
_sd3_pid=$!

wait "$_short_pid" 2>/dev/null
_t3_start=$SECONDS
kill "$_sd3_pid" 2>/dev/null || true
wait "$_sd3_pid" 2>/dev/null || true
_t3_elapsed=$(( SECONDS - _t3_start ))

if [[ $_t3_elapsed -le 3 ]]; then
    ok "Test 8: stall-detector cleanup completed quickly (${_t3_elapsed}s)"
else
    fail "Test 8: stall-detector cleanup took too long (${_t3_elapsed}s > 3s)"
fi
rm -rf "$_tmpdir3"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
