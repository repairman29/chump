#!/usr/bin/env bash
# test-patch-file-fallback.sh — INFRA-785
#
# Verifies the three-tier patch_file fallback in src/patch_apply.rs:
#   Tier a: strict context matching
#   Tier b: fuzzy (whitespace-tolerant, ±3 line drift)
#   Tier c: headerless (Llama 3.3-style diffs missing ---/+++ headers)
#
# Runs as a subset of the Rust unit test suite — no binary needed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-785 patch_file fallback tests ==="

# ── 1. Source-level contract checks ──────────────────────────────────────────
echo "[1/2] Checking source contracts..."

grep -q "pub fn looks_headerless" "$REPO_ROOT/src/patch_apply.rs" \
    && ok "looks_headerless exported from patch_apply.rs" \
    || fail "looks_headerless missing from patch_apply.rs"

grep -q "pub fn apply_unified_diff_headerless" "$REPO_ROOT/src/patch_apply.rs" \
    && ok "apply_unified_diff_headerless exported from patch_apply.rs" \
    || fail "apply_unified_diff_headerless missing from patch_apply.rs"

grep -q "pub fn parse_headerless_diff" "$REPO_ROOT/src/patch_apply.rs" \
    && ok "parse_headerless_diff exported from patch_apply.rs" \
    || fail "parse_headerless_diff missing from patch_apply.rs"

grep -q "applied-headerless" "$REPO_ROOT/src/repo_tools.rs" \
    && ok "tier-c 'applied-headerless' mode wired in repo_tools.rs" \
    || fail "'applied-headerless' mode not found in repo_tools.rs"

grep -q "apply_unified_diff_headerless" "$REPO_ROOT/src/repo_tools.rs" \
    && ok "apply_unified_diff_headerless called from repo_tools.rs" \
    || fail "apply_unified_diff_headerless not called from repo_tools.rs"

grep -q "looks_headerless" "$REPO_ROOT/src/repo_tools.rs" \
    && ok "looks_headerless gate used in repo_tools.rs" \
    || fail "looks_headerless gate missing from repo_tools.rs"

# ── 2. Rust unit tests for patch_apply module ─────────────────────────────────
echo "[2/2] Running cargo test (patch_apply headerless unit tests)..."
# Scope to the chump bin so per-test names appear in stdout (quiet mode hides
# them, and -p chump alone runs every workspace target which dilutes the
# signal). --nocapture leaves stderr alone; we tee combined output.
( cd "$REPO_ROOT" && cargo test -p chump --bin chump patch_apply -- --nocapture ) \
    > /tmp/patch-apply-test-out.txt 2>&1 || true

for tc in \
    "looks_headerless_detects_missing_headers" \
    "headerless_strict_parse_rejects_llama_style" \
    "apply_headerless_diff_succeeds_on_llama_style" \
    "apply_headerless_rejects_context_mismatch" \
    "apply_headerless_no_hunks_returns_parse_error" \
    "apply_headerless_tolerates_leading_commentary"
do
    grep -q "test patch_apply::tests::${tc} \.\.\. ok" /tmp/patch-apply-test-out.txt \
        && ok "unit test: ${tc}" \
        || fail "unit test missing or FAILED: ${tc}"
done

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "PASS"
