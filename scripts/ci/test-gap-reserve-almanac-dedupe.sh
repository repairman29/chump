#!/usr/bin/env bash
# scripts/ci/test-gap-reserve-almanac-dedupe.sh — ZERO-WASTE-045 (2026-08-10)
#
# Tests the ZERO-WASTE-045 reserve-time Almanac-corpus dedupe check, which
# extends INFRA-1149's state.db-only check (open + 30-day-closed) to search
# the full Almanac index over docs/gaps/*.yaml — including gaps that shipped
# long enough ago to have fallen out of state.db's closed-lookback window.
# That was the actual DOC-082 failure mode this gap fixes: re-filing
# something already SHIPPED, not something open.
#
#  1. reserve still succeeds when almanac is unavailable (AC4: degrades safely)
#  2. ... and says so LOUDLY on stderr — never a silent skip (AC4 / CREDIBLE-214)
#  3. ZERO-WASTE-045 marker present in src/main.rs
#  4. search_gap_corpus / extract_gap_ids_from_search_output present in src/almanac_tool.rs
#  5. shipped_gap_dedupe_candidates present in chump-gap-store
#  6. both new event kinds registered in EVENT_REGISTRY.yaml
#  7. --force-duplicate is still accepted (doesn't regress INFRA-1149 flag)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/lib/source-grep.sh"
GAP_STORE_PATH=$(find_gap_store_path)

if [[ -n "${CHUMP_BIN:-}" ]]; then
    CHUMP="$CHUMP_BIN"
elif [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
    CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
else
    CHUMP="$(command -v chump 2>/dev/null || echo chump)"
fi

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== ZERO-WASTE-045 Almanac-corpus dedupe check test ==="
echo

# ── Test 1+2: almanac unavailable in this env (no ~/.almanac index / no
# almanac-mcp binary in a fresh CI runner) → reserve still succeeds, and the
# stderr output says loudly the almanac dedupe check did not run.
STDERR_OUT="$TMP/stderr.txt"
if CHUMP_ALMANAC_ENABLED=0 \
    "$CHUMP" gap reserve --domain TEST --title "almanac dedupe unavailable test unique qzx77" \
    --priority P3 --effort xs 2>"$STDERR_OUT" | grep -q "TEST-"; then
    ok "reserve succeeds even when almanac dedupe check cannot run"
else
    fail "reserve failed when almanac was unavailable — must degrade safely"
fi

if grep -qi "almanac.*did not run\|almanac.*unavailable" "$STDERR_OUT"; then
    ok "almanac-unavailable case is announced loudly on stderr (not a silent skip)"
else
    fail "no loud announcement that the almanac dedupe check did not run"
fi

# ── Test 3: ZERO-WASTE-045 marker in src/main.rs ─────────────────────────────
if grep -q "ZERO-WASTE-045" "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "ZERO-WASTE-045 marker present in src/main.rs"
else
    fail "ZERO-WASTE-045 marker missing from src/main.rs"
fi

# ── Test 4: new almanac_tool.rs functions exist ──────────────────────────────
ALMANAC_TOOL="$REPO_ROOT/src/almanac_tool.rs"
if grep -q "fn search_gap_corpus" "$ALMANAC_TOOL" 2>/dev/null; then
    ok "search_gap_corpus present in src/almanac_tool.rs"
else
    fail "search_gap_corpus missing from src/almanac_tool.rs"
fi
if grep -q "fn extract_gap_ids_from_search_output" "$ALMANAC_TOOL" 2>/dev/null; then
    ok "extract_gap_ids_from_search_output present in src/almanac_tool.rs"
else
    fail "extract_gap_ids_from_search_output missing from src/almanac_tool.rs"
fi

# ── Test 5: shipped_gap_dedupe_candidates exists in gap-store ───────────────
if grep -q "pub fn shipped_gap_dedupe_candidates" "$GAP_STORE_PATH" 2>/dev/null; then
    ok "shipped_gap_dedupe_candidates present in $GAP_STORE_PATH"
else
    fail "shipped_gap_dedupe_candidates missing from $GAP_STORE_PATH"
fi

# ── Test 6: event kinds registered ───────────────────────────────────────────
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "gap_reserve_almanac_dedupe_hit" "$EVENT_REG" 2>/dev/null; then
    ok "gap_reserve_almanac_dedupe_hit registered in EVENT_REGISTRY.yaml"
else
    fail "gap_reserve_almanac_dedupe_hit missing from EVENT_REGISTRY.yaml"
fi
if grep -q "gap_reserve_dedupe_check_skipped" "$EVENT_REG" 2>/dev/null; then
    ok "gap_reserve_dedupe_check_skipped registered in EVENT_REGISTRY.yaml"
else
    fail "gap_reserve_dedupe_check_skipped missing from EVENT_REGISTRY.yaml"
fi

# ── Test 7: --force-duplicate still accepted (AC2: explicit flag proceeds) ──
if CHUMP_ALMANAC_ENABLED=0 \
    "$CHUMP" gap reserve --domain TEST --title "force duplicate almanac test unique qzx88" \
    --force-duplicate --priority P3 --effort xs --quiet 2>/dev/null | grep -q "TEST-"; then
    ok "--force-duplicate still accepted alongside the almanac dedupe check"
else
    fail "--force-duplicate regressed"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
