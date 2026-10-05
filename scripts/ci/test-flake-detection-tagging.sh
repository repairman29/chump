#!/usr/bin/env bash
# test-flake-detection-tagging.sh — META-141 smoke test.
#
# Exercises the flake-tagging functions added to
# scripts/coord/pr-shepherd-daemon.sh directly (not via cmd_tick, which needs
# a live PR queue) against a scratch sqlite db.
#
# Usage:
#   scripts/ci/test-flake-detection-tagging.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_FLAKE_DB="$TMP/flake.db"

# Load just the flake helper functions (avoid running the daemon's top-level
# gh/network-touching sourced libs and the tick/dispatch machinery).
FLAKE_FUNCS="$(sed -n '/^_sql_escape() {/,/^cmd_query_flakes() {/p' "$DAEMON" | sed '$d')"
# shellcheck disable=SC1090
eval "REPO_ROOT=\"$REPO_ROOT\"; FLAKE_DB=\"$CHUMP_FLAKE_DB\"; $FLAKE_FUNCS"

echo "=== META-141 flake-detection-tagging smoke test ==="
echo

# 1. Same fingerprint x2 must NOT be tagged a flake yet (AC #3).
_flake_track "test-A" "fp-1"
_flake_track "test-A" "fp-1"
row=$(sqlite3 "$CHUMP_FLAKE_DB" "SELECT COUNT(*) FROM flakes WHERE test_name='test-A';")
if [[ "$row" -eq 0 ]]; then
    ok "2 consecutive identical fingerprints do not tag a flake"
else
    fail "test-A tagged as flake after only 2 identical-fingerprint runs"
fi

# 2. Same fingerprint x3 (consecutive) MUST be tagged a flake with status='flake' (AC #1).
_flake_track "test-A" "fp-1"
status=$(sqlite3 "$CHUMP_FLAKE_DB" "SELECT status FROM flakes WHERE test_name='test-A';" 2>/dev/null || echo "")
if [[ "$status" == "flake" ]]; then
    ok "3 consecutive identical fingerprints tags test-A as flake"
else
    fail "test-A not tagged as flake after 3 identical-fingerprint runs (status='$status')"
fi

# 3. A differing fingerprint resets the streak — 2 then a different one then 2 more must not tag.
_flake_track "test-B" "fp-x"
_flake_track "test-B" "fp-x"
_flake_track "test-B" "fp-y"
_flake_track "test-B" "fp-y"
row=$(sqlite3 "$CHUMP_FLAKE_DB" "SELECT COUNT(*) FROM flakes WHERE test_name='test-B';")
if [[ "$row" -eq 0 ]]; then
    ok "a differing fingerprint resets the consecutive streak"
else
    fail "test-B incorrectly tagged as flake despite a broken streak"
fi

# 4. query-flakes subcommand lists tagged flakes with test name + fingerprint (AC #2).
out=$(CHUMP_FLAKE_DB="$CHUMP_FLAKE_DB" "$DAEMON" query-flakes)
if echo "$out" | grep -qP 'test-A\tfp-1'; then
    ok "query-flakes prints test name and fingerprint for tagged flakes"
else
    fail "query-flakes output missing test-A/fp-1 row: $out"
fi

# 5. _flake_fingerprint uses extract_job from test-half-impl-detector.sh (AC #4).
fp1=$(_flake_fingerprint "half-impl-detector")
fp2=$(_flake_fingerprint "half-impl-detector")
unmatched_fp=$(_flake_fingerprint "definitely-not-a-real-job-xyz")
if [[ -n "$fp1" && "$fp1" == "$fp2" && "$fp1" != "$unmatched_fp" ]]; then
    ok "fingerprint is deterministic and job-section-derived (via extract_job)"
else
    fail "fingerprint not deterministic/derived as expected (fp1=$fp1 fp2=$fp2 unmatched=$unmatched_fp)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
