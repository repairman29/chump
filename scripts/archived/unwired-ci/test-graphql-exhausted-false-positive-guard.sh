#!/usr/bin/env bash
# scripts/ci/test-graphql-exhausted-false-positive-guard.sh — INFRA-2484
#
# Regression test: _chump_gh_maybe_emit_exhausted must reject negative gql_rem
# values (sentinel from failed rate_limit call), and chump_gh_record must skip
# the exhausted-emit when rc != 0.
#
# AC5 acceptance criteria:
#   Test 1: _chump_gh_maybe_emit_exhausted -1 0      → NO graphql_exhausted line
#   Test 2: _chump_gh_maybe_emit_exhausted -999 ...  → NO emit
#   Test 3: _chump_gh_maybe_emit_exhausted 50 0      → EXACTLY ONE graphql_exhausted
#   Test 4: chump_gh_record "test-api" 100 1 "test"  (rc=1) → ZERO graphql_exhausted
#   Test 5: chump_gh_record "test-api" 100 0 "test"  (rc=0) → no crash
#
# Exit non-zero on any assertion failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: cannot find $LIB" >&2
    exit 1
fi

PASS=0
FAIL=0
_fail() { echo "FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }
_pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }

# ── Setup: shared temp dir used as ambient root ───────────────────────────────
TMP_DIR="$(mktemp -d)"
TMP_AMBIENT="$TMP_DIR/ambient.jsonl"
trap 'rm -rf "$TMP_DIR"' EXIT

# Load the lib with no PATH shim injection and silent mode on, so sourcing
# it here doesn't try to spin up gh or write to the real ambient stream.
export CHUMP_GH_NO_PATH_INJECT=1
export CHUMP_GH_SILENT=1
export CHUMP_AMBIENT_OVERRIDE="$TMP_AMBIENT"

# We need the debounce flag file inside TMP_DIR too so tests don't cross-contaminate.
# The flag path is derived from dirname($ambient) inside the function.
# Since CHUMP_AMBIENT_OVERRIDE points to $TMP_DIR/ambient.jsonl, dirname = $TMP_DIR.

# Source the lib in a subshell context by declaring functions inline.
# We source it once; all tests run in the same shell so state is reset manually.
# shellcheck source=/dev/null
source "$LIB"

_reset_ambient() {
    : > "$TMP_AMBIENT"
    rm -f "$TMP_DIR/.graphql-exhausted-since"
}

count_exhausted() {
    grep -c '"kind":"graphql_exhausted"' "$TMP_AMBIENT" 2>/dev/null || true
}

# ── Test 1: negative sentinel -1 must NOT emit ───────────────────────────────
_reset_ambient
_chump_gh_maybe_emit_exhausted "-1" "0" "$TMP_AMBIENT"
n="$(count_exhausted)"
if [[ "$n" -eq 0 ]]; then
    _pass "T1: gql_rem=-1 produced 0 graphql_exhausted events (got $n)"
else
    _fail "T1: gql_rem=-1 should produce 0 graphql_exhausted events, got $n"
fi

# ── Test 2: large negative sentinel must NOT emit ────────────────────────────
_reset_ambient
_chump_gh_maybe_emit_exhausted "-999" "1780500000" "$TMP_AMBIENT"
n="$(count_exhausted)"
if [[ "$n" -eq 0 ]]; then
    _pass "T2: gql_rem=-999 produced 0 graphql_exhausted events (got $n)"
else
    _fail "T2: gql_rem=-999 should produce 0 graphql_exhausted events, got $n"
fi

# ── Test 3: positive value under threshold MUST emit exactly once ─────────────
# Use threshold=100 (default). 50 < 100 → should emit.
_reset_ambient
export CHUMP_GH_EXHAUSTED_THRESHOLD=100
_chump_gh_maybe_emit_exhausted "50" "0" "$TMP_AMBIENT"
n="$(count_exhausted)"
if [[ "$n" -eq 1 ]]; then
    _pass "T3: gql_rem=50 under threshold=100 emitted exactly 1 graphql_exhausted"
else
    _fail "T3: gql_rem=50 under threshold=100 should emit 1 graphql_exhausted, got $n"
fi

# ── Test 4: chump_gh_record with rc=1 must emit ZERO graphql_exhausted ───────
# Even if gql_rem would otherwise be under threshold, the rc gate must block it.
# We stub _chump_gh_rate_remaining to return "50 50 0" (under threshold)
# to prove the rc gate fires before the emit path.
# Note: unset CHUMP_GH_SILENT for chump_gh_record tests — SILENT=1 causes the
# function to return before reaching any emit path, which would mask T4b.
_reset_ambient
_chump_gh_rate_remaining() { printf '%s' "50 50 0"; }
export -f _chump_gh_rate_remaining 2>/dev/null || true

CHUMP_GH_SILENT=0 chump_gh_record "test-api" "100" "1" "test-script"
n="$(count_exhausted)"
if [[ "$n" -eq 0 ]]; then
    _pass "T4: chump_gh_record rc=1 produced 0 graphql_exhausted events"
else
    _fail "T4: chump_gh_record rc=1 should produce 0 graphql_exhausted events, got $n"
fi

# Also verify the breadcrumb was written.
skipped="$(grep -c '"kind":"gh_recording_skipped_rc_nonzero"' "$TMP_AMBIENT" 2>/dev/null || true)"
if [[ "$skipped" -ge 1 ]]; then
    _pass "T4b: gh_recording_skipped_rc_nonzero breadcrumb emitted ($skipped)"
else
    _fail "T4b: gh_recording_skipped_rc_nonzero breadcrumb missing"
fi

# ── Test 5: chump_gh_record with rc=0 must not crash ─────────────────────────
_reset_ambient
# Keep stubbed _chump_gh_rate_remaining returning "50 50 0" (under threshold).
# rc=0 path: may emit graphql_exhausted (that's fine) but must not crash.
set +e
CHUMP_GH_SILENT=0 chump_gh_record "test-api" "100" "0" "test-script"
rc5=$?
set -e
if [[ "$rc5" -eq 0 ]]; then
    _pass "T5: chump_gh_record rc=0 exited 0 (no crash)"
else
    _fail "T5: chump_gh_record rc=0 crashed with exit $rc5"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
