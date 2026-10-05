#!/usr/bin/env bash
# scripts/ci/test-systemic-red-detector.sh — RESILIENT-337
#
# Validates scripts/coord/systemic-red-detector.sh (W-015 wedge class:
# systemic-red shared-check wedge). Covers the gap's AC:
#   1. N>=3 open PRs failing the IDENTICAL check → wedge_detected fires,
#      naming the shared check + PR numbers + a suspected root cause.
#   2. <3 open PRs sharing a check → clean, no alarm (below threshold).
#   3. Different PRs failing DIFFERENT checks → clean (no single check
#      crosses the threshold), proving this is distinct from a naive
#      "any PR has any failure" aggregate (W-AGG).
#   4. --check-only exits 1 on detection with zero emits.
#   5. CHUMP_SYSTEMIC_RED_DISABLED=1 bypasses cleanly.
#   6. wedge-watch.sh wires the detector in (W-015 section present).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== RESILIENT-337 systemic-red-detector tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/systemic-red-detector.sh"
[[ -x "$DETECTOR" ]] || { echo "FATAL: $DETECTOR not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"
AMBIENT="$FAKE/.chump-locks/ambient.jsonl"

BIN="$TMP/bin"
mkdir -p "$BIN"

run_detector() {
    > "$AMBIENT"
    env PATH="$BIN:$PATH" \
        CHUMP_REPO_ROOT="$FAKE" \
        CHUMP_AMBIENT_LOG="$AMBIENT" \
        "$@" \
        bash "$DETECTOR" ${W015_ARGS:-} 2>&1
}

# ── 0: source contract ───────────────────────────────────────────────────────
echo "--- 0: source contract ---"
bash -n "$DETECTOR" || fail "detector bash -n failed"
pass_msg="detector script present + executable + syntax clean"
ok "$pass_msg"

# ── Test 1: 3 PRs failing IDENTICAL check → W-015 DETECTED ─────────────────
echo "--- Test 1: 3 open PRs failing identical check 'fast-checks' → W-015 DETECTED ---"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[{"number":11,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":12,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":13,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":14,"statusCheckRollup":[{"name":"unit-tests","conclusion":"SUCCESS"}]}]'
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"

OUT=$(run_detector)
if grep -q '"kind":"wedge_detected"' "$AMBIENT" \
   && grep -q '"wedge_class":"W-015"' "$AMBIENT" \
   && grep -q '"check":"fast-checks"' "$AMBIENT" \
   && grep -q '"pr_count":3' "$AMBIENT" \
   && grep -q '"pr_numbers":"11,12,13"' "$AMBIENT" \
   && grep -q '"suspected_cause":' "$AMBIENT" \
   && grep -q '"result":"detected"' "$AMBIENT"; then
    ok "3 PRs sharing 'fast-checks' failure → wedge_detected W-015 names check + PRs + cause"
else
    fail "expected W-015 detection (ambient=$(cat "$AMBIENT"))"
fi
echo "$OUT" | grep -q "DETECTED" || fail "stdout should report DETECTED"

# ── Test 2: only 2 PRs share a check → below threshold, clean ──────────────
echo "--- Test 2: only 2 PRs failing same check → clean (below threshold) ---"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[{"number":21,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":22,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":23,"statusCheckRollup":[{"name":"unit-tests","conclusion":"SUCCESS"}]}]'
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"

OUT=$(run_detector)
if grep -q '"result":"clean"' "$AMBIENT" && ! grep -q 'wedge_detected' "$AMBIENT"; then
    ok "2 PRs below threshold=3 → clean, no wedge_detected"
else
    fail "expected clean below threshold (ambient=$(cat "$AMBIENT"))"
fi

# ── Test 3: 3 PRs failing but each a DIFFERENT check → clean ───────────────
# This is the discriminator vs. W-AGG: a naive "any PR has any failure"
# aggregate would fire here (3 failing PRs total); this detector must NOT,
# because no single check name is shared by >= 3 PRs.
echo "--- Test 3: 3 PRs, 3 different failing checks → clean (no shared check) ---"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[{"number":31,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":32,"statusCheckRollup":[{"name":"clippy","conclusion":"FAILURE"}]},{"number":33,"statusCheckRollup":[{"name":"unit-tests","conclusion":"FAILURE"}]}]'
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"

OUT=$(run_detector)
if grep -q '"result":"clean"' "$AMBIENT" && ! grep -q 'wedge_detected' "$AMBIENT"; then
    ok "3 distinct failing checks (no overlap) → clean, distinct from W-AGG's raw-count aggregate"
else
    fail "expected clean with 3 distinct checks (ambient=$(cat "$AMBIENT"))"
fi

# ── Test 4: --check-only exits 1 on detection, emits nothing ───────────────
echo "--- Test 4: --check-only exits 1 on detection, no emits ---"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[{"number":41,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":42,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":43,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]}]'
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"
> "$AMBIENT"
env PATH="$BIN:$PATH" CHUMP_REPO_ROOT="$FAKE" CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$DETECTOR" --check-only > /dev/null 2>&1
RC=$?
if [[ "$RC" -eq 1 ]] && [[ ! -s "$AMBIENT" ]]; then
    ok "--check-only: rc=1 on detect, no events emitted"
else
    fail "expected rc=1 + no emits (rc=$RC, ambient=$(cat "$AMBIENT" 2>/dev/null))"
fi

# ── Test 5: CHUMP_SYSTEMIC_RED_DISABLED=1 bypasses cleanly ─────────────────
echo "--- Test 5: CHUMP_SYSTEMIC_RED_DISABLED=1 bypass ---"
> "$AMBIENT"
OUT=$(CHUMP_SYSTEMIC_RED_DISABLED=1 CHUMP_REPO_ROOT="$FAKE" CHUMP_AMBIENT_LOG="$AMBIENT" bash "$DETECTOR" 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ ! -s "$AMBIENT" ]] && echo "$OUT" | grep -q "CHUMP_SYSTEMIC_RED_DISABLED"; then
    ok "bypass short-circuits cleanly, no emits"
else
    fail "expected clean bypass (rc=$RC, ambient=$(cat "$AMBIENT" 2>/dev/null))"
fi

# ── Test 6: threshold is configurable via CHUMP_SYSTEMIC_RED_THRESHOLD ─────
echo "--- Test 6: CHUMP_SYSTEMIC_RED_THRESHOLD=2 lowers the bar ---"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[{"number":61,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},{"number":62,"statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]}]'
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"
> "$AMBIENT"
env PATH="$BIN:$PATH" CHUMP_REPO_ROOT="$FAKE" CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_SYSTEMIC_RED_THRESHOLD=2 bash "$DETECTOR" > /dev/null 2>&1
if grep -q '"wedge_class":"W-015"' "$AMBIENT" && grep -q '"pr_count":2' "$AMBIENT"; then
    ok "threshold override to 2 fires on 2 shared-check PRs"
else
    fail "expected threshold-2 detection (ambient=$(cat "$AMBIENT" 2>/dev/null))"
fi

# ── Test 7: wedge-watch.sh wires the detector in ────────────────────────────
echo "--- Test 7: wedge-watch.sh references the W-015 detector ---"
WEDGE_WATCH="$REPO_ROOT/scripts/coord/wedge-watch.sh"
if [[ -f "$WEDGE_WATCH" ]] && grep -q "systemic-red-detector.sh" "$WEDGE_WATCH" && grep -q "W-015" "$WEDGE_WATCH"; then
    ok "wedge-watch.sh wires in systemic-red-detector.sh under W-015"
else
    fail "wedge-watch.sh missing W-015 wiring"
fi

# ── Test 8: wedge-state-machine.sh routes W-015 ────────────────────────────
echo "--- Test 8: wedge-state-machine.sh has a W-015 remediation route ---"
WSM="$REPO_ROOT/scripts/coord/wedge-state-machine.sh"
if [[ -f "$WSM" ]] && grep -q "W-015)" "$WSM"; then
    ok "wedge-state-machine.sh routes W-015"
else
    fail "wedge-state-machine.sh missing W-015 route"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
