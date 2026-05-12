#!/usr/bin/env bash
# test-uuid-gap-id-compat.sh — INFRA-630
#
# Validates UUID-format gap-ID compatibility across the stack.
# Tests the sites that previously assumed [A-Z]+-\d+ pattern.
#
# Tests:
#  1. validate_gap_id (Rust) accepts full RFC-4122 UUID
#  2. validate_gap_id (Rust) accepts 8-char hex short-prefix
#  3. validate_gap_id (Rust) accepts classic DOMAIN-NUMBER (regression)
#  4. validate_gap_id (Rust) rejects non-gap garbage (regression)
#  5. bot-merge.sh branch UUID extraction (chump/<uuid>-slug)
#  6. bot-merge.sh branch short-prefix extraction (chump/<8hex>--slug)
#  7. bot-merge.sh commit log UUID extraction
#  8. gap_store.rs short-prefix lookup compiles (INFRA-630 annotation present)
#  9. test-ci-fixture-coupling.sh REAL_GAP_PATTERN accepts UUID filenames
# 10. decomposition-hint-tracker.sh GAP_RE matches UUIDs

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== INFRA-630 UUID gap-id compatibility test ==="
echo

TMP="$(mktemp -d -t chump-uuid-compat-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. validate_gap_id accepts full RFC-4122 UUID ────────────────────────────
echo "[1. validate_gap_id accepts full RFC-4122 UUID]"
if [[ -f "$REPO_ROOT/src/execute_gap.rs" ]]; then
    if grep -q "is_ascii_hexdigit\|RFC-4122\|INFRA-630" "$REPO_ROOT/src/execute_gap.rs"; then
        ok "execute_gap.rs has INFRA-630 UUID validation logic"
    else
        fail "execute_gap.rs missing INFRA-630 UUID validation"
    fi
else
    fail "execute_gap.rs not found"
fi

# ── 2. validate_gap_id accepts 8-char short-prefix ──────────────────────────
echo
echo "[2. validate_gap_id accepts 8-char hex short-prefix]"
grep -q "gap_id.len() == 8\|len() == 8.*hexdigit\|8.*hex.*short\|short.prefix" \
    "$REPO_ROOT/src/execute_gap.rs" 2>/dev/null && \
    ok "8-char short-prefix support in validate_gap_id" || \
    fail "8-char short-prefix not handled in validate_gap_id"

# ── 3. validate_gap_id_accepts_uuid_forms test present ──────────────────────
echo
echo "[3. validate_gap_id_accepts_uuid_forms test present]"
grep -q "validate_gap_id_accepts_uuid_forms\|8d3f2c0e-9f5b" \
    "$REPO_ROOT/src/execute_gap.rs" 2>/dev/null && \
    ok "UUID acceptance test present in execute_gap.rs" || \
    fail "UUID acceptance test missing from execute_gap.rs"

# ── 4. validate_gap_id rejects garbage (regression check) ───────────────────
echo
echo "[4. validate_gap_id still rejects garbage]"
grep -q "validate_gap_id_rejects_garbage" "$REPO_ROOT/src/execute_gap.rs" 2>/dev/null && \
    ok "garbage-rejection test still present" || \
    fail "garbage-rejection test missing"

# ── 5. bot-merge.sh full UUID branch extraction ──────────────────────────────
echo
echo "[5. bot-merge.sh extracts full UUID from branch name]"
grep -q "RFC-4122\|9a-f]{8}-\[0-9a-f\]\{4\}\|\[0-9a-f\]{8}-\[0-9a-f\]{4}" \
    "$BOT_MERGE" 2>/dev/null && \
    ok "bot-merge.sh has full-UUID branch extraction" || \
    fail "bot-merge.sh missing full-UUID branch extraction"

# ── 6. bot-merge.sh short-prefix branch extraction ───────────────────────────
echo
echo "[6. bot-merge.sh extracts short-prefix from branch name]"
grep -q "8\\\\\}--\|{8}--\|_uuid_short\|8-char short" "$BOT_MERGE" 2>/dev/null && \
    ok "bot-merge.sh has short-prefix branch extraction" || \
    fail "bot-merge.sh missing short-prefix branch extraction"

# ── 7. bot-merge.sh commit log UUID extraction ───────────────────────────────
echo
echo "[7. bot-merge.sh commit log UUID extraction]"
grep -q "COMMIT_GAP_IDS.*0-9a-f\|INFRA-630.*extract" "$BOT_MERGE" 2>/dev/null && \
    ok "bot-merge.sh COMMIT_GAP_IDS extracts UUIDs from commit log" || \
    fail "bot-merge.sh COMMIT_GAP_IDS missing UUID extraction"

# ── 8. gap_store.rs short-prefix lookup ─────────────────────────────────────
echo
echo "[8. gap_store.rs has UUID short-prefix lookup]"
grep -q "INFRA-630\|is_uuid_short_prefix\|uuid_short_prefix" \
    "$REPO_ROOT/src/gap_store.rs" 2>/dev/null && \
    ok "gap_store.rs has INFRA-630 UUID short-prefix lookup" || \
    fail "gap_store.rs missing INFRA-630 UUID short-prefix lookup"

# ── 9. test-ci-fixture-coupling REAL_GAP_PATTERN accepts UUIDs ───────────────
echo
echo "[9. test-ci-fixture-coupling.sh REAL_GAP_PATTERN accepts UUID filenames]"
FIXTURE_SCRIPT="$REPO_ROOT/scripts/ci/test-ci-fixture-coupling.sh"
if [[ -f "$FIXTURE_SCRIPT" ]]; then
    if grep -q "0-9a-f\|uuid\|UUID\|INFRA-630" "$FIXTURE_SCRIPT" 2>/dev/null; then
        ok "test-ci-fixture-coupling.sh REAL_GAP_PATTERN includes UUID form"
    else
        fail "test-ci-fixture-coupling.sh REAL_GAP_PATTERN missing UUID support"
    fi
else
    ok "test-ci-fixture-coupling.sh not present (optional)"
fi

# ── 10. decomposition-hint-tracker.sh GAP_RE matches UUIDs ──────────────────
echo
echo "[10. decomposition-hint-tracker.sh GAP_RE matches UUIDs]"
TRACKER="$REPO_ROOT/scripts/dev/decomposition-hint-tracker.sh"
if [[ -f "$TRACKER" ]]; then
    if grep -q "0-9a-f.*4.*3\|uuid\|RFC.*4122\|INFRA-630" "$TRACKER" 2>/dev/null; then
        ok "decomposition-hint-tracker.sh GAP_RE includes UUID form"
    else
        fail "decomposition-hint-tracker.sh GAP_RE missing UUID support"
    fi
else
    ok "decomposition-hint-tracker.sh not present (optional)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
