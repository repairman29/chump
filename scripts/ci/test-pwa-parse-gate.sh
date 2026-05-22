#!/usr/bin/env bash
# scripts/ci/test-pwa-parse-gate.sh — INFRA-1621
#
# PR-hygiene gate: every .js file at web/v2/*.js must be syntactically valid
# JavaScript. Catches truncation/syntax-error commits (like the 2026-05-14
# c64ddd676 mishap that truncated 5 PWA classes and went unnoticed for 3 days
# because no CI lane parsed the PWA's main JS file).
#
# The gate runs `node --check <file>` on each top-level web/v2/ JS file and
# fails the job on any parse error. Also self-verifies via a known-bad fixture
# so the gate itself can't silently rot (e.g. if node behavior changes).
#
# Usage: bash scripts/ci/test-pwa-parse-gate.sh
# Env:   CHUMP_PWA_PARSE_GATE_SKIP_SELFTEST=1  (skip the fixture self-test)
# Exit:  0 = all PWA JS files parse cleanly + self-test passed
#        1 = at least one PWA JS file has a syntax error, OR self-test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PWA_DIR="$REPO_ROOT/web/v2"

if ! command -v node >/dev/null 2>&1; then
    echo "FAIL INFRA-1621: node binary not on PATH (required for --check)"
    exit 1
fi

# ── Self-verification: assert the gate catches a known-bad file ─────────────
# Without this, a future Node version that quietly stops flagging certain
# syntax errors would silently rot the gate. The fixture has an unclosed
# brace; node --check must exit non-zero.
if [[ "${CHUMP_PWA_PARSE_GATE_SKIP_SELFTEST:-0}" != "1" ]]; then
    _fixture="$(mktemp /tmp/pwa-parse-fixture-XXXXXX.js)"
    trap 'rm -f "$_fixture"' EXIT
    cat > "$_fixture" <<'JS'
function broken( {
  return 42;
JS
    if node --check "$_fixture" >/dev/null 2>&1; then
        echo "FAIL INFRA-1621: self-test — node --check accepted a malformed fixture (gate is broken)"
        exit 1
    fi
    rm -f "$_fixture"
    trap - EXIT
fi

# ── The actual gate: every web/v2/*.js must parse ───────────────────────────
if [[ ! -d "$PWA_DIR" ]]; then
    echo "FAIL INFRA-1621: $PWA_DIR not found (expected web/v2/ in repo root)"
    exit 1
fi

failed=0
total=0
shopt -s nullglob
for f in "$PWA_DIR"/*.js; do
    total=$((total + 1))
    if ! out="$(node --check "$f" 2>&1)"; then
        rel="${f#"$REPO_ROOT/"}"
        echo "FAIL: $rel"
        echo "$out" | head -3 | sed 's/^/  /'
        failed=$((failed + 1))
    fi
done
shopt -u nullglob

if [[ $total -eq 0 ]]; then
    echo "FAIL INFRA-1621: no .js files found in $PWA_DIR (regression in repo layout?)"
    exit 1
fi

if [[ $failed -gt 0 ]]; then
    echo "FAIL INFRA-1621: $failed of $total web/v2/*.js file(s) failed node --check"
    exit 1
fi

echo "OK INFRA-1621: self-test passed, $total web/v2/*.js file(s) parse cleanly"
