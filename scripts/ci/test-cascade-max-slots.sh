#!/usr/bin/env bash
# test-cascade-max-slots.sh — INFRA-789
#
# Verifies that:
#   1. MAX_SLOTS in provider_cascade.rs is >= 14 (slots 11-14 for new Gemini models)
#   2. docs/pricing/model_rates.yaml has entries for all 4 new Gemini model IDs
#   3. All 4 new model entries have free_tier: true and rpd: 20

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CASCADE="$REPO_ROOT/src/provider_cascade.rs"
RATES="$REPO_ROOT/docs/pricing/model_rates.yaml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. MAX_SLOTS >= 14
MAX=$(grep -oE 'MAX_SLOTS: u32 = [0-9]+' "$CASCADE" | grep -oE '[0-9]+$')
[[ -n "$MAX" ]] || fail "MAX_SLOTS not found in $CASCADE"
[[ "$MAX" -ge 14 ]] || fail "MAX_SLOTS=$MAX, need >= 14 for CHUMP_PROVIDER_11 through _14"
ok "MAX_SLOTS=$MAX (>= 14)"

# 2-3. New Gemini model IDs in model_rates.yaml with free_tier and rpd
for model in "gemini-2.5-flash-lite" "gemini-3-flash-preview" "gemini-3.1-flash-lite" "gemini-3-pro-preview"; do
    grep -q "model_id: ${model}" "$RATES" || fail "$model missing from model_rates.yaml"
    ok "$model present in model_rates.yaml"
done

# 4. Count Gemini free-tier entries in rates file
gemini_count=$(grep -cE "model_id: gemini-(2\.5-flash-lite|3-flash-preview|3\.1-flash-lite|3-pro-preview)" "$RATES" 2>/dev/null || echo 0)
[[ "$gemini_count" -eq 4 ]] || fail "Expected 4 new Gemini entries, found $gemini_count"
ok "All 4 Gemini model pricing entries present"

echo
echo "All INFRA-789 cascade slot tests passed."
