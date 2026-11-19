#!/usr/bin/env bash
# scripts/ci/test-cross-daemon-coord.sh — INFRA-2025
#
# Smoke test: verify cluster-detector defers when recovery-cycle-in-flight.flag
# is present, and resumes normally once the flag is removed.
#
# Tests:
#   1. Flag absent → cluster-detector runs normally (no deferred event)
#   2. Flag present → cluster-detector emits cluster_detection_deferred_for_recovery + exits 0
#   3. Flag present + --json → structured deferred JSON response
#   4. Flag present + --dry-run → dry-run deferred message (no ambient write)
#   5. Flag removed → cluster-detector runs normally again (no deferred event)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2025 cross-daemon coord tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/cluster-detector.sh"

if [[ ! -x "$DETECTOR" ]]; then
    echo "FATAL: cluster-detector not executable: $DETECTOR"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# W-013 immunization
unset CHUMP_REPO CHUMP_LOCK_DIR

# Fake repo with .chump-locks dir
FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"
cp "$DETECTOR" "$TMP/cluster-detector.sh"
chmod +x "$TMP/cluster-detector.sh"

# Fake gh: returns empty PR list (no clusters — we only care about deferral logic)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "[]"
GH
chmod +x "$TMP/bin/gh"

# Fake chump: no-op
cat > "$TMP/bin/chump" <<'CMOCK'
#!/usr/bin/env bash
exit 0
CMOCK
chmod +x "$TMP/bin/chump"

IN_FLIGHT_FLAG="$FAKE/.chump-locks/recovery-cycle-in-flight.flag"

run_detector() {
    local _rc
    (
        cd "$FAKE" || exit 2
        PATH="$TMP/bin:$PATH" \
        CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        CHUMP_RECOVERY_IN_FLIGHT_FLAG="$IN_FLIGHT_FLAG" \
        bash "$TMP/cluster-detector.sh" "$@" 2>&1
    )
    return $?
}

# ── Test 1: no flag → runs normally (no deferred event) ─────────────────────
echo "--- Test 1: flag absent → normal scan (no deferred event) ---"
rm -f "$IN_FLIGHT_FLAG"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
RC=$?
if [[ $RC -eq 0 ]] \
   && ! grep -q "cluster_detection_deferred_for_recovery" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && ! echo "$OUT" | grep -q "deferred"; then
    ok "no flag → no deferred event, exit 0"
else
    fail "no flag should not produce deferred (rc=$RC, out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null))"
fi

# ── Test 2: flag present → deferred event emitted, exit 0 ───────────────────
echo "--- Test 2: flag present → cluster_detection_deferred_for_recovery emitted ---"
touch "$IN_FLIGHT_FLAG"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
RC=$?
if [[ $RC -eq 0 ]] \
   && grep -q "cluster_detection_deferred_for_recovery" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"reason":"recovery_cycle_in_flight"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && echo "$OUT" | grep -q "deferred"; then
    ok "flag present → deferred event emitted + exit 0"
else
    fail "expected deferred event (rc=$RC, out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null))"
fi
rm -f "$IN_FLIGHT_FLAG"

# ── Test 3: flag present + --json → structured deferred JSON ────────────────
echo "--- Test 3: flag present + --json → structured deferred JSON response ---"
touch "$IN_FLIGHT_FLAG"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector --json)
RC=$?
# Extract first JSON line from output (ignore stderr lines)
JSON_LINE="$(echo "$OUT" | grep -m1 '^{' || true)"
if [[ $RC -eq 0 ]] \
   && echo "$JSON_LINE" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
status = d.get("status")
reason = d.get("reason")
assert status == "deferred", "status=" + str(status)
assert reason == "recovery_cycle_in_flight", "reason=" + str(reason)
' 2>/dev/null; then
    ok "flag present + --json → {status:deferred, reason:recovery_cycle_in_flight}"
else
    fail "expected structured JSON deferred response (rc=$RC, out=$OUT)"
fi
rm -f "$IN_FLIGHT_FLAG"

# ── Test 4: flag present + --dry-run → no ambient write ─────────────────────
echo "--- Test 4: flag present + --dry-run → no ambient write ---"
touch "$IN_FLIGHT_FLAG"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector --dry-run)
RC=$?
if [[ $RC -eq 0 ]] \
   && [[ ! -s "$FAKE/.chump-locks/ambient.jsonl" ]] \
   && echo "$OUT" | grep -q "dry-run"; then
    ok "flag + --dry-run → no ambient write, dry-run message in stdout"
else
    fail "expected no ambient write in dry-run (rc=$RC, out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null))"
fi
rm -f "$IN_FLIGHT_FLAG"

# ── Test 5: flag removed → resumes normally (no deferred event) ─────────────
echo "--- Test 5: flag removed → normal scan resumes (no deferred event) ---"
rm -f "$IN_FLIGHT_FLAG"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
RC=$?
if [[ $RC -eq 0 ]] \
   && ! grep -q "cluster_detection_deferred_for_recovery" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && ! echo "$OUT" | grep -q "deferred"; then
    ok "flag removed → normal scan, no deferred event"
else
    fail "flag removed should not produce deferred (rc=$RC, out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null))"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
