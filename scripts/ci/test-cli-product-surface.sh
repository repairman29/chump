#!/usr/bin/env bash
# scripts/ci/test-cli-product-surface.sh — CREDIBLE-036
#
# Verifies the product-surface CLI commands are wired in source:
# chump gen, mcp list/install, session-track, waste-tally, lesson-grade.
# Runs the Rust integration tests in tests/cli_product_surface.rs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"

PASS=0; FAIL=0
ok()   { echo "ok: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# ── Source-level wiring checks (fast, no binary needed) ────────────────────

echo "Running tests/cli_product_surface.rs..."
if cargo test --test cli_product_surface --quiet 2>&1; then
    ok "tests/cli_product_surface.rs: all 16 source-level assertions pass"
else
    fail "tests/cli_product_surface.rs: one or more assertions failed"
fi

# ── Spot-check: CLI_TEST_COVERAGE.md documents these commands ──────────────

COV_DOC="$ROOT/docs/process/CLI_TEST_COVERAGE.md"
for cmd in "chump gen" "chump mcp list" "chump waste-tally" "chump lesson-grade" "chump session-track"; do
    grep -q "$cmd" "$COV_DOC" 2>/dev/null \
        && ok "CLI_TEST_COVERAGE.md documents '$cmd'" \
        || fail "CLI_TEST_COVERAGE.md missing '$cmd'"
done

echo ""
echo "CREDIBLE-036: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
