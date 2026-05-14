#!/usr/bin/env bash
# scripts/ci/test-bot-merge-rest-direct.sh — INFRA-1166 (2026-05-14)
#
# Tests the INFRA-1166 REST-direct merge fast path in bot-merge.sh:
#  1. CHUMP_BOT_MERGE_REST_DIRECT env var registered in env-vars-internal.txt
#  2. bot_merge_rest_direct event registered in EVENT_REGISTRY.yaml
#  3. bot_merge_auto_armed event registered in EVENT_REGISTRY.yaml
#  4. bot-merge.sh contains INFRA-1166 marker
#  5. bot-merge.sh contains REST-direct path logic (gh api .../merge -X PUT)
#  6. bot-merge.sh contains CHUMP_BOT_MERGE_REST_DIRECT guard
#  7. bot-merge.sh emits bot_merge_rest_direct kind string
#  8. bot-merge.sh emits bot_merge_auto_armed kind string
#  9. bot-merge.sh has _rest_direct_merged guard variable
# 10. REQUIRED_CHECKS is passed into python3 check

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
ENV_VARS="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1166 REST-direct merge fast path test ==="
echo

# ── Test 1: env var registered ───────────────────────────────────────────────
if grep -q "CHUMP_BOT_MERGE_REST_DIRECT" "$ENV_VARS" 2>/dev/null; then
    ok "CHUMP_BOT_MERGE_REST_DIRECT registered in env-vars-internal.txt"
else
    fail "CHUMP_BOT_MERGE_REST_DIRECT missing from env-vars-internal.txt"
fi

# ── Test 2: bot_merge_rest_direct event registered ───────────────────────────
if grep -q "bot_merge_rest_direct" "$EVENT_REG" 2>/dev/null; then
    ok "bot_merge_rest_direct registered in EVENT_REGISTRY.yaml"
else
    fail "bot_merge_rest_direct missing from EVENT_REGISTRY.yaml"
fi

# ── Test 3: bot_merge_auto_armed event registered ────────────────────────────
if grep -q "bot_merge_auto_armed" "$EVENT_REG" 2>/dev/null; then
    ok "bot_merge_auto_armed registered in EVENT_REGISTRY.yaml"
else
    fail "bot_merge_auto_armed missing from EVENT_REGISTRY.yaml"
fi

# ── Test 4: INFRA-1166 marker in bot-merge.sh ───────────────────────────────
if grep -q "INFRA-1166" "$BOT_MERGE" 2>/dev/null; then
    ok "INFRA-1166 marker present in bot-merge.sh"
else
    fail "INFRA-1166 marker missing from bot-merge.sh"
fi

# ── Test 5: REST PUT merge call present ──────────────────────────────────────
# The call spans multiple lines: gh api repos/.../pulls/N/merge \n -X PUT
if grep -q '/pulls/.*TARGET_PR.*/merge' "$BOT_MERGE" 2>/dev/null && \
   grep -q '\-X PUT' "$BOT_MERGE" 2>/dev/null; then
    ok "REST PUT /pulls/N/merge call present in bot-merge.sh"
else
    fail "REST PUT merge call missing from bot-merge.sh"
fi

# ── Test 6: CHUMP_BOT_MERGE_REST_DIRECT guard present ───────────────────────
if grep -q "CHUMP_BOT_MERGE_REST_DIRECT" "$BOT_MERGE" 2>/dev/null; then
    ok "CHUMP_BOT_MERGE_REST_DIRECT guard present in bot-merge.sh"
else
    fail "CHUMP_BOT_MERGE_REST_DIRECT guard missing from bot-merge.sh"
fi

# ── Test 7: bot_merge_rest_direct kind emitted ───────────────────────────────
if grep -q '"kind":"bot_merge_rest_direct"' "$BOT_MERGE" 2>/dev/null; then
    ok "bot_merge_rest_direct kind string emitted in bot-merge.sh"
else
    fail "bot_merge_rest_direct kind string missing from bot-merge.sh"
fi

# ── Test 8: bot_merge_auto_armed kind emitted ────────────────────────────────
if grep -q '"kind":"bot_merge_auto_armed"' "$BOT_MERGE" 2>/dev/null; then
    ok "bot_merge_auto_armed kind string emitted in bot-merge.sh"
else
    fail "bot_merge_auto_armed kind string missing from bot-merge.sh"
fi

# ── Test 9: _rest_direct_merged guard variable ───────────────────────────────
if grep -q "_rest_direct_merged" "$BOT_MERGE" 2>/dev/null; then
    ok "_rest_direct_merged guard variable present in bot-merge.sh"
else
    fail "_rest_direct_merged guard variable missing from bot-merge.sh"
fi

# ── Test 10: python3 check receives REQUIRED_CHECKS ──────────────────────────
if grep -A3 "RDPYEOF\|rdpyeof\|python3.*REQUIRED_CHECKS\|sys.argv.*required" "$BOT_MERGE" 2>/dev/null | grep -q "argv\|required_raw\|REQUIRED_CHECKS"; then
    ok "python3 check receives REQUIRED_CHECKS in bot-merge.sh"
else
    # Alternative: check that REQUIRED_CHECKS is passed to the python3 block
    if grep -q 'python3 - "\$REQUIRED_CHECKS"' "$BOT_MERGE" 2>/dev/null; then
        ok "python3 check receives REQUIRED_CHECKS (\$REQUIRED_CHECKS arg)"
    else
        fail "python3 check does not pass REQUIRED_CHECKS to bot-merge.sh fast path"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
