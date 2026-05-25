#!/usr/bin/env bash
# test-pr-terminal-state.sh — INFRA-1981 regression test (M3 critique fix).
#
# Verifies pr_terminal_state() correctly distinguishes MERGED vs.
# GENUINELY_CLOSED vs. OPEN, including the transient-CLOSED-then-MERGED
# flash that bit PRs #2561 and #2566.
#
# Strategy: override `gh` with a shell function that returns canned JSON
# per call. Source the lib, call pr_terminal_state, assert output.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/dispatch/lib/pr-terminal-state.sh"

if [[ ! -f "$LIB" ]]; then
    echo "[FAIL] lib not found at $LIB"
    exit 1
fi

# shellcheck source=/dev/null
source "$LIB"

# Speed up re-query for tests (default 10s → 1s for test)
export CHUMP_PR_TERMINAL_REQUERY_DELAY_S=1

assert_eq() {
    local label="$1" expected="$2" got="$3"
    if [[ "$expected" == "$got" ]]; then
        echo "[PASS] $label (got=$got)"
    else
        echo "[FAIL] $label: expected='$expected' got='$got'"
        exit 1
    fi
}

# ---- Test 1: state=OPEN, mergedAt=null → OPEN ----
gh() { echo '{"state":"OPEN","mergedAt":null}'; }
export -f gh
out=$(pr_terminal_state 1 --quick)
assert_eq "Test 1 OPEN" "OPEN" "$out"

# ---- Test 2: state=MERGED, mergedAt=<ts> → MERGED (the happy path) ----
gh() { echo '{"state":"MERGED","mergedAt":"2026-05-25T15:45:15Z"}'; }
export -f gh
out=$(pr_terminal_state 2 --quick)
assert_eq "Test 2 MERGED happy path" "MERGED" "$out"

# ---- Test 3: state=CLOSED, mergedAt=<ts> → MERGED (the M3 bug case!) ----
# This is the exact pattern that bit #2566 — gh returned state=CLOSED
# but mergedAt was already populated. The fix: mergedAt != null wins.
gh() { echo '{"state":"CLOSED","mergedAt":"2026-05-25T15:45:15Z"}'; }
export -f gh
out=$(pr_terminal_state 3 --quick)
assert_eq "Test 3 M3 bug: CLOSED state but mergedAt populated → MERGED" "MERGED" "$out"

# ---- Test 4: state=CLOSED, mergedAt=null, --quick → GENUINELY_CLOSED ----
gh() { echo '{"state":"CLOSED","mergedAt":null}'; }
export -f gh
out=$(pr_terminal_state 4 --quick)
assert_eq "Test 4 genuine CLOSED in --quick mode" "GENUINELY_CLOSED" "$out"

# ---- Test 5: gh fails (e.g. rate limit) → UNKNOWN ----
gh() { return 1; }
export -f gh
out=$(pr_terminal_state 5 --quick)
assert_eq "Test 5 gh failure → UNKNOWN" "UNKNOWN" "$out"

# ---- Test 6: full-mode (non-quick) — transient CLOSED then MERGED ----
# Counter-based gh: first call CLOSED+null, second call CLOSED+timestamp.
# This exercises the re-query path; the fix should recover and return MERGED.
TMP_CTR=$(mktemp)
echo 0 > "$TMP_CTR"
gh() {
    local n
    n=$(cat "$TMP_CTR")
    n=$((n + 1))
    echo "$n" > "$TMP_CTR"
    if [[ "$n" -eq 1 ]]; then
        echo '{"state":"CLOSED","mergedAt":null}'
    else
        echo '{"state":"CLOSED","mergedAt":"2026-05-25T15:45:15Z"}'
    fi
}
export -f gh
out=$(pr_terminal_state 6)
rm -f "$TMP_CTR"
assert_eq "Test 6 transient CLOSED→MERGED (re-query path)" "MERGED" "$out"

# ---- Test 7: full-mode — genuine CLOSED stays CLOSED ----
TMP_CTR=$(mktemp)
echo 0 > "$TMP_CTR"
gh() {
    local n
    n=$(cat "$TMP_CTR")
    n=$((n + 1))
    echo "$n" > "$TMP_CTR"
    echo '{"state":"CLOSED","mergedAt":null}'
}
export -f gh
out=$(pr_terminal_state 7)
rm -f "$TMP_CTR"
assert_eq "Test 7 genuine CLOSED stays CLOSED after re-query" "GENUINELY_CLOSED" "$out"

echo
echo "[OK] all 7 INFRA-1981 pr-terminal-state cases passed"
