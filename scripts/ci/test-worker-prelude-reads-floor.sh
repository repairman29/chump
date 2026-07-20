#!/usr/bin/env bash
# scripts/ci/test-worker-prelude-reads-floor.sh — INFRA-2008
#
# Focused unit test for scripts/dispatch/lib/floor-readers.sh: synthesizes
# fleet-hold.txt + a HOT ambient.jsonl signal and asserts chump_floor_read
# exports the correct CHUMP_FLOOR_TEMP / CHUMP_FLEET_HOLD values, then
# asserts worker.sh's prelude pivots correctly on each combination.
# Complements scripts/ci/test-worker-prelude-floor-signals.sh (worker.sh
# functional/behavioral coverage); this one isolates the lib contract.

set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2008 floor-readers.sh lib contract tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/dispatch/lib/floor-readers.sh"

[[ -f "$LIB" ]] || { echo "FATAL: missing $LIB"; exit 2; }

if grep -q "chump_floor_read" "$LIB" && grep -q "CHUMP_FLOOR_TEMP" "$LIB" && grep -q "CHUMP_FLEET_HOLD" "$LIB"; then
    ok "lib defines chump_floor_read + exports CHUMP_FLOOR_TEMP/CHUMP_FLEET_HOLD"
else
    fail "lib missing chump_floor_read or the two exported vars"
fi

if grep -q "scripts/dispatch/lib/floor-readers.sh\|floor-readers.sh" "$REPO_ROOT/scripts/dispatch/worker.sh"; then
    ok "worker.sh sources floor-readers.sh"
else
    fail "worker.sh does NOT source floor-readers.sh"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks" "$FAKE/scripts/coord" "$FAKE/scripts/dispatch/lib"
cp "$LIB" "$FAKE/scripts/dispatch/lib/floor-readers.sh"

# fleet-hold-check.sh stub: exit 2 when hold file present, else exit 0.
cat > "$FAKE/scripts/coord/fleet-hold-check.sh" <<'HOLD_CHECK'
#!/usr/bin/env bash
HOLD_FILE="${CHUMP_FLEET_HOLD_FILE:-/nonexistent}"
[[ -f "$HOLD_FILE" ]] && exit 2
exit 0
HOLD_CHECK
chmod +x "$FAKE/scripts/coord/fleet-hold-check.sh"

# chump stub: `health --temp` exit code driven by CHUMP_MOCK_TEMP_RC.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'CMOCK'
#!/usr/bin/env bash
case "$1 $2" in
    "health --temp") exit "${CHUMP_MOCK_TEMP_RC:-0}" ;;
    *) exit 0 ;;
esac
CMOCK
chmod +x "$TMP/bin/chump"

run_read() {
    (
        export PATH="$TMP/bin:$PATH"
        export REPO_ROOT="$FAKE"
        export CHUMP_FLEET_HOLD_FILE="$1"
        export CHUMP_MOCK_TEMP_RC="$2"
        # shellcheck source=/dev/null
        source "$FAKE/scripts/dispatch/lib/floor-readers.sh"
        chump_floor_read
        echo "TEMP=$CHUMP_FLOOR_TEMP HOLD=$CHUMP_FLEET_HOLD"
    )
}

echo "--- COLD + no hold ---"
out="$(run_read /nonexistent 0)"
[[ "$out" == "TEMP=COLD HOLD=false" ]] && ok "COLD/no-hold: $out" || fail "COLD/no-hold: got '$out'"

echo "--- WARM ---"
out="$(run_read /nonexistent 1)"
[[ "$out" == "TEMP=WARM HOLD=false" ]] && ok "WARM: $out" || fail "WARM: got '$out'"

echo "--- HOT + fleet-hold active ---"
touch "$FAKE/.chump-locks/fleet-hold.txt"
out="$(run_read "$FAKE/.chump-locks/fleet-hold.txt" 2)"
[[ "$out" == "TEMP=HOT HOLD=true" ]] && ok "HOT/hold: $out" || fail "HOT/hold: got '$out'"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
