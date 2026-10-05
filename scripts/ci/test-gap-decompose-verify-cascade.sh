#!/usr/bin/env bash
# test-gap-decompose-verify-cascade.sh — regression test for INFRA-3464.
#
# `chump gap decompose --verify` picks a verifier provider: an explicit
# CHUMP_VERIFY_API_BASE/MODEL override is honored directly, but the
# no-override fallback used to hand-build a LocalOpenAIProvider pointed
# straight at https://api.anthropic.com/v1 keyed off ANTHROPIC_API_KEY —
# bespoke, no OAuth, no cascade fallback (broke for OAuth-only fleets).
# It must instead fall back to provider_cascade::build_provider(), the
# shared cascade (full auth ladder incl. OAuth, 429 backoff, slot fallback).
#
# This test greps the fallback block in src/main.rs (isolated by the
# "let suggestions = if verify {" .. "match verify_provider {" markers) and
# asserts:
#   (1) the no-override branch calls provider_cascade::build_provider().
#   (2) the bespoke direct-to-Anthropic literal is gone from that branch.
#   (3) the explicit-override branch (CHUMP_VERIFY_API_BASE/MODEL) is left
#       untouched — it still builds a LocalOpenAIProvider directly.
#
# Verified this test fails against the pre-INFRA-3464 source (commit
# a10f10227^) which hard-checked ANTHROPIC_API_KEY and hand-built a
# LocalOpenAIProvider at the literal Anthropic endpoint.
#
# Run:
#   ./scripts/ci/test-gap-decompose-verify-cascade.sh
#
# Exits non-zero on any failure.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAIN_RS="$REPO_ROOT/src/main.rs"

echo "=== INFRA-3464 gap-decompose --verify shared-cascade regression test ==="
echo

if [[ ! -f "$MAIN_RS" ]]; then
    fail "src/main.rs not found at $MAIN_RS"
    exit 1
fi

START_LINE=$(grep -n 'let suggestions = if verify {' "$MAIN_RS" | head -1 | cut -d: -f1)
if [[ -z "$START_LINE" ]]; then
    fail "could not locate 'let suggestions = if verify {' in src/main.rs"
    exit 1
fi
ok "located verify-provider selection block at line $START_LINE"

END_LINE=$(tail -n "+$START_LINE" "$MAIN_RS" | grep -n 'match verify_provider {' | head -1 | cut -d: -f1)
if [[ -z "$END_LINE" ]]; then
    fail "could not locate 'match verify_provider {' after line $START_LINE"
    exit 1
fi
END_LINE=$((START_LINE + END_LINE - 1))

BLOCK=$(sed -n "${START_LINE},${END_LINE}p" "$MAIN_RS")

if echo "$BLOCK" | grep -q 'provider_cascade::build_provider()'; then
    ok "fallback branch calls provider_cascade::build_provider()"
else
    fail "fallback branch does not call provider_cascade::build_provider() (bespoke provider regression?)"
fi

if echo "$BLOCK" | grep -qE '"https://api\.anthropic\.com'; then
    fail "fallback branch still hard-codes the direct Anthropic endpoint literal"
else
    ok "no hard-coded direct-to-Anthropic endpoint literal in the block"
fi

# The explicit CHUMP_VERIFY_API_BASE/MODEL override path is legitimate direct
# use and must remain — only the no-override fallback should route through
# the cascade.
if echo "$BLOCK" | grep -q 'LocalOpenAIProvider::new'; then
    ok "explicit CHUMP_VERIFY_API_BASE/MODEL override still builds a direct provider"
else
    fail "explicit override branch no longer builds a LocalOpenAIProvider — did the override path regress?"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
