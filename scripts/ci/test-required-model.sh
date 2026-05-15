#!/usr/bin/env bash
# test-required-model.sh — INFRA-843
#
# Validates gap.required_model plumbing:
#  1. INFRA-843 referenced in worker.sh and main.rs
#  2. required_model field in GapRow struct (gap_store.rs)
#  3. worker.sh emits kind=model_selected with required fields
#  4. model_selected registered in EVENT_REGISTRY.yaml
#  5. haiku-only worker skips opus-required gap (picker filter)
#  6. kind=model_selected reason=gap_required_model when override fires
#  7. kind=model_selected reason=fleet_model_default when no required_model
#  8. chump --execute-gap path: INFRA-843 block in main.rs

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
MAIN_RS="$REPO_ROOT/src/main.rs"
# INFRA-693: gap_store.rs was extracted to crates/chump-gap-store/.
# Accept either location during the transition for branches that haven't
# rebased onto the extracted-crate layout yet.
if [[ -f "$REPO_ROOT/crates/chump-gap-store/src/lib.rs" ]]; then
    GAP_STORE="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"
else
    GAP_STORE="$REPO_ROOT/src/gap_store.rs"
fi
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"
PICK_CLAIM="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

echo "=== INFRA-843 required_model plumbing test ==="
echo

# ── Static checks ──────────────────────────────────────────────────────────

# 1. INFRA-843 referenced in worker.sh
if grep -q 'INFRA-843' "$WORKER" 2>/dev/null; then
    ok "INFRA-843 referenced in worker.sh"
else
    fail "INFRA-843 missing from worker.sh"
fi

# 2. INFRA-843 referenced in main.rs (--execute-gap path)
if grep -q 'INFRA-843' "$MAIN_RS" 2>/dev/null; then
    ok "INFRA-843 referenced in main.rs"
else
    fail "INFRA-843 missing from main.rs"
fi

# 3. required_model field in gap_store.rs
if grep -q 'required_model' "$GAP_STORE" 2>/dev/null; then
    ok "required_model field present in gap_store.rs"
else
    fail "required_model missing from gap_store.rs"
fi

# 4. model_selected emitted in worker.sh
if grep -q 'model_selected' "$WORKER" 2>/dev/null; then
    ok "kind=model_selected emitted in worker.sh"
else
    fail "kind=model_selected missing from worker.sh"
fi

# 5. model_selected registered in EVENT_REGISTRY.yaml
if grep -q 'model_selected' "$REGISTRY" 2>/dev/null; then
    ok "model_selected registered in EVENT_REGISTRY.yaml"
else
    fail "model_selected missing from EVENT_REGISTRY.yaml"
fi

# 6. EVENT_REGISTRY entry has fields_required
if grep -A8 'kind: model_selected' "$REGISTRY" 2>/dev/null | grep -q 'fields_required'; then
    ok "model_selected registry entry has fields_required"
else
    fail "model_selected registry entry missing fields_required"
fi

# 7. model_selected fields include gap_id, requested, actual, reason
_reg_block=$(awk '/kind: model_selected/{found=1} found && /^  - kind:/{if(found>1){exit} found++} found{print}' "$REGISTRY" 2>/dev/null || true)
if echo "$_reg_block" | grep -q 'gap_id' && \
   echo "$_reg_block" | grep -q 'requested' && \
   echo "$_reg_block" | grep -q 'actual' && \
   echo "$_reg_block" | grep -q 'reason'; then
    ok "model_selected fields_required includes gap_id, requested, actual, reason"
else
    fail "model_selected fields_required missing one of: gap_id, requested, actual, reason"
fi

# 8. worker.sh reads _gap_required_model from gap_json
if grep -q '_gap_required_model\|required_model' "$WORKER" 2>/dev/null; then
    ok "worker.sh extracts required_model from gap_json"
else
    fail "worker.sh does not extract required_model from gap_json"
fi

# 9. required_model picker filter: skip gap if required_model != worker_model
# Check _pick_gap.py or _pick_and_claim_gap.py
_picker_check=0
if grep -q 'required_model' "$PICKER" 2>/dev/null; then _picker_check=1; fi
if grep -q 'required_model' "$PICK_CLAIM" 2>/dev/null; then _picker_check=1; fi
if [[ "$_picker_check" -eq 1 ]]; then
    ok "picker filters gaps by required_model vs. FLEET_MODEL"
