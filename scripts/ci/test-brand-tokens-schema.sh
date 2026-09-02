#!/usr/bin/env bash
# test-brand-tokens-schema.sh — CI smoke test for EFFECTIVE-636
#
# Validates docs/schemas/examples/brand-tokens.*.example.json against
# docs/schemas/brand-tokens.schema.json using python's jsonschema.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCHEMA="$REPO_ROOT/docs/schemas/brand-tokens.schema.json"
EXAMPLE_DIR="$REPO_ROOT/docs/schemas/examples"
PASS=0
FAIL=0

_ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

echo "=== brand-tokens schema smoke test ==="

if [[ ! -f "$SCHEMA" ]]; then
    echo "FATAL: $SCHEMA not found" >&2
    exit 2
fi

if ! python3 -c "import jsonschema" 2>/dev/null; then
    echo "SKIP: python3 jsonschema module not available" >&2
    exit 0
fi

shopt -s nullglob
examples=("$EXAMPLE_DIR"/brand-tokens.*.example.json)
shopt -u nullglob

if [[ ${#examples[@]} -eq 0 ]]; then
    _fail "no example token files found under $EXAMPLE_DIR"
fi

for ex in "${examples[@]}"; do
    if python3 -c "
import json, sys
import jsonschema

with open('$SCHEMA') as f:
    schema = json.load(f)
with open('$ex') as f:
    instance = json.load(f)

jsonschema.validate(instance=instance, schema=schema)
" 2>/tmp/brand-tokens-schema-err.$$; then
        _ok "$(basename "$ex") validates against schema"
    else
        _fail "$(basename "$ex") failed schema validation: $(cat /tmp/brand-tokens-schema-err.$$)"
    fi
    rm -f /tmp/brand-tokens-schema-err.$$
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
