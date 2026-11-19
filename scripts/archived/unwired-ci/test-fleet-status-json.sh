#!/usr/bin/env bash
# test-fleet-status-json.sh — CI schema test for fleet-status --json (INFRA-571)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
FLEET_STATUS="$REPO_ROOT/scripts/dispatch/fleet-status.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Run --json and capture output
output=$(bash "$FLEET_STATUS" --json 2>/dev/null) || fail "--json flag exited non-zero"

# Must be non-empty
[[ -n "$output" ]] || fail "output is empty"

# Must be valid JSON (python3 is the canonical dep in fleet-status.sh)
python3 - "$output" <<'PY' || fail "output is not valid JSON"
import json, sys
json.loads(sys.argv[1])
PY
pass "output is valid JSON"

# Validate required keys and value types
python3 - "$output" <<'PY' || fail "schema validation failed"
import json, sys

data = json.loads(sys.argv[1])

required = {
    "active_leases":      int,
    "ships_24h":          int,
    "pickable_count":     int,
    "waste_30m":          int,
    "fleet_workers_alive": int,
}

errors = []
for key, typ in required.items():
    if key not in data:
        errors.append(f"missing key: {key}")
    elif not isinstance(data[key], typ):
        errors.append(f"{key}: expected {typ.__name__}, got {type(data[key]).__name__} ({data[key]!r})")

if errors:
    for e in errors:
        print(f"  ERROR: {e}", file=sys.stderr)
    raise SystemExit(1)
PY
pass "all required keys present with correct types"

# Values must be >= -1 (pickable_count may be -1 when chump is unavailable)
python3 - "$output" <<'PY' || fail "value range check failed"
import json, sys

data = json.loads(sys.argv[1])
for key in ("active_leases", "ships_24h", "waste_30m", "fleet_workers_alive"):
    if data[key] < 0:
        print(f"  ERROR: {key} is negative ({data[key]})", file=sys.stderr)
        raise SystemExit(1)
if data["pickable_count"] < -1:
    print(f"  ERROR: pickable_count < -1 ({data['pickable_count']})", file=sys.stderr)
    raise SystemExit(1)
PY
pass "value range check passed"

echo
echo "ALL TESTS PASSED — fleet-status --json schema is valid"
echo "output: $output"