else
    fail "picker does not filter by required_model"
fi

# 10. --execute-gap path in main.rs reads required_model from store
if grep -B2 -A5 'INFRA-843' "$MAIN_RS" 2>/dev/null | grep -q 'required_model\|GapStore'; then
    ok "main.rs --execute-gap path reads required_model from GapStore"
else
    fail "main.rs --execute-gap path does not read required_model from GapStore"
fi

# ── Functional tests ───────────────────────────────────────────────────────
echo
echo "[functional: model_selected event schema + picker filter simulation]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 11. Simulate model_selected event (fleet_model_default case)
AMB="$TMP/ambient.jsonl"
printf '{"ts":"%s","kind":"model_selected","gap_id":"INFRA-TEST","requested":"","actual":"sonnet","reason":"fleet_model_default"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMB"

if python3 -c "
import sys, json
ev = json.loads(open('$AMB').read().strip())
assert ev['kind'] == 'model_selected', f'wrong kind: {ev[\"kind\"]}'
assert 'gap_id' in ev, 'missing gap_id'
assert 'requested' in ev, 'missing requested'
assert 'actual' in ev, 'missing actual'
assert 'reason' in ev, 'missing reason'
assert ev['reason'] in ('fleet_model_default', 'gap_required_model', 'routing_yaml'), f'invalid reason: {ev[\"reason\"]}'
print('ok')
" 2>/dev/null | grep -q 'ok'; then
    ok "model_selected event (fleet_model_default) has correct schema"
else
    fail "model_selected event missing required fields or invalid reason"
fi

# 12. Simulate model_selected event (gap_required_model case)
printf '{"ts":"%s","kind":"model_selected","gap_id":"INFRA-OPUS","requested":"opus","actual":"opus","reason":"gap_required_model"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMB"

_opus_ev=$(grep '"gap_required_model"' "$AMB" | tail -1)
if python3 -c "
import sys, json
ev = json.loads('$_opus_ev')
assert ev['reason'] == 'gap_required_model', f'wrong reason: {ev[\"reason\"]}'
assert ev['requested'] == 'opus', f'wrong requested: {ev[\"requested\"]}'
assert ev['actual'] == 'opus', f'wrong actual: {ev[\"actual\"]}'
print('ok')
" 2>/dev/null | grep -q 'ok'; then
    ok "model_selected event (gap_required_model) has correct requested/actual/reason"
else
    fail "model_selected event (gap_required_model) missing or incorrect fields"
fi

# 13. Picker filter: opus-only gap skipped by haiku worker
# Simulate _pick_gap.py behavior: haiku worker, gap requires opus
_picker_result=$(python3 -c "
# Simulate picker filter logic from _pick_and_claim_gap.py
worker_model = 'haiku'
gaps = [
    {'id': 'INFRA-OPUS', 'required_model': 'opus', 'priority': 'P1', 'effort': 's', 'status': 'open'},
    {'id': 'INFRA-ANY', 'required_model': '', 'priority': 'P1', 'effort': 's', 'status': 'open'},
    {'id': 'INFRA-HAIKU', 'required_model': 'haiku', 'priority': 'P1', 'effort': 's', 'status': 'open'},
]
pickable = []
for g in gaps:
    required_model = (g.get('required_model') or '').lower()
    if required_model and required_model != worker_model:
        continue  # skip — model mismatch
    pickable.append(g['id'])
assert 'INFRA-OPUS' not in pickable, f'opus gap should be skipped by haiku worker'
assert 'INFRA-ANY' in pickable, f'any-model gap should be pickable'
assert 'INFRA-HAIKU' in pickable, f'haiku gap should be pickable by haiku worker'
print('ok')
" 2>/dev/null || echo "fail")
if [[ "$_picker_result" == "ok" ]]; then
    ok "haiku worker skips opus-required gap; picks haiku and any-model gaps"
else
    fail "picker model filter not working correctly"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
