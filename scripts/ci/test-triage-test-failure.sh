#!/usr/bin/env bash
# test-triage-test-failure.sh — CREDIBLE-013 CI gate
#
# Verifies that triage-test-failure.sh correctly classifies cargo-test
# output into pass/real/flake/known-bug/unknown categories and emits the
# right exit codes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TRIAGE="$REPO_ROOT/scripts/ci/triage-test-failure.sh"

[[ -f "$TRIAGE" ]] || { echo "FAIL: triage-test-failure.sh not found at $TRIAGE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

check() {
    local name="$1" expected_class="$2" expected_exit="$3" input="$4"
    local log="$TMP/test-$name.log"
    printf '%s' "$input" > "$log"
    actual_exit=0
    actual_out="$(CHUMP_TRIAGE_ANNOTATE=0 bash "$TRIAGE" --log "$log" 2>/dev/null)" || actual_exit=$?
    actual_class="$(echo "$actual_out" | sed -E 's/^triage: ([a-z-]+).*/\1/')"
    if [[ "$actual_class" == "$expected_class" && "$actual_exit" -eq "$expected_exit" ]]; then
        echo "[OK] $name: class=$actual_class exit=$actual_exit"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL $name: expected class=$expected_class exit=$expected_exit, got class=$actual_class exit=$actual_exit"
        echo "  output: $actual_out"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ── Test 1: clean pass ────────────────────────────────────────────────────
check "pass" "pass" "0" "test foo::bar ... ok
test baz::qux ... ok
test result: ok. 2 passed; 0 failed"

# ── Test 2: real failure (test not in catalog) ────────────────────────────
check "real" "real" "1" "test module::tests::foo_bar ... FAILED
test result: FAILED. 0 passed; 1 failed"

# ── Test 3: unknown (compilation error, no FAILED lines) ─────────────────
check "unknown" "unknown" "1" "error[E0502]: cannot borrow 'x' as mutable
error: aborting due to previous error"

# ── Test 4: flake — all failures in catalog ───────────────────────────────
# Write a temp catalog with one known flake.
CAT_FILE="$TMP/KNOWN_FLAKES.yaml"
cat > "$CAT_FILE" <<'YAML'
schema_version: 1
last_audit: 2026-05-10
flakes:
  - test: "integration::tests::test_claim_race"
    reason: "races under high load"
    tracking_gap: INFRA-999
    added: 2026-05-01
    last_observed: 2026-05-09
    max_reruns: 1
YAML
CATALOG="$CAT_FILE" check "flake" "flake" "0" "test integration::tests::test_claim_race ... FAILED
test result: FAILED. 0 passed; 1 failed"

# ── Test 5: known-bug — some in catalog, some not ────────────────────────
CATALOG="$CAT_FILE" check "known-bug" "known-bug" "1" "test integration::tests::test_claim_race ... FAILED
test module::tests::real_bug ... FAILED
test result: FAILED. 0 passed; 2 failed"

# ── Test 6: --log flag works ──────────────────────────────────────────────
LOG_IN="$TMP/input.log"
echo "test foo::bar ... ok" > "$LOG_IN"
out="$(CHUMP_TRIAGE_ANNOTATE=0 bash "$TRIAGE" --log "$LOG_IN" 2>/dev/null)"
if echo "$out" | grep -q "^triage: pass"; then
    echo "[OK] test-6 (--log flag): $out"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-6 (--log flag): $out"
    FAIL=$(( FAIL + 1 ))
fi

# ── Test 7: stdin mode works ──────────────────────────────────────────────
out="$(echo "test foo ... ok" | CHUMP_TRIAGE_ANNOTATE=0 bash "$TRIAGE" 2>/dev/null)"
if echo "$out" | grep -q "^triage: pass"; then
    echo "[OK] test-7 (stdin mode): $out"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-7 (stdin mode): $out"
    FAIL=$(( FAIL + 1 ))
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "PASS: test-triage-test-failure (${PASS}/${PASS} cases verified)"
    exit 0
else
    echo "FAIL: ${FAIL} case(s) failed (${PASS} passed)"
    exit 1
fi
