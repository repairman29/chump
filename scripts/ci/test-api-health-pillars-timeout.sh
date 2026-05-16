#!/usr/bin/env bash
# test-api-health-pillars-timeout.sh — INFRA-1466
#
# Source-level assertions that /api/health/pillars wraps its blocking
# std::process::Command with tokio::time::timeout so the async runtime
# is never blocked.  No running server required.
#
# Run: bash scripts/ci/test-api-health-pillars-timeout.sh
# Exit 0 = pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1466 /api/health/pillars async timeout assertions ==="
echo

# AC1: tokio::process::Command must replace std::process::Command inside handler
# Look for tokio::process::Command usage in the handle_health_pillars vicinity.
if grep -q "tokio::process::Command" "$WEB_SERVER"; then
    ok "tokio::process::Command found in web_server.rs (async, non-blocking)"
else
    fail "tokio::process::Command NOT found — handler may still use blocking std::process::Command"
fi

# AC2: tokio::time::timeout wraps the command
if grep -q "tokio::time::timeout" "$WEB_SERVER"; then
    ok "tokio::time::timeout found in web_server.rs"
else
    fail "tokio::time::timeout NOT found — handler has no bounded timeout"
fi

# AC3: health_timed_out field in response JSON
if grep -q "health_timed_out" "$WEB_SERVER"; then
    ok "health_timed_out field present in response JSON"
else
    fail "health_timed_out field NOT found — timeout signal missing from response"
fi

# AC4: CHUMP_FLEET_STATUS_GH_TIMEOUT_S env var is read (operator-tunable timeout)
if grep -q "CHUMP_FLEET_STATUS_GH_TIMEOUT_S" "$WEB_SERVER"; then
    ok "CHUMP_FLEET_STATUS_GH_TIMEOUT_S env var wired in web_server.rs"
else
    fail "CHUMP_FLEET_STATUS_GH_TIMEOUT_S NOT found — timeout not configurable"
fi

# AC5: std::process::Command is NOT used for the health call inside
# handle_health_pillars (the old blocking path must be gone).
# We verify by checking that the only std::process::Command calls in
# web_server.rs are NOT paired with the health --slo-check args.
if grep -A3 'std::process::Command::new' "$WEB_SERVER" \
      | grep -q '"health".*"--slo-check"\|--slo-check.*health'; then
    fail "std::process::Command still used for health --slo-check (blocking path not removed)"
else
    ok "std::process::Command not used for health --slo-check (old blocking path removed)"
fi

# AC6: env-var is documented in .env.example
ENV_EXAMPLE="$REPO_ROOT/.env.example"
if grep -q "CHUMP_FLEET_STATUS_GH_TIMEOUT_S" "$ENV_EXAMPLE"; then
    ok "CHUMP_FLEET_STATUS_GH_TIMEOUT_S documented in .env.example"
else
    fail "CHUMP_FLEET_STATUS_GH_TIMEOUT_S NOT in .env.example — env-var coverage check will fail"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
