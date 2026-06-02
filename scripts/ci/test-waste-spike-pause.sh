#!/usr/bin/env bash
# test-waste-spike-pause.sh — FLEET-054
#
# Verifies that waste-spike-detector.sh auto-pauses the fleet when the waste
# rate exceeds CHUMP_WASTE_SPIKE_THRESHOLD and recovers when it falls below
# CHUMP_WASTE_RECOVERY_THRESHOLD for two consecutive checks.
#
#   1. rate > 30% → .chump/fleet-paused created
#   2. rate > 30% → kind=waste_spike_detected emitted to ambient.jsonl
#   3. rate > 30% again after pause → fleet-paused not removed
#   4. rate < 20% once → fleet still paused (need 2 consecutive)
#   5. rate < 20% twice → fleet-paused removed
#   6. rate < 20% twice → kind=fleet_resumed emitted
#   7. re-spike after recovery → fleet-paused re-created
#   8. detector always runs (CHUMP_IGNORE_WASTE_PAUSE deleted by INFRA-2424)
#      8b. waste-spike-detector.sh does not reference CHUMP_IGNORE_WASTE_PAUSE
#   9. worker.sh references fleet-paused sentinel (structural check)
#      9b. worker.sh references fleet-paused sentinel
#      9c. worker.sh does not reference CHUMP_IGNORE_WASTE_PAUSE (INFRA-2424)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# NOTE: intentionally no git-common-dir hop here. waste-spike-detector.sh and
# worker.sh are NEW files introduced by this PR; they only exist in this
# worktree before merge. After merge CI runs from the main repo directly, so
# REPO_ROOT (two dirs up from this script) is already correct in both cases.

DETECTOR="$REPO_ROOT/scripts/coord/waste-spike-detector.sh"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$DETECTOR" ]] || fail "waste-spike-detector.sh missing or not executable: $DETECTOR"
[[ -f "$WORKER" ]]   || fail "worker.sh missing: $WORKER"

TMP="$(mktemp -d -t fleet054-test-XXXX)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"
touch "$AMBIENT"
PAUSE_FILE="$TMP/fleet-paused"
CONSEC_FILE="$TMP/chump-waste-recovery-count"

# ── Stub chump binary ─────────────────────────────────────────────────────
# Write the stub ONCE and never overwrite it — macOS syspolicyd re-assesses
# executables after they are overwritten, which can race and kill the process
# with SIGKILL. By writing once and controlling output via a data file, we
# avoid re-assessment across tests.
#
# The stub reads its "waste-tally --json" output from $CHUMP_TEST_TALLY_FILE.
# All other chump subcommands are no-ops.
BIN="$TMP/bin"
mkdir -p "$BIN"
TALLY_FILE="$TMP/tally-output"
printf '{"total_events":0,"total_incidents":0}\n' > "$TALLY_FILE"

cat > "$BIN/chump" << 'STUB_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "waste-tally" ]]; then
    if [[ -n "${CHUMP_TEST_TALLY_FILE:-}" && -f "$CHUMP_TEST_TALLY_FILE" ]]; then
        cat "$CHUMP_TEST_TALLY_FILE"
    else
        echo '{}'
    fi
    exit 0
fi
exit 0
STUB_EOF
chmod +x "$BIN/chump"

# set_tally <events> <incidents> — updates the stub's tally output
set_tally() {
    printf '{"total_events":%d,"total_incidents":%d}\n' "$1" "$2" > "$TALLY_FILE"
}

# Common env passed to every detector invocation.
COMMON_ENV=(
    CHUMP_AMBIENT_LOG="$AMBIENT"
    CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE"
    CHUMP_WASTE_CONSEC_FILE="$CONSEC_FILE"
    CHUMP_TEST_TALLY_FILE="$TALLY_FILE"
    PATH="$BIN:$PATH"
)

# ── Test 1: rate > 30% → fleet-paused created ─────────────────────────────
set_tally 100 35   # 35% waste rate

env "${COMMON_ENV[@]}" bash "$DETECTOR" 2>/dev/null || true

if [[ -f "$PAUSE_FILE" ]]; then
    ok "Test 1: waste rate 35% > 30% threshold → fleet-paused created"
else
    fail "Test 1: fleet-paused not created despite 35% waste rate"
fi

# ── Test 2: waste_spike_detected emitted ──────────────────────────────────
if grep -q '"kind":"waste_spike_detected"' "$AMBIENT" 2>/dev/null; then
    ok "Test 2: kind=waste_spike_detected emitted to ambient.jsonl"
else
    fail "Test 2: waste_spike_detected event not found in ambient.jsonl"
fi

# ── Test 3: rate still > 30% → fleet-paused not removed ──────────────────
set_tally 100 40   # 40% waste rate

