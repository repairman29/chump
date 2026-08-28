#!/usr/bin/env bash
# test-ast-crawler-bash.sh — INFRA-1821
#
# Regression test: the AST crawler's bash parser must find function
# definitions at any depth (not just direct children of the tree root), or
# the whole bash surface silently produces 0 symbols (Opus #1 finding
# 2026-05-23 against echeo, PR #2412 — "Bash dominates source file count
# but produces 0 symbols").
#
# Runs crawl-cli against scripts/ and asserts the bash symbol count is well
# above zero (Chump has hundreds of bash fns under scripts/).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "=== INFRA-1821 ast-crawler bash symbol extraction test ==="
echo

echo "  [build] cargo run -p chump-ast-crawler --bin crawl-cli (quiet)..."
SHAPE_JSON="$(cargo run --quiet -p chump-ast-crawler --bin crawl-cli -- scripts 2>/tmp/ast-crawler-bash-test-stderr.log)"
BUILD_STATUS=$?

if [[ "$BUILD_STATUS" -ne 0 || -z "$SHAPE_JSON" ]]; then
    fail "crawl-cli failed to run against scripts/ (see /tmp/ast-crawler-bash-test-stderr.log)"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "crawl-cli ran against scripts/"

BASH_SYMBOL_COUNT="$(echo "$SHAPE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
total = sum(
    len(f.get('top_level_symbols', []))
    for f in data.get('files', [])
    if f.get('language') == 'bash'
)
print(total)
")"

if [[ "$BASH_SYMBOL_COUNT" -gt 100 ]]; then
    ok "bash symbol count > 100 (got $BASH_SYMBOL_COUNT)"
else
    fail "bash symbol count should be > 100, got $BASH_SYMBOL_COUNT — top-level bash scan may be missing nested function_definition nodes again"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
