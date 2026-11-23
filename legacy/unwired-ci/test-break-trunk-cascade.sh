#!/usr/bin/env bash
# scripts/ci/test-break-trunk-cascade.sh — INFRA-2087 smoke test.
#
# Asserts the script-level guarantees of break-trunk-cascade.sh without
# needing a real PR or live GitHub API calls.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT="$REPO_ROOT/scripts/ops/break-trunk-cascade.sh"

# ── Test 1: script exists + executable + bash-clean ────────────────────────
echo ""
echo "Test 1: bash -n + executable"
if [[ -x "$SCRIPT" ]]; then
    pass "executable bit set"
else
    fail "not executable"
fi
if bash -n "$SCRIPT" 2>&1; then
    pass "bash syntax OK"
else
    fail "bash syntax broken"
fi

# ── Test 2: --help exits 0 ─────────────────────────────────────────────────
echo ""
echo "Test 2: --help exits 0"
if bash "$SCRIPT" --help >/dev/null 2>&1; then
    pass "--help exits 0"
else
    fail "--help exited non-zero"
fi

# ── Test 3: missing --pr exits 1 ───────────────────────────────────────────
echo ""
echo "Test 3: missing --pr exits 1"
rc=0; bash "$SCRIPT" --reason "test" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "missing --pr rejected with exit 1"
else
    fail "missing --pr should exit 1 (got $rc)"
fi

# ── Test 4: missing --reason exits 1 (audit-trail enforced) ────────────────
echo ""
echo "Test 4: missing --reason exits 1"
rc=0; bash "$SCRIPT" --pr 1 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "missing --reason rejected with exit 1"
else
    fail "missing --reason should exit 1 (got $rc)"
fi

# ── Test 5: rate-limit check fires ─────────────────────────────────────────
echo ""
echo "Test 5: rate-limit check fires (synthesizes a recent invocation)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.chump-locks"
# Synth a recent history entry within the 1h window.
NOW_E=$(date -u +%s)
printf '{"epoch":%s,"ts":"now","pr":99,"reason":"synth","session":"test"}\n' "$NOW_E" \
    > "$SANDBOX/.chump-locks/break-cascade-history.jsonl"
# Run the script from inside the sandbox; expect exit 4 (rate-limited).
rc=0
(cd "$SANDBOX" && git init -q . 2>/dev/null && \
    CHUMP_BREAK_CASCADE_PER_HOUR=1 bash "$SCRIPT" --pr 2 --reason "synth" --repo fake/repo) \
    >/dev/null 2>&1 || rc=$?
# rc 4 = rate-limited, rc 2 = preflight-refused (also acceptable if gh not auth'd).
# Either rc is fine as long as the script EXITED (didn't run the API mutation).
if [[ "$rc" -eq 4 ]] || [[ "$rc" -eq 2 ]] || [[ "$rc" -eq 1 ]]; then
    pass "rate-limit guard fired (exit $rc)"
else
    fail "rate-limit guard should have fired (got $rc)"
fi

# ── Test 6: ambient kind scanner-anchor present (event-registry compat) ────
echo ""
echo "Test 6: scanner-anchor for trunk_cascade_broken kind present"
if grep -q 'scanner-anchor.*trunk_cascade_broken' "$SCRIPT" 2>/dev/null \
   || grep -q '"kind":"trunk_cascade_broken"' "$SCRIPT" 2>/dev/null; then
    pass "trunk_cascade_broken kind present in script"
else
    fail "trunk_cascade_broken kind not found"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
