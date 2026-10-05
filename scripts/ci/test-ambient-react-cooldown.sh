#!/usr/bin/env bash
# test-ambient-react-cooldown.sh — RESILIENT-036
#
# Regression test for the --tick-preamble per-role react-cooldown: without
# it, curator A broadcasts FEEDBACK, B reacts + broadcasts, A reacts, and the
# wire storms forever on the same corr_id. Verifies:
#   (1) First tick for role A surfaces a synth FEEDBACK with corr_id X.
#   (2) Second tick within CHUMP_REACT_COOLDOWN_M does NOT surface corr_id X
#       again (silently suppressed), even though the cursor already advanced
#       past it on tick 1 -- so we replay via a fresh new event carrying the
#       same corr_id to prove the *sentinel*, not just the cursor, is doing
#       the deduping.
#   (3) A different corr_id Y is unaffected by X's cooldown.
#   (4) With CHUMP_REACT_COOLDOWN_M=0 (expired immediately), a re-surfaced
#       corr_id is NOT suppressed.

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INJECT="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"
[[ -x "$INJECT" ]] || { echo "FATAL: $INJECT not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --tick-preamble resolves paths off `git rev-parse --show-toplevel`, so we
# need a real (throwaway) git repo to isolate the test from the real
# .chump-locks/ directory.
git -C "$TMP" init -q
mkdir -p "$TMP/.chump-locks"
AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl"
ROLE="test-role"

emit() {
    # $1=corr_id $2=event $3=to
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"%s","session":"peer-session","to":"%s","corr_id":"%s","reason":"synthetic test event"}\n' \
        "$ts" "$2" "$3" "$1" >> "$AMBIENT_LOG"
}

tick() {
    ( cd "$TMP" && CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$INJECT" --tick-preamble "$ROLE" )
}

echo "=== ambient react-cooldown (RESILIENT-036) ==="

# ── 1. First-react: corr_id X surfaces ────────────────────────────────────────
echo "--- Test 1: first tick surfaces corr_id X ---"
emit "X" "FEEDBACK" "fleet-wide"
OUT1="$(tick)"
if grep -q "synthetic test event" <<<"$OUT1"; then
    ok "digest contains corr_id X on first tick"
else
    fail "digest missing corr_id X on first tick; got: $OUT1"
fi

SENTINEL_DIR="$TMP/.chump-locks/${ROLE}-reacted"
if [[ -f "$SENTINEL_DIR/X.sentinel" ]]; then
    ok "sentinel file created for corr_id X"
else
    fail "sentinel file NOT created for corr_id X"
fi

# ── 2. Second react within cooldown: re-surfaced X is suppressed ─────────────
echo "--- Test 2: second tick within cooldown suppresses corr_id X ---"
emit "X" "FEEDBACK" "fleet-wide"
OUT2="$(tick)"
if [[ -z "$OUT2" ]]; then
    ok "digest empty on second tick (corr_id X suppressed)"
else
    fail "digest should be empty (suppressed X); got: $OUT2"
fi

# ── 3. Different corr_id Y is unaffected ──────────────────────────────────────
echo "--- Test 3: unrelated corr_id Y still surfaces ---"
emit "Y" "FEEDBACK" "fleet-wide"
OUT3="$(tick)"
if grep -q "synthetic test event" <<<"$OUT3"; then
    ok "digest surfaces corr_id Y (not cooled down)"
else
    fail "digest missing corr_id Y; got: $OUT3"
fi

# ── 4. Cooldown expiry: CHUMP_REACT_COOLDOWN_M=0 lets X re-surface ───────────
echo "--- Test 4: CHUMP_REACT_COOLDOWN_M=0 allows immediate re-react ---"
emit "X" "FEEDBACK" "fleet-wide"
OUT4="$( cd "$TMP" && CHUMP_AMBIENT_LOG="$AMBIENT_LOG" CHUMP_REACT_COOLDOWN_M=0 "$INJECT" --tick-preamble "$ROLE" )"
if grep -q "synthetic test event" <<<"$OUT4"; then
    ok "corr_id X re-surfaces once cooldown window is 0"
else
    fail "corr_id X should re-surface with cooldown=0; got: $OUT4"
fi

# ── Report ───────────────────────────────────────────────────────────────────
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
