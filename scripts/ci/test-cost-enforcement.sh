#!/usr/bin/env bash
# test-cost-enforcement.sh — INFRA-877
#
# Tests scripts/ops/cost-enforcement.sh with synthetic session_end events:
#  1. script exists and is executable
#  2. EVENT_REGISTRY has cost_quota_warning + cost_quota_exceeded
#  3. INFRA-877 referenced in cost_ledger.rs
#  4. At 50% spend: exits 0, no quota events emitted
#  5. At 80% spend: exits 0, emits cost_quota_warning
#  6. At 100% spend: exits 1, emits cost_quota_exceeded
#  7. At 110% spend: exits 1, emits cost_quota_exceeded
#  8. --dry-run suppresses ambient write at 110%
#  9. --json outputs JSON with budget_used_pct field

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/ops/cost-enforcement.sh"

pass=0
fail=0
ok()  { echo "  PASS $1"; pass=$((pass + 1)); }
err() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "=== test-cost-enforcement.sh ==="

# Test 1: script exists and executable
if [[ -x "$SCRIPT" ]]; then
    ok "1: cost-enforcement.sh exists and is executable"
else
    err "1: cost-enforcement.sh missing or not executable"
    exit 1
fi

# Test 2: EVENT_REGISTRY has both event kinds
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "cost_quota_warning" "$REGISTRY" && grep -q "cost_quota_exceeded" "$REGISTRY"; then
    ok "2: cost_quota_warning + cost_quota_exceeded registered in EVENT_REGISTRY.yaml"
else
    err "2: missing cost_quota event kinds in EVENT_REGISTRY.yaml"
fi

# Test 3: INFRA-877 referenced in cost_ledger.rs
if grep -q "INFRA-877" "$REPO_ROOT/src/cost_ledger.rs" 2>/dev/null; then
    ok "3: INFRA-877 referenced in src/cost_ledger.rs"
else
    err "3: INFRA-877 not found in src/cost_ledger.rs"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Helper: write a session_end event with given cost_usd to an ambient file
write_spend() {
    local amb="$1" cost="$2"
    mkdir -p "$(dirname "$amb")"
    ts=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    printf '{"ts":"%s","kind":"session_end","model":"claude-haiku","input_tokens":1000,"output_tokens":500,"cache_read_tokens":0,"cost_usd":%s}\n' \
        "$ts" "$cost" >> "$amb"
}

BUDGET=10.0  # $10 daily budget for all tests

# ── Test 4: 50% spend — exits 0, no quota events ─────────────────────────────
AMB4="$TMP/t4.jsonl"
write_spend "$AMB4" 5.0   # $5 / $10 = 50%
if CHUMP_DAILY_BUDGET_USD="$BUDGET" CHUMP_AMBIENT_LOG="$AMB4" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "4: 50% spend exits 0"
else
    err "4: 50% spend should exit 0"
fi
if ! grep -qE "cost_quota_warning|cost_quota_exceeded" "$AMB4" 2>/dev/null; then
    ok "4b: 50% spend emits no quota event"
else
    err "4b: 50% spend emitted unexpected quota event"
fi

# ── Test 5: 80% spend — exits 0, emits cost_quota_warning ────────────────────
AMB5="$TMP/t5.jsonl"
write_spend "$AMB5" 8.0   # $8 / $10 = 80%
if CHUMP_DAILY_BUDGET_USD="$BUDGET" CHUMP_AMBIENT_LOG="$AMB5" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "5: 80% spend exits 0 (warning, not hard cap)"
else
    err "5: 80% spend should exit 0"
fi
if grep -q "cost_quota_warning" "$AMB5" 2>/dev/null; then
    ok "5b: 80% spend emits cost_quota_warning"
else
    err "5b: 80% spend did not emit cost_quota_warning"
fi

# ── Test 6: 100% spend — exits 1, emits cost_quota_exceeded ──────────────────
AMB6="$TMP/t6.jsonl"
write_spend "$AMB6" 10.0  # $10 / $10 = 100%
if ! CHUMP_DAILY_BUDGET_USD="$BUDGET" CHUMP_AMBIENT_LOG="$AMB6" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "6: 100% spend exits 1 (hard cap)"
else
    err "6: 100% spend should exit 1"
fi
if grep -q "cost_quota_exceeded" "$AMB6" 2>/dev/null; then
    ok "6b: 100% spend emits cost_quota_exceeded"
else
    err "6b: 100% spend did not emit cost_quota_exceeded"
fi

# ── Test 7: 110% spend — exits 1, emits cost_quota_exceeded ──────────────────
AMB7="$TMP/t7.jsonl"
write_spend "$AMB7" 11.0  # $11 / $10 = 110%
if ! CHUMP_DAILY_BUDGET_USD="$BUDGET" CHUMP_AMBIENT_LOG="$AMB7" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "7: 110% spend exits 1"
else
    err "7: 110% spend should exit 1"
fi
if grep -q "cost_quota_exceeded" "$AMB7" 2>/dev/null; then
    ok "7b: 110% spend emits cost_quota_exceeded"
else
    err "7b: 110% spend did not emit cost_quota_exceeded"
fi

# ── Test 8: --dry-run suppresses ambient write ────────────────────────────────
AMB8="$TMP/t8.jsonl"
write_spend "$AMB8" 11.0   # 110% — would normally write + exit 1
lines_before=$(wc -l < "$AMB8" | tr -d ' ')
CHUMP_DAILY_BUDGET_USD="$BUDGET" CHUMP_AMBIENT_LOG="$AMB8" bash "$SCRIPT" --dry-run >/dev/null 2>&1 || true
lines_after=$(wc -l < "$AMB8" | tr -d ' ')
if [[ "$lines_before" -eq "$lines_after" ]]; then
    ok "8: --dry-run suppresses ambient write"
else
    err "8: --dry-run still appended to ambient ($lines_before → $lines_after)"
fi

# ── Test 9: --json outputs JSON with budget_used_pct ─────────────────────────
AMB9="$TMP/t9.jsonl"
write_spend "$AMB9" 6.0   # 60%
JSON_OUT=$(CHUMP_DAILY_BUDGET_USD="$BUDGET" CHUMP_AMBIENT_LOG="$AMB9" bash "$SCRIPT" --json 2>/dev/null | grep "budget_used_pct" | head -1)
if [[ -n "$JSON_OUT" ]]; then
    PCT=$(echo "$JSON_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('budget_used_pct', 'MISSING'))" 2>/dev/null || echo "FAIL")
    if [[ "$PCT" != "MISSING" && "$PCT" != "FAIL" ]]; then
        ok "9: --json outputs budget_used_pct=${PCT}"
    else
        err "9: --json output missing budget_used_pct field"
    fi
else
    err "9: --json produced no output"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
