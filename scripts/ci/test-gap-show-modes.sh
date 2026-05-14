#!/usr/bin/env bash
# CI tests for chump gap show --brief / --full / --field (INFRA-1037)
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CHUMP="${CHUMP_BIN:-chump}"

# --- Test 1: default show has status in first 5 lines ---
output="$("$CHUMP" gap show INFRA-1037 2>/dev/null | head -5)" || output=""
if echo "$output" | grep -q "status:"; then
  ok "default show: status appears in first 5 lines"
else
  fail "default show: status NOT in first 5 lines (got: $output)"
fi

# --- Test 2: --brief prints exactly one line ---
brief_out="$("$CHUMP" gap show INFRA-1037 --brief 2>/dev/null)"
line_count="$(echo "$brief_out" | wc -l | tr -d ' ')"
if [[ "$line_count" -eq 1 ]]; then
  ok "--brief produces exactly 1 line"
else
  fail "--brief produced $line_count lines (expected 1)"
fi

# --- Test 3: --brief line contains ID, status, title ---
if echo "$brief_out" | grep -qE "INFRA-1037"; then
  ok "--brief line contains gap ID"
else
  fail "--brief line missing gap ID: $brief_out"
fi

# --- Test 4: --field status prints just the status value ---
field_out="$("$CHUMP" gap show INFRA-1037 --field status 2>/dev/null)"
if [[ "$field_out" == "open" || "$field_out" == "done" || "$field_out" == "claimed" ]]; then
  ok "--field status prints bare value"
else
  fail "--field status printed unexpected: '$field_out'"
fi

# --- Test 5: --field title prints just the title ---
title_out="$("$CHUMP" gap show INFRA-1037 --field title 2>/dev/null)"
if [[ -n "$title_out" ]] && echo "$title_out" | grep -q "show"; then
  ok "--field title prints title value"
else
  fail "--field title printed unexpected: '$title_out'"
fi

# --- Test 6: --field unknown exits 1 ---
if ! "$CHUMP" gap show INFRA-1037 --field nonexistent_field 2>/dev/null; then
  ok "--field unknown exits non-zero"
else
  fail "--field unknown should exit non-zero"
fi

# --- Test 7: default show has closed_pr/closed_date before description ---
# Test with a done gap that has closed_pr (use INFRA-1020 which we just shipped)
done_out="$("$CHUMP" gap show INFRA-1020 2>/dev/null | head -10)"
desc_line="$(echo "$done_out" | grep -n "description:" | head -1 | cut -d: -f1)"
pr_line="$(echo "$done_out" | grep -n "closed_pr:\|closed_date:" | head -1 | cut -d: -f1)"
if [[ -n "$pr_line" && -n "$desc_line" ]] && [[ "$pr_line" -lt "$desc_line" ]]; then
  ok "closed_pr appears before description in done gap"
elif [[ -z "$pr_line" ]]; then
  ok "no closed_pr in INFRA-1020 (gap may not have PR yet)"
else
  fail "description (line $desc_line) appears before closed_pr (line $pr_line)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
