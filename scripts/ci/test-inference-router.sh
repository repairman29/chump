#!/usr/bin/env bash
# test-inference-router.sh — INFRA-1843, CP-011 (bicameral-mind vendoring)
#
# Verifies src/inference_router.rs::route() decisions are deterministic and
# observable:
#   1. Module is wired into main.rs.
#   2. CHUMP_INFERENCE_TIER honors reflexive / neocortex / auto (default
#      reflexive), including the auto-mode escalation-on-retry rule.
#   3. Every route() call emits kind=inference_routed to ambient.jsonl.
#
# This is a synthetic in-process test (no docker mocks required) — it runs
# the module's own `cargo test` suite, which exercises the same CallContext
# / route() surface a real call site would use, then checks the ambient
# emission side-effect directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1843 inference_router smoke test ==="
echo

# 1. Module wired into main.rs.
if grep -q '^mod inference_router;' "$REPO_ROOT/src/main.rs"; then
    ok "inference_router module wired into main.rs"
else
    fail "mod inference_router; missing from main.rs"
fi

# 2. Vendoring lineage comment present.
if grep -q 'Vendored architectural pattern from repairman29/pixel-edge-server' \
    "$REPO_ROOT/src/inference_router.rs"; then
    ok "vendoring lineage comment present"
else
    fail "vendoring lineage comment missing from src/inference_router.rs"
fi

# 3. Run the module's unit tests: default tier, explicit reflexive/neocortex,
#    auto-mode escalation, and determinism — all exercised in-process.
AMBIENT_LOG="$(mktemp)"
trap 'rm -f "$AMBIENT_LOG"' EXIT

if CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    PATH="$HOME/.cargo/bin:$PATH" \
    cargo test --bin chump inference_router:: -- --test-threads=1 >/tmp/infra-1843-test.log 2>&1; then
    ok "cargo test inference_router:: (tier defaults, overrides, escalation, determinism)"
else
    fail "cargo test inference_router:: failed — see /tmp/infra-1843-test.log"
fi

# 4. Observability: route() calls during the test run emitted kind=inference_routed.
if [ -s "$AMBIENT_LOG" ] && grep -q '"kind":"inference_routed"' "$AMBIENT_LOG"; then
    ok "route() decisions observable via kind=inference_routed in ambient.jsonl"
else
    fail "no kind=inference_routed events found in ambient log"
fi

# 5. Each emitted event carries tier + call_site + attempt for downstream audit.
if [ -s "$AMBIENT_LOG" ] && grep '"kind":"inference_routed"' "$AMBIENT_LOG" \
    | grep -q '"tier":"\(reflexive\|neocortex\)"'; then
    ok "inference_routed events carry a valid tier field"
else
    fail "inference_routed events missing/invalid tier field"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
