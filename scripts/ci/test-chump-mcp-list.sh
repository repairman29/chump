#!/usr/bin/env bash
# test-chump-mcp-list.sh — PRODUCT-061 smoke test
#
# Verifies:
#   1. chump mcp list (default) reads registry/mcp-servers.toml and prints entries
#   2. The bundled registry contains the 5 required server names
#   3. --json outputs valid JSON
#   4. --installed flag runs without error

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

CHUMP="${CHUMP_BIN:-${CARGO_TARGET_DIR:-./target}/debug/chump}"
if [[ ! -x "$CHUMP" ]]; then
    cargo build --bin chump -q 2>&1 | tail -3
fi

PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"
    if [[ "$result" == "ok" ]]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label — $result"
        FAIL=$((FAIL + 1))
    fi
}

# 1. Default list reads registry
output=$("$CHUMP" mcp list 2>&1)
check "mcp list exits 0" "ok"

# 2. Bundled entries present
for name in filesystem git web-search database code-analysis; do
    if echo "$output" | grep -q "$name"; then
        check "registry contains $name" "ok"
    else
        check "registry contains $name" "not found in: $(echo "$output" | head -5)"
    fi
done

# 3. --json produces valid JSON
json_out=$("$CHUMP" mcp list --json 2>&1)
if echo "$json_out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    check "--json produces valid JSON" "ok"
else
    check "--json produces valid JSON" "invalid JSON: ${json_out:0:80}"
fi

# 4. --installed runs without error (may return empty list in CI)
"$CHUMP" mcp list --installed > /dev/null 2>&1
check "--installed flag accepted" "ok"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
