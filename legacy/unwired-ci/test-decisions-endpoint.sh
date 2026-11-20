#!/usr/bin/env bash
# scripts/ci/test-decisions-endpoint.sh — INFRA-1563
#
# Validates GET /api/decisions + POST /api/decisions/{id}/resolve:
#   1. Static wiring: handlers defined + module registered + routes wired
#   2. Event registry has operator_decision_needed / operator_decision_resolved
#   3. HTTP round-trip (if binary available):
#      - emit a synthetic operator_decision_needed event
#      - GET /api/decisions must include it
#      - POST resolve
#      - GET /api/decisions must no longer include it

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1563 /api/decisions test ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
grep -q 'handle_decisions_list' "$REPO_ROOT/src/routes/decisions.rs" \
    && ok "handle_decisions_list defined in src/routes/decisions.rs" \
    || fail "handle_decisions_list missing from src/routes/decisions.rs"

grep -q 'handle_decisions_resolve' "$REPO_ROOT/src/routes/decisions.rs" \
    && ok "handle_decisions_resolve defined in src/routes/decisions.rs" \
    || fail "handle_decisions_resolve missing from src/routes/decisions.rs"

grep -q 'pub mod decisions' "$REPO_ROOT/src/routes/mod.rs" \
    && ok "decisions module exported from src/routes/mod.rs" \
    || fail "src/routes/mod.rs does not export pub mod decisions"

grep -q '"/api/decisions"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/decisions route registered in web_server.rs" \
    || fail "/api/decisions route not registered in web_server.rs"

grep -q '/api/decisions/{id}/resolve' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/decisions/{id}/resolve route registered in web_server.rs" \
    || fail "/api/decisions/{id}/resolve route not registered in web_server.rs"

# ── 2. Event registry ───────────────────────────────────────────────────────
grep -q 'kind: operator_decision_needed' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    && ok "operator_decision_needed registered in EVENT_REGISTRY.yaml" \
    || fail "operator_decision_needed missing from EVENT_REGISTRY.yaml"

grep -q 'kind: operator_decision_resolved' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    && ok "operator_decision_resolved registered in EVENT_REGISTRY.yaml" \
    || fail "operator_decision_resolved missing from EVENT_REGISTRY.yaml"

# ── 3. Frontend wired ────────────────────────────────────────────────────────
grep -q "fetch('/api/decisions')" "$REPO_ROOT/web/v2/app.js" \
    && ok "frontend <chump-view-decisions> fetches /api/decisions" \
    || fail "frontend does not fetch /api/decisions"

grep -q '/resolve' "$REPO_ROOT/web/v2/app.js" \
    && ok "frontend wires the resolve action" \
    || fail "frontend missing resolve action wiring"

# ── 4. HTTP round-trip (if binary available) ────────────────────────────────
if [[ ! -x "$BIN" ]]; then
    echo "  [info] chump binary missing at $BIN; skipping HTTP round-trip"
    echo
    echo "=== Results: $PASS passed, $FAIL failed (HTTP tier skipped) ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

PORT="${TEST_PORT:-13858}"
TMP="$(mktemp -d)"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'kill_server; rm -rf "$TMP"' EXIT

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump" "$SANDBOX_ROOT/.chump-locks" "$SANDBOX_ROOT/docs"

SERVER_LOG="$TMP/server.log"
CHUMP_REPO="$SANDBOX_ROOT" \
    CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" \
    "$BIN" --web > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
    sleep 0.5
done
if ! curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    fail "server failed to start: $(tail -20 "$SERVER_LOG")"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# Empty ambient.jsonl → empty decisions array.
body=$(curl -s "http://127.0.0.1:$PORT/api/decisions")
[ "$body" = "[]" ] \
    && ok "empty ambient.jsonl -> empty decisions array" \
    || fail "expected [] with no ambient.jsonl, got: $body"

# Emit a synthetic operator_decision_needed event.
cat >> "$SANDBOX_ROOT/.chump-locks/ambient.jsonl" <<'EOF'
{"ts":"2026-09-25T00:00:00Z","kind":"operator_decision_needed","id":"dec-test-1","decision_kind":"merge_approval","gap_id":"INFRA-1563","pr_number":9999,"summary":"needs operator sign-off","priority":"P1"}
EOF

body=$(curl -s "http://127.0.0.1:$PORT/api/decisions")
has_id=$(printf '%s' "$body" | jq '[.[] | select(.id == "dec-test-1")] | length')
[ "$has_id" -eq 1 ] \
    && ok "pending decision appears in GET /api/decisions" \
    || fail "pending decision dec-test-1 not found in: $body"

kind=$(printf '%s' "$body" | jq -r '.[] | select(.id == "dec-test-1") | .kind')
[ "$kind" = "merge_approval" ] \
    && ok "decision kind carried through (merge_approval)" \
    || fail "expected kind=merge_approval, got $kind"

# Resolve it.
resolve_body=$(curl -s -X POST "http://127.0.0.1:$PORT/api/decisions/dec-test-1/resolve" \
    -H 'Content-Type: application/json' -d '{"response":"approved"}')
ok_field=$(printf '%s' "$resolve_body" | jq -r '.ok')
[ "$ok_field" = "true" ] \
    && ok "POST resolve returns ok:true" \
    || fail "POST resolve did not return ok:true: $resolve_body"

body=$(curl -s "http://127.0.0.1:$PORT/api/decisions")
has_id=$(printf '%s' "$body" | jq '[.[] | select(.id == "dec-test-1")] | length')
[ "$has_id" -eq 0 ] \
    && ok "resolved decision disappears from GET /api/decisions" \
    || fail "resolved decision dec-test-1 still present in: $body"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
