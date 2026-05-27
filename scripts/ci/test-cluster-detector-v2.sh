#!/usr/bin/env bash
# scripts/ci/test-cluster-detector-v2.sh — INFRA-2012
#
# Validates the SECOND clustering heuristic: SHARED SUSPECT COMMIT.
# When 3+ BLOCKED PRs have DIFFERENT failing-check sets but blame-bot
# surfaces the SAME suspect commit(s), the detector must still fire a
# ci_failure_cluster event (cluster_type=suspect_commit).
#
# This is exactly the miss-case from the 2026-05-25 stuck-AF cascade:
#   6 PRs cascaded on INFRA-2003 trunk-RED — each failed a DIFFERENT
#   check, so Phase 1 saw 0 clusters. The same suspect commit would
#   have grouped them.
#
# Tests:
#   1. 3 BLOCKED PRs with DIFFERENT failing checks + SAME blame suspect
#      → ci_failure_cluster fires (cluster_type=suspect_commit)
#   2. cluster_type field is present and correct in ambient event
#   3. suspect_commits field is present in ambient event
#   4. Backwards-compat: IDENTICAL checks still cluster (faster path,
#      no blame-bot call needed) — verify Pass 1 still fires
#   5. No suspects from blame-bot + different checks → no cluster
#      (regression guard: v2 must not over-cluster)
#
# W-013 immunization: unset workflow-injected env vars.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2012 cluster-detector-v2 tests (suspect-commit heuristic) ==="
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

# Fake gh: emits whatever JSON is in $TMP_GH_PR_LIST for `pr list`.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        cat "${TMP_GH_PR_LIST:-/dev/null}" 2>/dev/null || echo "[]"
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

# run_detector: runs the detector with controlled env.
# CHUMP_BLAME_BOT_SUSPECTS_CSV bypasses real blame-bot (test injection).
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

# ── Test 1: DIFFERENT failing checks + SAME blame suspect → cluster fires ──────
echo "--- Test 1: 3 BLOCKED PRs with DIFFERENT checks + SAME suspect → ci_failure_cluster ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[
  {"number":501,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]},
  {"number":502,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"audit","conclusion":"FAILURE"}]},
  {"number":503,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE"}]}
]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/reserve.log"
rm -f "$FAKE/.chump-locks/cluster-detector-state.json"

# Inject a suspect commit via test env var (bypasses real blame-bot)
SUSPECT_SHA="abc1234def56"
OUT=$(CHUMP_BLAME_BOT_SUSPECTS_CSV="$SUSPECT_SHA" run_detector)
if grep -q "ci_failure_cluster" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "3 PRs with DIFFERENT checks but SAME suspect emitted ci_failure_cluster"
else
    fail "expected ci_failure_cluster from suspect-commit heuristic (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 2: cluster_type=suspect_commit in ambient event ─────────────────────
echo "--- Test 2: cluster_type=suspect_commit present in ambient event ---"
if grep -q '"cluster_type":"suspect_commit"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "cluster_type=suspect_commit present in ambient event"
else
    fail "expected cluster_type=suspect_commit in event (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 3: suspect_commits field present in ambient event ────────────────────
echo "--- Test 3: suspect_commits field present in ambient event ---"
if grep -q '"suspect_commits"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null && \
   grep -q "$SUSPECT_SHA" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "suspect_commits field present with correct SHA"
else
    fail "expected suspect_commits with sha=$SUSPECT_SHA (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 4: backwards-compat — IDENTICAL checks still cluster (Pass 1) ───────
echo "--- Test 4: backwards-compat — IDENTICAL failing checks still cluster ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[
  {"number":601,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]},
  {"number":602,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]},
  {"number":603,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"},{"name":"audit","conclusion":"FAILURE"}]}
]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/reserve.log"
rm -f "$FAKE/.chump-locks/cluster-detector-state.json"

# No blame suspects injected → only Pass 1 (identical-checks) should fire
OUT=$(run_detector)
if grep -q "ci_failure_cluster" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null && \
   grep -q '"count":3' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "IDENTICAL checks still cluster via Pass 1 (backwards-compat)"
else
    fail "expected ci_failure_cluster from Pass 1 (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 5: no suspects + different checks → no cluster ──────────────────────
echo "--- Test 5: no blame suspects + DIFFERENT checks → NO cluster (no over-clustering) ---"
cat > "$TMP/gh-pr-list.json" <<'EOF'
[
  {"number":701,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]},
  {"number":702,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"audit","conclusion":"FAILURE"}]},
  {"number":703,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"clippy","conclusion":"FAILURE"}]}
]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/reserve.log"
rm -f "$FAKE/.chump-locks/cluster-detector-state.json"

# No blame suspects (empty string injection) — different checks, no suspects
OUT=$(CHUMP_BLAME_BOT_SUSPECTS_CSV="" run_detector)
if ! grep -q "ci_failure_cluster" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "no suspects + different checks → no cluster (no over-clustering)"
else
    fail "should NOT cluster when no suspects and checks differ (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
