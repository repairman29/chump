#!/usr/bin/env bash
# scripts/ci/test-cluster-detector.sh — INFRA-1987 (THE FLOOR Phase 1)
#
# Validates the CI-failure cluster detector. Stubs `gh pr list` with
# controllable JSON output, runs the detector, and asserts:
#   1. CHUMP_SKIP_CLUSTER_DETECTOR=1 → silent no-op
#   2. No BLOCKED PRs → "clean" output, no ambient emit
#   3. 1 BLOCKED PR with failures → no cluster (below threshold)
#   4. 3 BLOCKED PRs with IDENTICAL failing checks → kind=ci_failure_cluster fires
#   5. 3 BLOCKED PRs with DIFFERENT failing checks → no cluster (different sets)
#   6. Idempotency: same cluster re-detected → state file updated, no re-emit
#   7. Resolution: cluster disappears → kind=ci_failure_cluster_resolved fires
#
# W-013 immunization (RESILIENT-024 pattern): unset workflow-injected env
# so this test's own $TMP fixtures are not hijacked by CI workflow paths.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1987 cluster-detector tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/cluster-detector.sh"

if [[ ! -x "$DETECTOR" ]]; then
    echo "FATAL: detector not executable: $DETECTOR"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# W-013 immunization
unset CHUMP_REPO CHUMP_LOCK_DIR

# Fake repo
FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"
cp "$DETECTOR" "$TMP/cluster-detector.sh"
chmod +x "$TMP/cluster-detector.sh"

# Fake gh: emits whatever JSON is in $TMP/gh-pr-list.json for `pr list`.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        cat "$TMP_GH_PR_LIST" 2>/dev/null || echo "[]"
        ;;
    *)
        echo "[]"
        ;;
esac
GH
chmod +x "$TMP/bin/gh"

# Fake chump: records gap reserve calls; returns fake gap ID.
cat > "$TMP/bin/chump" <<'CMOCK'
#!/usr/bin/env bash
case "$1" in
    gap)
        case "$2" in
            reserve)
                echo "$@" >> "$CHUMP_RESERVE_LOG"
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
    cd - >/dev/null || true
    return "$RC"
}

# ── Test 1: bypass env ──────────────────────────────────────────────────────
echo "--- Test 1: CHUMP_SKIP_CLUSTER_DETECTOR=1 → silent no-op ---"
echo "[]" > "$TMP/gh-pr-list.json"
OUT=$(CHUMP_SKIP_CLUSTER_DETECTOR=1 run_detector)
if echo "$OUT" | grep -q "skipped"; then
    ok "bypass env produced skip message"
else
    fail "bypass should print skip (out=$OUT)"
fi

# ── Test 2: empty list ──────────────────────────────────────────────────────
echo "--- Test 2: no BLOCKED PRs → clean output, no ambient ---"
echo "[]" > "$TMP/gh-pr-list.json"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
if echo "$OUT" | grep -q "clean" && [[ ! -s "$FAKE/.chump-locks/ambient.jsonl" ]]; then
    ok "empty input produced clean output + no ambient"
else
    fail "expected clean+empty ambient (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 3: 1 BLOCKED PR (below threshold) ──────────────────────────────────
echo "--- Test 3: 1 BLOCKED PR with failures → no cluster (below threshold) ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[{"number":100,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]}]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
if echo "$OUT" | grep -q "clean" && [[ ! -s "$FAKE/.chump-locks/ambient.jsonl" ]]; then
    ok "1 PR below threshold produced no cluster"
else
    fail "expected clean (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 4: 3 BLOCKED PRs IDENTICAL failures → cluster fires ────────────────
echo "--- Test 4: 3 BLOCKED PRs IDENTICAL failing checks → kind=ci_failure_cluster ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[
  {"number":101,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]},
  {"number":102,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]},
  {"number":103,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]}
]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/reserve.log"
rm -f "$FAKE/.chump-locks/cluster-detector-state.json"
OUT=$(run_detector)
if grep -q "ci_failure_cluster" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"count":3' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "cluster of 3 PRs with identical failures emitted ci_failure_cluster"
else
    fail "expected ci_failure_cluster event (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

if grep -q "CLUSTER RCA" "$TMP/reserve.log" 2>/dev/null; then
    ok "META cluster RCA gap auto-filed"
else
    fail "expected gap reserve with CLUSTER RCA title (reserve.log=$(cat "$TMP/reserve.log" 2>/dev/null))"
fi

# ── Test 5: 3 BLOCKED PRs DIFFERENT failures → no cluster ───────────────────
echo "--- Test 5: 3 BLOCKED PRs DIFFERENT failing checks → no cluster ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[
  {"number":201,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]},
  {"number":202,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"audit","conclusion":"FAILURE"}]},
  {"number":203,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"clippy","conclusion":"FAILURE"}]}
]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/reserve.log"
rm -f "$FAKE/.chump-locks/cluster-detector-state.json"
OUT=$(run_detector)
if ! grep -q "ci_failure_cluster" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && [[ ! -s "$TMP/reserve.log" ]]; then
    ok "3 PRs with DIFFERENT failures did NOT cluster (correct)"
else
    fail "different failures should not cluster (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"), reserve=$(cat "$TMP/reserve.log" 2>/dev/null))"
fi

# ── Test 6: idempotency — second run on same cluster doesn't re-file ────────
echo "--- Test 6: idempotent — second run on same cluster doesn't re-file gap ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[
  {"number":301,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},
  {"number":302,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]},
  {"number":303,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]}
]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/reserve.log"
rm -f "$FAKE/.chump-locks/cluster-detector-state.json"
# First run files the gap
run_detector > /dev/null
FIRST_RESERVES="$(wc -l < "$TMP/reserve.log" | xargs)"
# Second run should NOT re-file
run_detector > /dev/null
SECOND_RESERVES="$(wc -l < "$TMP/reserve.log" | xargs)"
if [[ "$FIRST_RESERVES" == "1" ]] && [[ "$SECOND_RESERVES" == "1" ]]; then
    ok "idempotent: first run filed gap, second did not re-file"
else
    fail "expected first=1 second=1, got first=$FIRST_RESERVES second=$SECOND_RESERVES"
fi

# ── Test 7: resolution — cluster disappears → resolved event ────────────────
echo "--- Test 7: cluster disappears → kind=ci_failure_cluster_resolved ---"
echo "[]" > "$TMP/gh-pr-list.json"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
if grep -q "ci_failure_cluster_resolved" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "cluster resolution emitted ci_failure_cluster_resolved"
else
    fail "expected resolved event (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
