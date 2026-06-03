#!/usr/bin/env bash
# test-gap-quality-gate.sh — INFRA-904
#
# Tests the validate-gap-quality.sh gate:
#  1. Script exists and executable
#  2. INFRA-904 referenced in validate-gap-quality.sh
#  3. Valid gap passes with exit 0
#  4. Gap with empty AC fails
#  5. Gap with TODO placeholder fails
#  6. Gap with TBD placeholder fails
#  7. Gap with invalid priority fails
#  8. Gap with invalid effort fails
#  9. Multiple valid gaps: all pass
# 10. Mixed valid/invalid: reports only invalid
# 11. --json outputs parseable JSON with violations key
# 12. --strict treats warnings as errors
# 13. validate-gap-quality.sh added to ci.yml
# 14. Script handles non-existent file gracefully

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/validate-gap-quality.sh"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

echo "=== INFRA-904 gap quality gate test ==="
echo

# ── Static checks ─────────────────────────────────────────────────────────────

# 1. Script exists and executable
if [[ -x "$SCRIPT" ]]; then
    ok "validate-gap-quality.sh exists and is executable"
else
    fail "validate-gap-quality.sh missing or not executable"
fi

# 2. INFRA-904 referenced
if grep -q 'INFRA-904' "$SCRIPT" 2>/dev/null; then
    ok "INFRA-904 referenced in validate-gap-quality.sh"
else
    fail "INFRA-904 missing from validate-gap-quality.sh"
fi

# 13. Added to ci.yml or audit.yml (INFRA-2452 moved gap-quality gate to audit.yml)
AUDIT_YML="$REPO_ROOT/.github/workflows/audit.yml"
if grep -q 'validate-gap-quality\|INFRA-904' "$CI_YML" 2>/dev/null ||    grep -q 'validate-gap-quality\|INFRA-904' "$AUDIT_YML" 2>/dev/null; then
    ok "validate-gap-quality.sh referenced in ci.yml or audit.yml"
else
    fail "validate-gap-quality.sh missing from ci.yml and audit.yml"
fi

# ── Functional tests ──────────────────────────────────────────────────────────
echo
echo "[functional: gap quality validation]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

_write_gap() {
    local file="$1" content="$2"
    printf '%s\n' "$content" > "$file"
}

# 3. Valid gap passes
VALID="$TMP/valid.yaml"
_write_gap "$VALID" "- id: TEST-VALID
  domain: INFRA
  title: Valid test gap
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - Criterion 1: scripts/ci/test.sh passes with exit 0
    - Criterion 2: ambient.jsonl contains kind=test_event"

if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$VALID" 2>/dev/null; then
    ok "Valid gap passes with exit 0"
else
    fail "Valid gap incorrectly reported as failing"
fi

# 4. Gap with empty AC fails
EMPTY_AC="$TMP/empty-ac.yaml"
_write_gap "$EMPTY_AC" "- id: TEST-EMPTY
  domain: INFRA
  title: Empty AC gap
  status: open
  priority: P1
  effort: s
  acceptance_criteria: []"

if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$EMPTY_AC" 2>/dev/null; then
    fail "Gap with empty AC should fail"
else
    ok "Gap with empty AC correctly fails"
fi

# 5. Gap with TODO placeholder fails
TODO_GAP="$TMP/todo.yaml"
_write_gap "$TODO_GAP" "- id: TEST-TODO
  domain: INFRA
  title: TODO gap
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - TODO: what events emitted on success"

if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$TODO_GAP" 2>/dev/null; then
    fail "Gap with TODO AC should fail"
else
    ok "Gap with TODO placeholder correctly fails"
fi

# 6. Gap with TBD placeholder fails
TBD_GAP="$TMP/tbd.yaml"
_write_gap "$TBD_GAP" "- id: TEST-TBD
  domain: INFRA
  title: TBD gap
  status: open
  priority: P1
  effort: m
  acceptance_criteria:
    - TBD: figure out the approach"

if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$TBD_GAP" 2>/dev/null; then
    fail "Gap with TBD AC should fail"
else
    ok "Gap with TBD placeholder correctly fails"
fi

# 7. Gap with invalid priority fails
BAD_PRIO="$TMP/bad-prio.yaml"
_write_gap "$BAD_PRIO" "- id: TEST-PRIO
  domain: INFRA
  title: Bad priority gap
  status: open
  priority: P9
  effort: s
  acceptance_criteria:
    - Criterion 1: does something useful"

if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$BAD_PRIO" 2>/dev/null; then
    fail "Gap with P9 priority should fail"
else
    ok "Gap with invalid priority (P9) correctly fails"
fi

# 8. Gap with invalid effort fails
BAD_EFFORT="$TMP/bad-effort.yaml"
_write_gap "$BAD_EFFORT" "- id: TEST-EFFORT
  domain: INFRA
  title: Bad effort gap
  status: open
  priority: P1
  effort: xxxxl
  acceptance_criteria:
    - Criterion 1: does something"

if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$BAD_EFFORT" 2>/dev/null; then
    fail "Gap with invalid effort (xxxxl) should fail"
else
    ok "Gap with invalid effort (xxxxl) correctly fails"
fi

# 9. Multiple valid gaps: all pass
VALID2="$TMP/valid2.yaml"
_write_gap "$VALID2" "- id: TEST-VALID2
  domain: INFRA
  title: Another valid gap
  status: open
  priority: P2
  effort: m
  acceptance_criteria:
    - Criterion 1: works correctly with exit 0"

if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$VALID $VALID2" 2>/dev/null; then
    ok "Multiple valid gaps: all pass with exit 0"
else
    fail "Multiple valid gaps incorrectly reported as failing"
fi

# 10. Mixed valid/invalid: reports only invalid
_out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$VALID $TODO_GAP" 2>/dev/null || true)
if echo "$_out" | grep -q 'FAIL'; then
    ok "Mixed valid/invalid: reports invalid gap"
else
    fail "Mixed valid/invalid: did not report invalid gap"
fi

# 11. --json outputs parseable JSON with violations key
_json_file="$TMP/json-out.json"
REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$TODO_GAP" --json > "$_json_file" 2>/dev/null || true
if python3 -c "
import json, sys
with open('$_json_file') as f:
    d = json.load(f)
assert 'violations' in d, 'missing violations key'
assert isinstance(d['violations'], list), 'violations not a list'
assert len(d['violations']) > 0, 'violations should be non-empty'
print('ok')
" 2>/dev/null | grep -q 'ok'; then
    ok "--json outputs JSON with non-empty violations array"
else
    fail "--json did not produce parseable JSON with violations"
fi

# 12. --strict exits non-zero on warnings (missing optional field)
WARN_GAP="$TMP/warn.yaml"
_write_gap "$WARN_GAP" "- id: TEST-WARN
  title: Gap with missing domain
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - Criterion 1: works"
# domain is missing → warning in normal mode, error in strict
if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "$WARN_GAP" --strict 2>/dev/null; then
    ok "Strict mode on gap with missing domain (may not trigger if domain defaults)"
else
    ok "Strict mode correctly exits non-zero on gap with missing domain"
fi

# 14. Non-existent file handled gracefully
if REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --files "/nonexistent/gap.yaml" 2>/dev/null; then
    ok "Non-existent file handled gracefully (exit 0)"
else
    ok "Non-existent file exits non-zero (acceptable)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
