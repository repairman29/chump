#!/usr/bin/env bash
# scripts/ci/test-barnacle-buster.sh — RESILIENT-359 unit tests.
#
# Verifies scripts/coord/barnacle-buster.sh against a synthetic registry:
#   (1) surface below threshold -> no ambient alert, no gap reserve call
#   (2) surface above threshold -> ambient barnacle_threshold_crossed emitted
#   (3) surface above threshold -> chump gap reserve invoked (mocked)
#   (4) debounce: second run within window does NOT re-file the gap
#   (5) --dry-run never calls gap reserve even when breached
#   (6) barnacle_buster_tick emitted every run (Roll-Called visibility)
#   (7) a check command that fails/produces no numeric output is skipped,
#       not treated as a breach

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== RESILIENT-359 barnacle-buster unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUSTER="$REPO_ROOT/scripts/coord/barnacle-buster.sh"

if [ ! -x "$BUSTER" ]; then
    chmod +x "$BUSTER" 2>/dev/null || true
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

AMBIENT="$TMPDIR_BASE/ambient.jsonl"
STATE_DIR="$TMPDIR_BASE/state"
CHUMP_CALLS="$TMPDIR_BASE/chump-calls.log"

# Mock `chump` binary: logs every invocation, "succeeds" gap reserve.
CHUMP_SHIM_DIR="$TMPDIR_BASE/bin"
mkdir -p "$CHUMP_SHIM_DIR"
cat > "$CHUMP_SHIM_DIR/chump-mock" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CHUMP_CALLS"
echo "MOCK-GAP-1"
exit 0
EOF
chmod +x "$CHUMP_SHIM_DIR/chump-mock"

write_registry() {
    # $1 = registry path, $2 = check command, $3 = threshold
    cat > "$1" <<EOF
surfaces:
  - id: test-surface
    description: "synthetic test surface"
    check: "$2"
    threshold: $3
    domain: RESILIENT
    priority: P2
    effort: s
EOF
}

reset_state() {
    : > "$AMBIENT"
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    : > "$CHUMP_CALLS"
}

run_buster() {
    CHUMP_BARNACLE_AMBIENT="$AMBIENT" \
    CHUMP_BARNACLE_STATE_DIR="$STATE_DIR" \
    CHUMP_BARNACLE_CHUMP_CMD="$CHUMP_SHIM_DIR/chump-mock" \
    CHUMP_BARNACLE_REGISTRY="$1" \
        "$BUSTER" "${@:2}" 2>&1
}

# ── Test 1: below threshold -> no alert, no gap ─────────────────────────────
echo "--- Test 1: value below threshold -> healthy, no action ---"
reset_state
REG="$TMPDIR_BASE/registry-below.yaml"
write_registry "$REG" "echo 5" 30
out=$(run_buster "$REG")
if ! grep -q "barnacle_threshold_crossed" "$AMBIENT"; then
    ok "Test 1: no threshold-crossed event for value below threshold"
else
    fail "Test 1: unexpected threshold-crossed event: $(cat "$AMBIENT")"
fi
if [ ! -s "$CHUMP_CALLS" ]; then
    ok "Test 1: no gap reserve call for healthy surface"
else
    fail "Test 1: unexpected chump call(s): $(cat "$CHUMP_CALLS")"
fi

# ── Test 2: above threshold -> ambient alert ────────────────────────────────
echo "--- Test 2: value above threshold -> barnacle_threshold_crossed emitted ---"
reset_state
REG="$TMPDIR_BASE/registry-above.yaml"
write_registry "$REG" "echo 99" 30
out=$(run_buster "$REG")
if grep -q '"kind":"barnacle_threshold_crossed"' "$AMBIENT" && grep -q '"surface":"test-surface"' "$AMBIENT"; then
    ok "Test 2: threshold-crossed event emitted with correct surface id"
else
    fail "Test 2: expected threshold-crossed event, got: $(cat "$AMBIENT")"
fi

# ── Test 3: above threshold -> gap reserve invoked ──────────────────────────
echo "--- Test 3: value above threshold -> chump gap reserve called ---"
reset_state
out=$(run_buster "$REG")
if grep -q "gap reserve" "$CHUMP_CALLS" && grep -q "RESILIENT" "$CHUMP_CALLS"; then
    ok "Test 3: gap reserve invoked with domain RESILIENT"
else
    fail "Test 3: expected gap reserve call, got: $(cat "$CHUMP_CALLS" 2>/dev/null || echo '<empty>')"
fi

# ── Test 4: debounce -> second run within window does not re-file ──────────
echo "--- Test 4: debounce suppresses re-filing within window ---"
reset_state
run_buster "$REG" >/dev/null
first_calls=$(wc -l < "$CHUMP_CALLS")
run_buster "$REG" >/dev/null
second_calls=$(wc -l < "$CHUMP_CALLS")
if [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ]; then
    ok "Test 4: second run within debounce window did not re-file (still 1 call)"
else
    fail "Test 4: expected 1 call after two runs, got first=$first_calls second=$second_calls"
fi

# ── Test 5: --dry-run never files a gap even when breached ─────────────────
echo "--- Test 5: --dry-run suppresses gap reserve on breach ---"
reset_state
out=$(run_buster "$REG" --dry-run)
if [ ! -s "$CHUMP_CALLS" ]; then
    ok "Test 5: --dry-run made no chump calls despite breach"
else
    fail "Test 5: unexpected chump call(s) under --dry-run: $(cat "$CHUMP_CALLS")"
fi
if grep -q "DRY-RUN" <<<"$out"; then
    ok "Test 5: dry-run output announces what it would have filed"
else
    fail "Test 5: expected DRY-RUN announcement in output"
fi

# ── Test 6: barnacle_buster_tick emitted every run ──────────────────────────
echo "--- Test 6: barnacle_buster_tick emitted (Roll-Called visibility) ---"
reset_state
REG_HEALTHY="$TMPDIR_BASE/registry-healthy.yaml"
write_registry "$REG_HEALTHY" "echo 1" 30
run_buster "$REG_HEALTHY" >/dev/null
if grep -q '"kind":"barnacle_buster_tick"' "$AMBIENT"; then
    ok "Test 6: barnacle_buster_tick emitted on a clean run"
else
    fail "Test 6: expected barnacle_buster_tick, got: $(cat "$AMBIENT")"
fi

# ── Test 7: broken check command is skipped, not treated as breach ─────────
echo "--- Test 7: non-numeric check output -> skipped, no false breach ---"
reset_state
REG_BROKEN="$TMPDIR_BASE/registry-broken.yaml"
write_registry "$REG_BROKEN" "exit 1" 30
out=$(run_buster "$REG_BROKEN")
if ! grep -q "barnacle_threshold_crossed" "$AMBIENT"; then
    ok "Test 7: broken check produced no false-positive breach"
else
    fail "Test 7: broken check incorrectly triggered a breach: $(cat "$AMBIENT")"
fi
if echo "$out" | grep -qi "WARN.*skipping"; then
    ok "Test 7: WARN logged for broken check"
else
    fail "Test 7: expected WARN about skipped check, got: $out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
