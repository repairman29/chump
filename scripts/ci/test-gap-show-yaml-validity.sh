#!/usr/bin/env bash
# test-gap-show-yaml-validity.sh — INFRA-1285: verify chump gap show emits valid YAML
# for gaps with colons in title and numbered-AC format.
#
# AC:
#   - titles with colons are quoted
#   - acceptance_criteria is a YAML list, not a numbered mapping
#   - output parses via yaml.safe_load
#
# Run: bash scripts/ci/test-gap-show-yaml-validity.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { printf '[PASS] %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

CHUMP="${CHUMP:-${REPO_ROOT}/target/debug/chump}"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || true)"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "[SKIP] chump binary not found — skipping test-gap-show-yaml-validity.sh"
    exit 0
fi

# ── Pick a gap with a colon in its title ─────────────────────────────────────
# INFRA-1285 itself is a good fixture (filed with colon in title).
FIXTURE_ID="INFRA-1285"
OUTPUT="$("$CHUMP" gap show "$FIXTURE_ID" 2>/dev/null || true)"

if [[ -z "$OUTPUT" ]]; then
    echo "[SKIP] gap $FIXTURE_ID not found in state.db — skipping"
    exit 0
fi

# ── Test 1: output parses as valid YAML ──────────────────────────────────────
if echo "$OUTPUT" | python3 -c "import yaml,sys; yaml.safe_load(sys.stdin.read())" 2>/dev/null; then
    pass "Test 1: $FIXTURE_ID output is valid YAML"
else
    fail "Test 1: $FIXTURE_ID output is NOT valid YAML"
    echo "--- output ---"
    echo "$OUTPUT"
    echo "---"
fi

# ── Test 2: title field is quoted (contains double-quote chars) ───────────────
TITLE_LINE="$(echo "$OUTPUT" | grep "^  title:")"
if echo "$TITLE_LINE" | grep -q '"'; then
    pass "Test 2: title is quoted (contains colon)"
else
    fail "Test 2: title with colon is NOT quoted: $TITLE_LINE"
fi

# ── Test 3: AC is a YAML list (items start with "    - ") ────────────────────
if echo "$OUTPUT" | grep -q "^    - "; then
    pass "Test 3: acceptance_criteria uses list syntax (- item)"
else
    # Check if AC section exists at all
    if echo "$OUTPUT" | grep -q "acceptance_criteria:"; then
        fail "Test 3: acceptance_criteria present but NOT a list (numbered mapping?)"
        echo "$OUTPUT" | grep -A5 "acceptance_criteria:"
    else
        pass "Test 3: no acceptance_criteria section (gap has none)"
    fi
fi

# ── Test 4: AC items are not numbered (no "    N. " pattern in the AC block) ──
# Only check lines between "acceptance_criteria:" and the next top-level key.
AC_BLOCK="$(echo "$OUTPUT" | awk '/^  acceptance_criteria:/{p=1;next} p && /^  [a-z]/{p=0} p{print}')"
if echo "$AC_BLOCK" | grep -qE "^    [0-9]+\. "; then
    fail "Test 4: AC still uses numbered mapping format (1. 2. 3.) in AC block"
else
    pass "Test 4: AC block does not use numbered mapping format"
fi

# ── Test 5: AC list parsed by Python is actually a list ──────────────────────
AC_TYPE="$(echo "$OUTPUT" | python3 -c "
import yaml, sys
data = yaml.safe_load(sys.stdin.read())
if not data or not isinstance(data, list):
    print('not_a_list')
    raise SystemExit(1)
gap = data[0]
ac = gap.get('acceptance_criteria', None)
if ac is None:
    print('missing')
elif isinstance(ac, list):
    print('list')
else:
    print(type(ac).__name__)
" 2>/dev/null || echo "parse_error")"

if [[ "$AC_TYPE" == "list" ]]; then
    pass "Test 5: acceptance_criteria parsed as Python list"
elif [[ "$AC_TYPE" == "missing" ]]; then
    pass "Test 5: no acceptance_criteria (gap has none)"
else
    fail "Test 5: acceptance_criteria parsed as $AC_TYPE (expected list)"
fi

# ── Test 6: run all open gaps through yaml.safe_load, count failures ──────────
TOTAL=0
INVALID=0
while IFS= read -r gap_id; do
    [[ -z "$gap_id" ]] && continue
    gap_out="$("$CHUMP" gap show "$gap_id" 2>/dev/null || true)"
    [[ -z "$gap_out" ]] && continue
    TOTAL=$((TOTAL+1))
    if ! echo "$gap_out" | python3 -c "import yaml,sys; yaml.safe_load(sys.stdin.read())" 2>/dev/null; then
        INVALID=$((INVALID+1))
        fail "  gap $gap_id: invalid YAML output"
    fi
done < <("$CHUMP" gap list --status open 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -50)

if [[ $INVALID -eq 0 && $TOTAL -gt 0 ]]; then
    pass "Test 6: all $TOTAL sampled gaps emit valid YAML"
elif [[ $TOTAL -eq 0 ]]; then
    pass "Test 6: no gaps to validate (state.db empty?)"
else
    fail "Test 6: $INVALID/$TOTAL gaps emit invalid YAML"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "INFRA-1285: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
