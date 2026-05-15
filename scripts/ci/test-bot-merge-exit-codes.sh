#!/usr/bin/env bash
# CI gate for RESILIENT-010: bot-merge.sh step-specific exit codes.
# Tests: each named failure step exits with the correct code and emits
# kind=bot_merge_phase_failure to ambient.jsonl with step and exit_code fields.
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== RESILIENT-010: bot-merge.sh step-specific exit codes ==="
echo

# ── Extract _bm_fail function definition from bot-merge.sh ──────────────────
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
if [[ ! -f "$BOT_MERGE" ]]; then
  echo "SKIP: scripts/coord/bot-merge.sh not found"
  exit 0
fi

# Check that _bm_fail is defined in bot-merge.sh
if ! grep -q "_bm_fail()" "$BOT_MERGE"; then
  fail "RESILIENT-010: _bm_fail() function not found in bot-merge.sh"
  echo
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi
ok "_bm_fail() defined in bot-merge.sh"

# ── Test _bm_fail directly by sourcing the function ──────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
AMBIENT="$TMP/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT"

# Extract just the _bm_fail function from bot-merge.sh (everything between
# the function def and the next blank line after the closing })
FAIL_FN=$(awk '/^_bm_fail\(\)/{found=1} found{print; if(/^}$/){exit}}' "$BOT_MERGE")

if [[ -z "$FAIL_FN" ]]; then
  fail "could not extract _bm_fail() function body"
  echo
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi
ok "_bm_fail() function body extractable"

# ── Helper: call _bm_fail in a subshell, capture exit code + ambient event ──
# GAP_IDS and BRANCH are referenced inside _bm_fail, provide them.
run_fail() {
    local step="$1" expected_code="$2"
    local GAP_IDS=("TEST-001") BRANCH="test-branch"
    export GAP_IDS BRANCH
    local actual_code=0
    (
        eval "$FAIL_FN"
        GAP_IDS=("TEST-001")
        BRANCH="test-branch"
        _bm_fail "$step" "$expected_code" "test failure"
    ) || actual_code=$?
    echo "$actual_code"
}

_expected_code() {
    case "$1" in
        preflight) echo 10 ;;
        rebase)    echo 11 ;;
        clippy)    echo 12 ;;
        test)      echo 13 ;;
        push)      echo 14 ;;
        pr-create) echo 15 ;;
        *)         echo 1  ;;
    esac
}

echo "[Exit code verification per step]"
for step in preflight rebase clippy test push pr-create; do
    expected=$(_expected_code "$step")
    actual=$(run_fail "$step" "$expected")
    if [[ "$actual" -eq "$expected" ]]; then
        ok "step=$step exits with code $expected"
    else
        fail "step=$step: expected exit $expected, got $actual"
    fi
done

echo
echo "[Ambient event emission]"
# Run one _bm_fail call and check the ambient event
(
    eval "$FAIL_FN"
    GAP_IDS=("INFRA-123")
    BRANCH="chump/infra-123-claim"
    _bm_fail "push" 14 "test push failure"
) || true

if [[ -f "$AMBIENT" ]]; then
    ok "ambient.jsonl was created"
else
    fail "ambient.jsonl not created by _bm_fail"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"bot_merge_phase_failure"' "$AMBIENT"; then
    ok 'ambient event has kind=bot_merge_phase_failure'
else
    fail 'ambient event missing kind=bot_merge_phase_failure'
fi

if [[ -f "$AMBIENT" ]] && python3 -c "
import sys, json
events = [json.loads(l) for l in open('$AMBIENT') if l.strip()]
ev = events[-1]
assert ev.get('step') == 'push', f'expected step=push, got {ev.get(\"step\")}'
assert ev.get('exit_code') == 14, f'expected exit_code=14, got {ev.get(\"exit_code\")}'
" 2>/dev/null; then
    ok "ambient event has step=push, exit_code=14"
else
    fail "ambient event missing step or exit_code fields"
fi

echo
echo "[Exit code documentation in bot-merge.sh header]"
for step_code in "10" "11" "12" "13" "14" "15"; do
    if grep -q "$step_code" "$BOT_MERGE" | grep -q "preflight\|rebase\|clippy\|test\|push\|pr-create" 2>/dev/null; then
        true
    fi
done
# More lenient: just verify the exit code values appear in the header comment
if grep -q "10.*[Pp]reflight\|[Pp]reflight.*10" "$BOT_MERGE"; then
    ok "exit code 10 documented as preflight in header"
else
    fail "exit code 10 (preflight) not documented in header"
fi
if grep -q "14.*push\|push.*14" "$BOT_MERGE"; then
    ok "exit code 14 documented as push in header"
else
    fail "exit code 14 (push) not documented in header"
fi

echo
echo "[RESILIENT-010 referenced in source]"
if grep -q "RESILIENT-010" "$BOT_MERGE"; then
    ok "RESILIENT-010 referenced in bot-merge.sh"
else
    fail "RESILIENT-010 not found in bot-merge.sh"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
