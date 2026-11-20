#!/usr/bin/env bash
# scripts/ci/test-cluster-auto-hold.sh — INFRA-2004 (THE FLOOR Phase 2)
#
# Validates the cluster-detector → fleet-hold.txt → worker contract chain:
#   1. No clusters → no hold file, fleet-hold-check exits 0
#   2. Cluster fires → hold file written with JSON payload
#   3. fleet-hold-check exits 2 + prints details when hold is active
#   4. --json output is parseable
#   5. Cluster resolves → hold file removed, check exits 0 again
#
# W-013 immunization (RESILIENT-024 pattern): unset workflow-injected env.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2004 cluster auto-HOLD tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/cluster-detector.sh"
CHECKER="$REPO_ROOT/scripts/coord/fleet-hold-check.sh"

[[ -x "$DETECTOR" ]] || { echo "FATAL: $DETECTOR not executable"; exit 2; }
[[ -x "$CHECKER" ]]  || { echo "FATAL: $CHECKER not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset CHUMP_REPO CHUMP_LOCK_DIR

# Fake repo with the cluster-detector + checker
FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"
cp "$DETECTOR" "$TMP/cluster-detector.sh"
chmod +x "$TMP/cluster-detector.sh"

# Mock gh + chump (record reserves)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        cat "$TMP_GH_PR_LIST" 2>/dev/null || echo "[]"
        ;;
    *) echo "[]" ;;
esac
GH
chmod +x "$TMP/bin/gh"
cat > "$TMP/bin/chump" <<'CMOCK'
#!/usr/bin/env bash
case "$1" in
    gap)
        case "$2" in
            reserve)
                echo "$@" >> "${CHUMP_RESERVE_LOG:-/dev/null}"
                echo "META-CLUSTER-$(date +%s)"
                exit 0
                ;;
        esac
        ;;
esac
exit 0
CMOCK
chmod +x "$TMP/bin/chump"

run_detector() {
    cd "$FAKE" || return 2
    PATH="$TMP/bin:$PATH" \
    CHUMP_REPO="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    TMP_GH_PR_LIST="${TMP_GH_PR_LIST:-$TMP/gh-pr-list.json}" \
    CHUMP_RESERVE_LOG="$TMP/reserve.log" \
    bash "$TMP/cluster-detector.sh" "$@" 2>&1
    RC=$?
    cd - >/dev/null
    return "$RC"
}

run_checker() {
    CHUMP_REPO="$FAKE" \
    CHUMP_FLEET_HOLD_FILE="$FAKE/.chump-locks/fleet-hold.txt" \
    bash "$CHECKER" "$@" 2>&1
    return "$?"
}

# ── Test 1: no clusters → no hold file ───────────────────────────────────────
echo "--- Test 1: no clusters → no hold file ---"
echo "[]" > "$TMP/gh-pr-list.json"
rm -f "$FAKE/.chump-locks/fleet-hold.txt"
run_detector > /dev/null
if [[ ! -f "$FAKE/.chump-locks/fleet-hold.txt" ]]; then
    ok "no cluster → no hold file written"
else
    fail "hold file should not exist (contents=$(cat "$FAKE/.chump-locks/fleet-hold.txt" 2>/dev/null))"
fi

# ── Test 2: fleet-hold-check exits 0 when no hold ───────────────────────────
echo "--- Test 2: fleet-hold-check exits 0 when no hold ---"
OUT=$(run_checker)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "not active"; then
    ok "check exited 0 + correct message"
else
    fail "expected rc=0 + 'not active' (rc=$RC, out=$OUT)"
fi

# ── Test 3: cluster fires → hold file written ───────────────────────────────
echo "--- Test 3: 3 BLOCKED PRs identical failures → hold file written ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[
  {"number":401,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]},
  {"number":402,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]},
  {"number":403,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]}
]
EOF
rm -f "$FAKE/.chump-locks/cluster-detector-state.json" "$FAKE/.chump-locks/fleet-hold.txt"
run_detector > /dev/null
if [[ -f "$FAKE/.chump-locks/fleet-hold.txt" ]]; then
    ok "cluster fire → hold file created"
else
    fail "hold file should exist after cluster fire"
fi

# Inspect contents
if grep -q '"active": true' "$FAKE/.chump-locks/fleet-hold.txt" 2>/dev/null \
   && grep -q '"reason": "ci_failure_cluster"' "$FAKE/.chump-locks/fleet-hold.txt" 2>/dev/null; then
    ok "hold file payload has active:true + reason:ci_failure_cluster"
else
    fail "hold file payload malformed (contents=$(cat "$FAKE/.chump-locks/fleet-hold.txt"))"
fi

# ── Test 4: fleet-hold-check exits 2 when hold active ──────────────────────
echo "--- Test 4: fleet-hold-check exits 2 + prints details when hold active ---"
OUT=$(run_checker 2>&1)
RC=$?
if [[ "$RC" -eq 2 ]] && echo "$OUT" | grep -q "ACTIVE"; then
    ok "check exited 2 + 'ACTIVE' message"
else
    fail "expected rc=2 + 'ACTIVE' (rc=$RC, out=$OUT)"
fi

# ── Test 5: --json output parseable ────────────────────────────────────────
echo "--- Test 5: --json output is parseable JSON ---"
OUT=$(run_checker --json)
if echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('active') == True
assert 'cluster_id' in d
assert 'reason' in d
print('OK')
" 2>&1 | grep -q "OK"; then
    ok "--json output is well-formed + has expected fields"
else
    fail "--json output malformed (out=$OUT)"
fi

# ── Test 6: cluster resolves → hold file removed ───────────────────────────
echo "--- Test 6: cluster resolves → hold file removed ---"
echo "[]" > "$TMP/gh-pr-list.json"
run_detector > /dev/null
if [[ ! -f "$FAKE/.chump-locks/fleet-hold.txt" ]]; then
    ok "cluster resolved → hold file removed"
else
    fail "hold file should be removed after resolution (contents=$(cat "$FAKE/.chump-locks/fleet-hold.txt" 2>/dev/null))"
fi

OUT=$(run_checker)
RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "post-resolution check exits 0 again"
else
    fail "expected rc=0 after resolution (rc=$RC)"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
