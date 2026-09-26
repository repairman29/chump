#!/usr/bin/env bash
# test-ast-crawler-bash.sh — INFRA-1821
#
# Regression guard for the bash top-level symbol extraction bug: crawl the
# repo's own scripts/ directory (hundreds of bash fn defs) and assert the
# crawler finds more than a token handful, not zero.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "=== INFRA-1821 ast-crawler bash symbol extraction test ==="
echo

SHAPE_JSON="$(mktemp)"
trap 'rm -f "$SHAPE_JSON"' EXIT

if cargo run --quiet -p chump-ast-crawler --bin crawl-cli -- scripts > "$SHAPE_JSON" 2>/dev/null; then
    ok "crawl-cli ran against scripts/"
else
    fail "crawl-cli failed to run against scripts/"
fi

BASH_SYMBOL_COUNT="$(python3 -c "
import json
d = json.load(open('$SHAPE_JSON'))
bash_files = [f for f in d['files'] if f['language'] == 'bash']
print(sum(len(f['top_level_symbols']) for f in bash_files))
")"

echo "  bash top-level symbol count: $BASH_SYMBOL_COUNT"
if [ "$BASH_SYMBOL_COUNT" -gt 100 ]; then
    ok "bash symbol count > 100 (got $BASH_SYMBOL_COUNT)"
else
    fail "bash symbol count <= 100 (got $BASH_SYMBOL_COUNT) — top-level fn scan regressed"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