env "${COMMON_ENV[@]}" bash "$DETECTOR" 2>/dev/null || true

if [[ -f "$PAUSE_FILE" ]]; then
    ok "Test 3: rate still 40% → fleet-paused remains"
else
    fail "Test 3: fleet-paused removed despite 40% waste rate"
fi

# ── Test 4: rate < 20% once → fleet still paused (need 2 consecutive) ────
set_tally 100 10   # 10% waste rate

env "${COMMON_ENV[@]}" bash "$DETECTOR" 2>/dev/null || true

if [[ -f "$PAUSE_FILE" ]]; then
    ok "Test 4: 10% rate (1st check) → fleet still paused (need 2 consecutive)"
else
    fail "Test 4: fleet-paused removed after only 1 consecutive below-threshold check"
fi

# ── Test 5: rate < 20% twice → fleet-paused removed ──────────────────────
# (set_tally stays at 10% — second consecutive)
env "${COMMON_ENV[@]}" bash "$DETECTOR" 2>/dev/null || true

if [[ ! -f "$PAUSE_FILE" ]]; then
    ok "Test 5: 10% rate (2nd consecutive check) → fleet-paused removed"
else
    fail "Test 5: fleet-paused not removed after 2 consecutive below-threshold checks"
fi

# ── Test 6: fleet_resumed emitted ─────────────────────────────────────────
if grep -q '"kind":"fleet_resumed"' "$AMBIENT" 2>/dev/null; then
    ok "Test 6: kind=fleet_resumed emitted after 2 consecutive recovery checks"
else
    fail "Test 6: fleet_resumed event not found in ambient.jsonl"
fi

# ── Test 7: re-spike after recovery → fleet-paused re-created ────────────
# PAUSE_FILE was removed by Test 5; a new spike must re-create it.
AMBIENT2="$TMP/ambient2.jsonl"; touch "$AMBIENT2"
CONSEC2="$TMP/chump-waste-recovery-count2"
set_tally 100 35   # 35% — re-spike

env "${COMMON_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$AMBIENT2" \
    CHUMP_WASTE_CONSEC_FILE="$CONSEC2" \
    bash "$DETECTOR" 2>/dev/null || true

if [[ -f "$PAUSE_FILE" ]]; then
    ok "Test 7: re-spike (35%) after recovery → fleet-paused re-created"
else
    fail "Test 7: fleet-paused not re-created on re-spike after recovery"
fi

# ── Test 8: waste-spike-detector.sh always runs (CHUMP_IGNORE_WASTE_PAUSE deleted) ──
# INFRA-2424: the bypass env var is gone. At 40% waste rate the detector should
# still write fleet-paused (no skip path exists anymore).
rm -f "$PAUSE_FILE"
AMBIENT3="$TMP/ambient3.jsonl"; touch "$AMBIENT3"
set_tally 100 40   # 40% waste rate — above spike threshold

env "${COMMON_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$AMBIENT3" \
    bash "$DETECTOR" 2>/dev/null || true

if [[ -f "$PAUSE_FILE" ]]; then
    ok "Test 8: 40% waste rate → fleet-paused created (no bypass path; detector always runs)"
else
    fail "Test 8: fleet-paused not created at 40% waste rate"
fi

if grep -q "CHUMP_IGNORE_WASTE_PAUSE" "$DETECTOR" 2>/dev/null; then
    fail "Test 8b: waste-spike-detector.sh still references CHUMP_IGNORE_WASTE_PAUSE — not cleaned up"
else
    ok "Test 8b: waste-spike-detector.sh does not reference CHUMP_IGNORE_WASTE_PAUSE (INFRA-2424)"
fi

# ── Test 9: worker.sh fleet-pause check is wired ──────────────────────────
if grep -q 'worker_paused_waste_spike' "$WORKER" 2>/dev/null; then
    ok "Test 9: worker.sh emits kind=worker_paused_waste_spike when paused"
else
    fail "Test 9: worker_paused_waste_spike not wired in worker.sh"
fi

if grep -q 'fleet-paused\|CHUMP_FLEET_PAUSE_FILE' "$WORKER" 2>/dev/null; then
    ok "Test 9b: worker.sh references fleet-paused sentinel (claim still blocks)"
else
    fail "Test 9b: worker.sh does not reference fleet-paused sentinel"
fi

if grep -q 'CHUMP_IGNORE_WASTE_PAUSE' "$WORKER" 2>/dev/null; then
    fail "Test 9c: worker.sh still references CHUMP_IGNORE_WASTE_PAUSE — bypass not deleted (INFRA-2424)"
else
    ok "Test 9c: worker.sh does not reference CHUMP_IGNORE_WASTE_PAUSE (INFRA-2424)"
fi

echo ""
echo "=== test-waste-spike-pause.sh PASSED ==="
