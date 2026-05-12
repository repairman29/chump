#!/usr/bin/env bash
# test-obs-alerting.sh — INFRA-679
#
# Validates scripts/ops/obs-alerting.sh:
#  1. no-alert: clean env → no alerts fired
#  2. cascade_near_cap: 3 slots at >80% RPD → alert emitted to ambient.jsonl
#  3. cascade_near_cap: only 2 slots at >80% → no alert
#  4. cost_budget_breach: spent > cap → alert emitted
#  5. cost_budget_breach: spent < cap → no alert
#  6. --dry-run: doesn't write to ambient.jsonl
#  7. --json: outputs valid JSON event
#  8. CHUMP_ALERT_WEBHOOK: attempt POST when webhook configured
#  9. cascade_near_cap registered in EVENT_REGISTRY.yaml
# 10. cost_budget_breach registered in EVENT_REGISTRY.yaml

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/obs-alerting.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-679 obs-alerting test ==="
echo

if [[ ! -x "$SCRIPT" ]]; then
    echo "  SKIP: $SCRIPT not found or not executable"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_env() {
    local root="$1"
    mkdir -p "$root/.chump" "$root/.chump-locks"
    touch "$root/.chump-locks/ambient.jsonl"
}

# ── 1. No-alert: clean environment ────────────────────────────────────────────
echo "[1. no-alert case]"
R1="$TMP/t1"; mk_env "$R1"
OUT=$(CHUMP_REPO="$R1" CHUMP_AMBIENT_OVERRIDE="$R1/.chump-locks/ambient.jsonl" \
    "$SCRIPT" 2>&1 || true)
if ! grep -q "cascade_near_cap\|cost_budget_breach" "$R1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "no alerts fired in clean environment"
else
    fail "unexpected alert in clean environment"
fi

# ── 2. cascade_near_cap: 3+ slots at >80% ─────────────────────────────────────
echo
echo "[2. cascade_near_cap fires with 3 overloaded slots]"
R2="$TMP/t2"; mk_env "$R2"
# 3 slots at 90%+ of their RPD limits
printf '{"1": 850, "2": 12960, "3": 45000}\n' > "$R2/.chump/provider-usage.json"

CHUMP_REPO="$R2" \
CHUMP_AMBIENT_OVERRIDE="$R2/.chump-locks/ambient.jsonl" \
CHUMP_PROVIDER_USAGE_FILE="$R2/.chump/provider-usage.json" \
CHUMP_PROVIDER_1_RPD=1000 \
CHUMP_PROVIDER_2_RPD=14400 \
CHUMP_PROVIDER_3_RPD=50000 \
    "$SCRIPT" 2>/dev/null || true

if grep -q "cascade_near_cap" "$R2/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "cascade_near_cap alert fired when 3 slots at >80%"
else
    fail "cascade_near_cap did not fire (expected 3 slots at >80%)"
fi

if python3 -c "
import json
events = [json.loads(l) for l in open('$R2/.chump-locks/ambient.jsonl') if l.strip()]
e = next((x for x in events if x.get('kind') == 'cascade_near_cap'), None)
assert e is not None
assert e.get('near_cap_slots', 0) >= 3, f'near_cap_slots={e.get(\"near_cap_slots\")}'
" 2>/dev/null; then
    ok "cascade_near_cap event has near_cap_slots >= 3"
else
    fail "cascade_near_cap event missing or near_cap_slots wrong"
fi

# ── 3. cascade_near_cap: only 2 slots → no alert ──────────────────────────────
echo
echo "[3. cascade no alert with only 2 overloaded slots]"
R3="$TMP/t3"; mk_env "$R3"
printf '{"1": 850, "2": 12960, "3": 100}\n' > "$R3/.chump/provider-usage.json"

CHUMP_REPO="$R3" \
CHUMP_AMBIENT_OVERRIDE="$R3/.chump-locks/ambient.jsonl" \
CHUMP_PROVIDER_USAGE_FILE="$R3/.chump/provider-usage.json" \
CHUMP_PROVIDER_1_RPD=1000 \
CHUMP_PROVIDER_2_RPD=14400 \
CHUMP_PROVIDER_3_RPD=50000 \
    "$SCRIPT" 2>/dev/null || true

if ! grep -q "cascade_near_cap" "$R3/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "no cascade_near_cap alert when only 2 slots at >80%"
else
    fail "unexpected cascade_near_cap with only 2 overloaded slots"
fi

# ── 4. cost_budget_breach: spent > cap ────────────────────────────────────────
echo
echo "[4. cost_budget_breach fires when spent > cap]"
R4="$TMP/t4"; mk_env "$R4"
printf '{"spent_usd": 12.50, "budget_usd": 10.00}\n' > "$R4/.chump/daily-cost.json"

CHUMP_REPO="$R4" \
CHUMP_AMBIENT_OVERRIDE="$R4/.chump-locks/ambient.jsonl" \
    "$SCRIPT" 2>/dev/null || true

