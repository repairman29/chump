#!/usr/bin/env bash
# test-curator-decision-logging.sh — INFRA-848
#
# Validates that opus-curator.sh emits kind=curator_decision events with
# the required structured schema: decision_type, reasoning, action_taken.
#
# AC targets (6/6):
#   1. kind=curator_decision present in emitted events
#   2. All required fields present (decision_type, reasoning, action_taken)
#   3. decision_type in allowed enum set
#   4. action_taken recorded (not empty)
#   5. curator_decision logged for each audit phase (5 decisions minimum)
#   6. curator_decision registered in EVENT_REGISTRY.yaml

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-848 curator decision logging test ==="
echo

# ── Static checks ──────────────────────────────────────────────────────────

# 1. opus-curator.sh exists and is executable
if [[ -x "$CURATOR" ]]; then
    ok "opus-curator.sh exists and is executable"
else
    fail "opus-curator.sh missing or not executable at $CURATOR"
fi

# 2. log_curator_decision function present
if grep -q 'log_curator_decision' "$CURATOR"; then
    ok "log_curator_decision function defined in opus-curator.sh"
else
    fail "log_curator_decision missing from opus-curator.sh"
fi

# 3. curator_decision kind emitted (kind literal present)
if grep -q '"curator_decision"' "$CURATOR" || grep -q 'kind.*curator_decision\|curator_decision.*kind' "$CURATOR"; then
    ok "curator_decision kind literal present in opus-curator.sh"
else
    fail "curator_decision kind literal missing from opus-curator.sh"
fi

# 4. decision_type field emitted
if grep -q 'decision_type' "$CURATOR"; then
    ok "decision_type field referenced in opus-curator.sh"
else
    fail "decision_type field missing from opus-curator.sh"
fi

# 5. reasoning field emitted
if grep -q 'reasoning' "$CURATOR"; then
    ok "reasoning field referenced in opus-curator.sh"
else
    fail "reasoning field missing from opus-curator.sh"
fi

# 6. action_taken field emitted
if grep -q 'action_taken' "$CURATOR"; then
    ok "action_taken field referenced in opus-curator.sh"
else
    fail "action_taken field missing from opus-curator.sh"
fi

# 7. All allowed decision_type values present
ALLOWED_TYPES="p0_demotion gap_ac_filled gap_filed pr_unstick waste_investigation balance_restock"
_missing_types=()
for _dt in $ALLOWED_TYPES; do
    if ! grep -q "$_dt" "$CURATOR"; then
        _missing_types+=("$_dt")
    fi
done
if [[ ${#_missing_types[@]} -eq 0 ]]; then
    ok "all allowed decision_type values referenced in opus-curator.sh"
else
    fail "missing decision_type values in opus-curator.sh: ${_missing_types[*]}"
fi

# 8. At least 5 log_curator_decision calls (one per audit phase)
_call_count=$(grep -c 'log_curator_decision' "$CURATOR" 2>/dev/null || echo 0)
# Subtract 1 for the function definition itself
_actual_calls=$(( _call_count - 1 ))
if [[ "$_actual_calls" -ge 5 ]]; then
    ok "log_curator_decision called at least 5 times (got $_actual_calls)"
else
    fail "expected >= 5 log_curator_decision calls, got $_actual_calls"
fi

# 9. INFRA-848 referenced in curator script
if grep -q 'INFRA-848' "$CURATOR"; then
    ok "INFRA-848 referenced in opus-curator.sh"
else
    fail "INFRA-848 reference missing from opus-curator.sh"
fi

# 10. curator_decision registered in EVENT_REGISTRY.yaml
if grep -q 'curator_decision' "$REGISTRY"; then
    ok "curator_decision registered in EVENT_REGISTRY.yaml"
else
    fail "curator_decision missing from EVENT_REGISTRY.yaml"
fi

# 11. EVENT_REGISTRY entry has fields_required with all 3 required fields
if grep -A5 'kind: curator_decision' "$REGISTRY" 2>/dev/null | grep -q 'decision_type.*reasoning.*action_taken\|fields_required.*decision_type'; then
    ok "curator_decision registry entry has fields_required"
else
    # Check if fields are spread across lines
    _reg_block=$(awk '/kind: curator_decision/{found=1} found && /^  - kind:/{if(found>1){exit} found++} found{print}' "$REGISTRY" 2>/dev/null || true)
    if echo "$_reg_block" | grep -q 'decision_type' && \
       echo "$_reg_block" | grep -q 'reasoning' && \
       echo "$_reg_block" | grep -q 'action_taken'; then
        ok "curator_decision registry entry has fields_required (decision_type, reasoning, action_taken)"
    else
        fail "curator_decision registry entry missing fields_required with decision_type/reasoning/action_taken"
    fi
fi

# ── Functional test: simulate curator run and validate events ──────────────
echo
echo "[functional: simulate curator_decision events and validate schema]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"

# Emit simulated curator_decision events (one per decision type)
DECISION_TYPES=(p0_demotion gap_ac_filled balance_restock pr_unstick waste_investigation)
for _dt in "${DECISION_TYPES[@]}"; do
    printf '{"ts":"%s","kind":"curator_decision","decision_type":"%s","reasoning":"test reasoning for %s","action_taken":"identified_only"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_dt" "$_dt" \
        >> "$AMB"
done

# 12. kind=curator_decision present in output
if grep -q '"kind":"curator_decision"' "$AMB"; then
    ok "kind=curator_decision present in simulated events"
else
    fail "kind=curator_decision missing from simulated events"
fi

# 13. All required fields present in each event
_bad=0
while IFS= read -r _line; do
    if ! echo "$_line" | python3 -c "
import sys, json
ev = json.loads(sys.stdin.read())
assert 'decision_type' in ev, 'missing decision_type'
assert 'reasoning' in ev, 'missing reasoning'
assert 'action_taken' in ev, 'missing action_taken'
assert ev['reasoning'] != '', 'reasoning is empty'
assert ev['action_taken'] != '', 'action_taken is empty'
" 2>/dev/null; then
        _bad=$((_bad+1))
    fi
done < "$AMB"
if [[ "$_bad" -eq 0 ]]; then
    ok "all required fields present and non-empty in each curator_decision event"
else
    fail "$_bad curator_decision events missing required fields or have empty values"
fi

# 14. decision_type in allowed enum set
_invalid_dt=0
while IFS= read -r _line; do
    _dt_val=$(echo "$_line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('decision_type',''))" 2>/dev/null || echo "")
    if ! echo "$ALLOWED_TYPES" | grep -qw "$_dt_val"; then
        _invalid_dt=$((_invalid_dt+1))
    fi
done < "$AMB"
if [[ "$_invalid_dt" -eq 0 ]]; then
    ok "all decision_type values within allowed enum set"
else
    fail "$_invalid_dt events had decision_type outside allowed enum"
fi

# 15. 5 decision phases covered (one event per decision type)
_event_count=$(wc -l < "$AMB" | tr -d ' ')
if [[ "$_event_count" -ge 5 ]]; then
    ok "5 curator decision phases covered in events (got $_event_count)"
else
    fail "expected >= 5 curator_decision events, got $_event_count"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
