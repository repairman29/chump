#!/usr/bin/env bash
# scripts/ci/test-decisions-endpoint.sh — INFRA-1563
#
# Validates GET /api/decisions + POST /api/decisions/{id}/resolve:
#   1. Static wiring: handlers defined + module registered + routes wired
#   2. Response shape keys (id / kind / gap_id / pr_number / summary /
#      priority / created_at)
#   3. Docs updated (WEB_API_REFERENCE.md, CLAUDE_GOTCHAS.md, EVENT_REGISTRY.yaml)
#   4. Frontend wired (web/v2/app.js fetches /api/decisions)
#   5. Empty/missing ambient stream: 200 (not 500) with empty array
#   6. HTTP round-trip (if binary available): emit a synthetic
#      operator_decision_needed event, GET /api/decisions, assert it
#      appears, POST resolve, assert it disappears.

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
grep -q 'fn handle_decisions_list' "$REPO_ROOT/src/routes/decisions.rs" \
    && ok "handle_decisions_list defined in src/routes/decisions.rs" \
    || fail "handle_decisions_list missing from src/routes/decisions.rs"

grep -q 'fn handle_decisions_resolve' "$REPO_ROOT/src/routes/decisions.rs" \
    && ok "handle_decisions_resolve defined in src/routes/decisions.rs" \
    || fail "handle_decisions_resolve missing from src/routes/decisions.rs"

grep -q 'pub mod decisions' "$REPO_ROOT/src/routes/mod.rs" \
    && ok "decisions module exported from src/routes/mod.rs" \
    || fail "src/routes/mod.rs does not export pub mod decisions"

grep -q '"/api/decisions"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/decisions route registered in web_server.rs" \
    || fail "/api/decisions route not registered in web_server.rs"

grep -q '"/api/decisions/{id}/resolve"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/decisions/{id}/resolve route registered in web_server.rs" \
    || fail "/api/decisions/{id}/resolve route not registered in web_server.rs"

# ── 2. Response shape keys ──────────────────────────────────────────────────
for key in id kind gap_id pr_number summary priority created_at; do
    grep -q "\"$key\"" "$REPO_ROOT/src/routes/decisions.rs" \
        && ok "response key '$key' present" \
        || fail "response key '$key' missing"
done

# ── 3. Docs updated ──────────────────────────────────────────────────────────
grep -q '/api/decisions' "$REPO_ROOT/docs/api/WEB_API_REFERENCE.md" \
    && ok "WEB_API_REFERENCE.md documents /api/decisions" \
    || fail "WEB_API_REFERENCE.md missing /api/decisions section"

grep -q 'Decisions queue' "$REPO_ROOT/docs/process/CLAUDE_GOTCHAS.md" \
    && ok "CLAUDE_GOTCHAS.md has a Decisions queue subsection" \
    || fail "CLAUDE_GOTCHAS.md missing Decisions queue subsection"

grep -q 'kind: operator_decision_needed' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    && ok "EVENT_REGISTRY.yaml registers operator_decision_needed" \
    || fail "EVENT_REGISTRY.yaml missing operator_decision_needed"

grep -q 'kind: operator_decision_resolved' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    && ok "EVENT_REGISTRY.yaml registers operator_decision_resolved" \
    || fail "EVENT_REGISTRY.yaml missing operator_decision_resolved"

# ── 4. Frontend wired ───────────────────────────────────────────────────────
grep -q "fetch('/api/decisions')" "$REPO_ROOT/web/v2/app.js" \
    && ok "frontend <chump-view-decisions> fetches /api/decisions" \
    || fail "frontend does not fetch /api/decisions"

grep -q '/resolve' "$REPO_ROOT/web/v2/app.js" \
    && ok "frontend posts to /api/decisions/{id}/resolve" \
    || fail "frontend does not post to the resolve endpoint"

# ── 5/6. HTTP round-trip (if binary available) ──────────────────────────────
if [[ ! -x "$BIN" ]]; then
    echo "  [info] chump binary missing at $BIN; skipping HTTP round-trip"
    echo
    echo "=== Results: $PASS passed, $FAIL failed (HTTP tier skipped) ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

PORT="${TEST_PORT:-13859}"
TMP="$(mktemp -d)"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'kill_server; rm -rf "$TMP"' EXIT

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump" "$SANDBOX_ROOT/.chump-locks"

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

# Empty ambient stream (not even a file yet) → 200 + empty array.
empty_body=$(curl -s "http://127.0.0.1:$PORT/api/decisions")
empty_len=$(printf '%s' "$empty_body" | jq 'length' 2>/dev/null || echo -1)
[ "$empty_len" = "0" ] \
    && ok "no ambient.jsonl yet → 200 + empty array" \
    || fail "expected empty array with no ambient.jsonl, got: $empty_body"

# Emit a synthetic operator_decision_needed event.
DEC_ID="dec-test-$$"
printf '{"ts":"2026-08-27T00:00:00Z","kind":"operator_decision_needed","id":"%s","priority":"normal","summary":"synthetic smoke-test decision","gap_id":"INFRA-0000"}\n' \
    "$DEC_ID" >> "$SANDBOX_ROOT/.chump-locks/ambient.jsonl"

body=$(curl -s "http://127.0.0.1:$PORT/api/decisions")
found=$(printf '%s' "$body" | jq --arg id "$DEC_ID" '[.[] | select(.id == $id)] | length')
[ "$found" = "1" ] \
    && ok "synthetic decision appears in GET /api/decisions" \
    || fail "synthetic decision $DEC_ID not found in: $body"

for key in id kind gap_id pr_number summary priority created_at; do
    has=$(printf '%s' "$body" | jq --arg id "$DEC_ID" --arg key "$key" \
        '[.[] | select(.id == $id)][0] | has($key)')
    [ "$has" = "true" ] \
        && ok "decision object has key '$key'" \
        || fail "decision object missing key '$key'"
done

# Resolve it.
resolve_code=$(curl -s -o /tmp/decisions_resolve.json -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/api/decisions/$DEC_ID/resolve" \
    -H 'Content-Type: application/json' -d '{"resolved_by":"ci-smoke-test"}')
[ "$resolve_code" = "200" ] \
    && ok "POST /api/decisions/$DEC_ID/resolve returns 200" \
    || fail "resolve returned $resolve_code: $(cat /tmp/decisions_resolve.json)"

after_body=$(curl -s "http://127.0.0.1:$PORT/api/decisions")
after_found=$(printf '%s' "$after_body" | jq --arg id "$DEC_ID" '[.[] | select(.id == $id)] | length')
[ "$after_found" = "0" ] \
    && ok "resolved decision disappears from GET /api/decisions" \
    || fail "resolved decision $DEC_ID still present: $after_body"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