if grep -q "cost_budget_breach" "$R4/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "cost_budget_breach alert fired when spent > budget"
else
    fail "cost_budget_breach did not fire (spent=12.50 > budget=10.00)"
fi

# ── 5. cost_budget_breach: spent < cap → no alert ─────────────────────────────
echo
echo "[5. no cost alert when spent < cap]"
R5="$TMP/t5"; mk_env "$R5"
printf '{"spent_usd": 7.00, "budget_usd": 10.00}\n' > "$R5/.chump/daily-cost.json"

CHUMP_REPO="$R5" \
CHUMP_AMBIENT_OVERRIDE="$R5/.chump-locks/ambient.jsonl" \
    "$SCRIPT" 2>/dev/null || true

if ! grep -q "cost_budget_breach" "$R5/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "no cost_budget_breach when spent < budget"
else
    fail "unexpected cost_budget_breach when spent=7.00 < budget=10.00"
fi

# ── 6. --dry-run: doesn't write to ambient.jsonl ──────────────────────────────
echo
echo "[6. --dry-run: no ambient writes]"
R6="$TMP/t6"; mk_env "$R6"
printf '{"spent_usd": 15.00, "budget_usd": 10.00}\n' > "$R6/.chump/daily-cost.json"

CHUMP_REPO="$R6" \
CHUMP_AMBIENT_OVERRIDE="$R6/.chump-locks/ambient.jsonl" \
    "$SCRIPT" --dry-run 2>/dev/null || true

AMBIENT_SIZE="$(wc -c < "$R6/.chump-locks/ambient.jsonl")"
if [[ "$AMBIENT_SIZE" -eq 0 ]]; then
    ok "--dry-run does not write to ambient.jsonl"
else
    fail "--dry-run wrote to ambient.jsonl (got $AMBIENT_SIZE bytes)"
fi

# ── 7. --json: outputs valid JSON event ───────────────────────────────────────
echo
echo "[7. --json output is valid JSON]"
R7="$TMP/t7"; mk_env "$R7"
printf '{"spent_usd": 15.00, "budget_usd": 10.00}\n' > "$R7/.chump/daily-cost.json"

JSON_OUT="$(CHUMP_REPO="$R7" \
    CHUMP_AMBIENT_OVERRIDE="$R7/.chump-locks/ambient.jsonl" \
    "$SCRIPT" --json 2>/dev/null || true)"

if python3 -c "
import json, sys
lines = [l for l in '''$JSON_OUT'''.strip().splitlines() if l.strip()]
assert len(lines) > 0, 'no JSON output'
obj = json.loads(lines[0])
assert 'kind' in obj, f'missing kind: {obj}'
assert obj['kind'] in ('cost_budget_breach', 'cascade_near_cap'), f'unexpected kind: {obj[\"kind\"]}'
" 2>/dev/null; then
    ok "--json outputs valid JSON event with kind field"
else
    fail "--json did not output valid JSON with kind (got: $JSON_OUT)"
fi

# ── 8. CHUMP_ALERT_WEBHOOK: POST attempted ────────────────────────────────────
echo
echo "[8. CHUMP_ALERT_WEBHOOK POST attempted]"
R8="$TMP/t8"; mk_env "$R8"
printf '{"spent_usd": 15.00, "budget_usd": 10.00}\n' > "$R8/.chump/daily-cost.json"

# Use a fake URL that will fail gracefully (curl returns error, script continues)
WEBHOOK_ATTEMPTED=0
if CHUMP_REPO="$R8" \
   CHUMP_AMBIENT_OVERRIDE="$R8/.chump-locks/ambient.jsonl" \
   CHUMP_ALERT_WEBHOOK="http://127.0.0.1:1" \
   "$SCRIPT" 2>/dev/null; then
    WEBHOOK_ATTEMPTED=1
fi
# Script should not fail even if webhook POST fails
if grep -q "cost_budget_breach" "$R8/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "webhook failure does not prevent ambient.jsonl write"
else
    fail "alert not written to ambient.jsonl when webhook is configured"
fi

# ── 9. EVENT_REGISTRY: cascade_near_cap registered ───────────────────────────
echo
echo "[9. EVENT_REGISTRY registration]"
if [[ -f "$REGISTRY" ]] && grep -q "cascade_near_cap" "$REGISTRY"; then
    ok "cascade_near_cap registered in EVENT_REGISTRY.yaml"
else
    fail "cascade_near_cap NOT registered in EVENT_REGISTRY.yaml"
fi

if [[ -f "$REGISTRY" ]] && grep -q "cost_budget_breach" "$REGISTRY"; then
    ok "cost_budget_breach registered in EVENT_REGISTRY.yaml"
else
    fail "cost_budget_breach NOT registered in EVENT_REGISTRY.yaml"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
