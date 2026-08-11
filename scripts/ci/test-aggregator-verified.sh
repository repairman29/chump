#!/usr/bin/env bash
# test-aggregator-verified.sh — CREDIBLE-269
#
# Proves the decision logic in scripts/ci/aggregator-verified.sh matches the
# classification table in docs/design/CI_VERIFIED_AGGREGATOR.md §2.2-2.3:
#   - all lanes success                       -> PASS  (exit 0)
#   - any lane failure                        -> FAIL  (exit 1)
#   - real skipped, no stub declared          -> PASS  (exit 0)
#   - real skipped, stub success              -> PASS  (exit 0)
#   - real skipped, stub also skipped         -> FAIL  (exit 1, missing-stub bug)
#   - any lane in_progress, none failed       -> PENDING (exit 2)
#   - a failure alongside an in_progress lane -> FAIL wins (exit 1)
#
# Run locally:
#   bash scripts/ci/test-aggregator-verified.sh
#
# Exits non-zero on any assertion failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGG="$REPO_ROOT/scripts/ci/aggregator-verified.sh"
TMP_AMBIENT="$(mktemp -d)/ambient.jsonl"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

[[ -x "$AGG" ]] || { echo "FATAL: $AGG not found or not executable"; exit 2; }

run_agg() {
    # runs aggregator, captures exit code into $LAST_EXIT, stdout into $LAST_OUT
    set +e
    LAST_OUT="$(bash "$AGG" --pr 1 --sha deadbeef --ambient-log "$TMP_AMBIENT" "$@" 2>&1)"
    LAST_EXIT=$?
    set -e
}

echo "=== CREDIBLE-269 aggregator-verified.sh decision-logic guard ==="
echo

# ── Case 1: all lanes success -> PASS, exit 0 ───────────────────────────────
run_agg --lane "clippy=success" --lane "cargo-test=success" --lane "fast-checks=success"
if [[ "$LAST_EXIT" -eq 0 ]] && grep -q "VERDICT=PASS" <<<"$LAST_OUT"; then
    ok "all-success -> PASS (exit 0)"
else
    fail "all-success expected PASS/exit0, got exit=$LAST_EXIT out=$LAST_OUT"
fi

# ── Case 2: one failure -> FAIL, exit 1 ─────────────────────────────────────
run_agg --lane "clippy=success" --lane "cargo-test=failure"
if [[ "$LAST_EXIT" -eq 1 ]] && grep -q "VERDICT=FAIL" <<<"$LAST_OUT"; then
    ok "one-failure -> FAIL (exit 1)"
else
    fail "one-failure expected FAIL/exit1, got exit=$LAST_EXIT out=$LAST_OUT"
fi

# ── Case 3: real skipped, no stub declared -> PASS ──────────────────────────
run_agg --lane "e2e-pwa=skipped"
if [[ "$LAST_EXIT" -eq 0 ]] && grep -q "VERDICT=PASS" <<<"$LAST_OUT"; then
    ok "skipped-no-stub -> PASS (exit 0)"
else
    fail "skipped-no-stub expected PASS/exit0, got exit=$LAST_EXIT out=$LAST_OUT"
fi

# ── Case 4: real skipped, stub success (path-filter lane) -> PASS ──────────
run_agg --lane "audit=skipped,success"
if [[ "$LAST_EXIT" -eq 0 ]] && grep -q "VERDICT=PASS" <<<"$LAST_OUT"; then
    ok "skipped+stub-success -> PASS (exit 0)"
else
    fail "skipped+stub-success expected PASS/exit0, got exit=$LAST_EXIT out=$LAST_OUT"
fi

# ── Case 5: real skipped, stub also skipped -> FAIL (missing-stub bug) ─────
run_agg --lane "audit=skipped,skipped"
if [[ "$LAST_EXIT" -eq 1 ]] && grep -q "VERDICT=FAIL" <<<"$LAST_OUT"; then
    ok "skipped+stub-skipped -> FAIL (exit 1, missing-stub config bug)"
else
    fail "skipped+stub-skipped expected FAIL/exit1, got exit=$LAST_EXIT out=$LAST_OUT"
fi

# ── Case 6: one lane in_progress, none failed -> PENDING, exit 2 ───────────
run_agg --lane "clippy=success" --lane "cargo-test=in_progress"
if [[ "$LAST_EXIT" -eq 2 ]] && grep -q "VERDICT=PENDING" <<<"$LAST_OUT"; then
    ok "in-progress-no-failure -> PENDING (exit 2)"
else
    fail "in-progress-no-failure expected PENDING/exit2, got exit=$LAST_EXIT out=$LAST_OUT"
fi

# ── Case 7: failure + in_progress -> FAIL wins, exit 1 ──────────────────────
run_agg --lane "clippy=failure" --lane "cargo-test=in_progress"
if [[ "$LAST_EXIT" -eq 1 ]] && grep -q "VERDICT=FAIL" <<<"$LAST_OUT"; then
    ok "failure+in-progress -> FAIL wins (exit 1)"
else
    fail "failure+in-progress expected FAIL/exit1, got exit=$LAST_EXIT out=$LAST_OUT"
fi

# ── Case 8: ambient event was actually written ──────────────────────────────
if [[ -f "$TMP_AMBIENT" ]] && grep -q '"kind": "verified_aggregator_decision"' "$TMP_AMBIENT"; then
    ok "ambient emit: kind=verified_aggregator_decision written"
else
    fail "ambient log missing verified_aggregator_decision event (file=$TMP_AMBIENT)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
