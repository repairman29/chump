#!/usr/bin/env bash
# test-almanac-drift-extract.sh — CREDIBLE-569
#
# Stubs the almanac-mcp binary with a fixture JSON-RPC response (no live
# almanac checkout required in CI) and asserts almanac-drift-extract.sh:
#   1. writes the raw payload to a JSON file,
#   2. logs the number of drift flags retrieved,
#   3. exits 0 on a well-formed response, non-zero on a missing binary.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/almanac-mcp"
cat > "$STUB_BIN" <<'EOF'
#!/usr/bin/env bash
read -r _ >/dev/null
cat <<'JSON'
{"jsonrpc":"2.0","result":{"content":[{"text":"{\n  \"organ\": \"config\",\n  \"organs\": {\n    \"config\": {\n      \"count\": 42,\n      \"drift_count\": 3,\n      \"drift\": [\n        {\"flag\":\"FOO\",\"defaults\":[\"a\",\"b\"],\"reads\":5}\n      ]\n    }\n  }\n}"}]}}
JSON
EOF
chmod +x "$STUB_BIN"

OUT_FILE="$WORK/drift.json"
LOG="$(CHUMP_ALMANAC_MCP_BIN="$STUB_BIN" scripts/dev/almanac-drift-extract.sh chump --out "$OUT_FILE")"

echo "$LOG" | grep -q "retrieved 3 drift flag(s)" \
    || { echo "FAIL: log line did not report the expected drift count. Got: $LOG" >&2; exit 1; }

[[ -s "$OUT_FILE" ]] || { echo "FAIL: output file was not written" >&2; exit 1; }

python3 -c "
import json, sys
with open('$OUT_FILE') as f:
    data = json.load(f)
assert data['organs']['config']['drift_count'] == 3, data
assert data['organs']['config']['drift'][0]['flag'] == 'FOO', data
"

# Missing binary must fail loudly, not silently no-op.
if CHUMP_ALMANAC_MCP_BIN="$WORK/does-not-exist" scripts/dev/almanac-drift-extract.sh chump --out "$WORK/other.json" 2>/dev/null; then
    echo "FAIL: script should have exited non-zero for a missing almanac-mcp binary" >&2
    exit 1
fi

echo "OK: test-almanac-drift-extract.sh"
