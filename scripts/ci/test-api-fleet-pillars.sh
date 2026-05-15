#!/usr/bin/env bash
# scripts/ci/test-api-fleet-pillars.sh — INFRA-1339
#
# Verifies GET /api/fleet/pillars end-to-end against a synthetic state.db.
#   1. Static wiring: handler defined + route registered + cache wired
#   2. Shape: 4 pillar keys + mission key + ts present
#   3. Schema: each pillar entry has full field set
#   4. Grade derivation: 2 seeded EFFECTIVE-tagged gaps → effective.grade=A
#   5. 60s cache returns identical bytes on second hit
#   6. Docs reference /api/fleet/pillars

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="$REPO_ROOT/target/debug/chump"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1339 /api/fleet/pillars test ==="
echo

# ── 1. Static wiring checks (no binary needed) ─────────────────────────────
grep -q 'handle_fleet_pillars' "$REPO_ROOT/src/routes/health.rs" \
    && ok "handle_fleet_pillars defined in src/routes/health.rs" \
    || fail "handle_fleet_pillars missing from src/routes/health.rs"

grep -q 'api/fleet/pillars' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/fleet/pillars route registered in web_server.rs" \
    || fail "/api/fleet/pillars route missing from web_server.rs"

grep -q 'mission_grade::build_report' "$REPO_ROOT/src/routes/health.rs" \
    && ok "health.rs calls mission_grade::build_report (shared Rust module)" \
    || fail "health.rs does not call mission_grade::build_report"

grep -q 'PillarsSnapshot\|pillars_cache' "$REPO_ROOT/src/routes/health.rs" \
    && ok "60s in-process cache struct present" \
    || fail "in-process cache struct missing"

grep -q 'Duration::from_secs(60)' "$REPO_ROOT/src/routes/health.rs" \
    && ok "60-second TTL wired in handler" \
    || fail "60-second TTL not found in handler"

# ── 2. Docs ────────────────────────────────────────────────────────────────
grep -q 'fleet/pillars' "$REPO_ROOT/docs/api/WEB_API_REFERENCE.md" \
    && ok "WEB_API_REFERENCE.md documents /api/fleet/pillars" \
    || fail "WEB_API_REFERENCE.md missing /api/fleet/pillars section"

# ── 3. HTTP round-trip (requires binary) ───────────────────────────────────
if [[ ! -x "$BIN" ]]; then
    echo "  [info] chump binary missing at $BIN; skipping HTTP round-trip"
    echo
    echo "=== Results: $PASS passed, $FAIL failed (HTTP tier skipped) ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

PORT="${TEST_PORT:-13855}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill_server' EXIT

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump" "$SANDBOX_ROOT/.chump-locks" "$SANDBOX_ROOT/docs/gaps"

seed_gap() {
    local id="$1" title="$2"
    cat > "$SANDBOX_ROOT/docs/gaps/${id}.yaml" <<EOF
- id: $id
  domain: INFRA
  title: "$title"
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - one
    - two
EOF
}
# 2 EFFECTIVE pickable → grade A; 1 CREDIBLE → grade B; 1 RESILIENT → grade B;
# 0 ZERO-WASTE → grade F.
seed_gap "INFRA-9001" "EFFECTIVE: synthetic gap alpha"
seed_gap "INFRA-9002" "EFFECTIVE: synthetic gap beta"
seed_gap "INFRA-9003" "CREDIBLE: synthetic gap gamma"
seed_gap "INFRA-9004" "RESILIENT: synthetic gap delta"

# `chump gap list` auto-imports docs/gaps/*.yaml into state.db on first call
# when the DB is empty (INFRA-821). Run twice: first triggers import, second
# is a no-op confirmation.
CHUMP_REPO="$SANDBOX_ROOT" "$BIN" gap list >/dev/null 2>&1 || true
CHUMP_REPO="$SANDBOX_ROOT" "$BIN" gap list >/dev/null 2>&1 || true

SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }

start_server() {
    CHUMP_REPO="$SANDBOX_ROOT" \
        CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" \
        "$BIN" --web > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    fail "server failed to start: $(tail -40 "$SERVER_LOG")"
    return 1
}
start_server || { echo; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1; }

body=$(curl -s "http://127.0.0.1:$PORT/api/fleet/pillars")

# Shape check
for key in effective credible resilient zero_waste mission ts; do
    has=$(printf '%s' "$body" | jq "has(\"$key\")")
    if [ "$has" = "true" ]; then
        ok "top-level key $key present"
    else
        fail "top-level $key missing: $body"
    fi
done

# Pillar entry field check
for field in grade score count_pickable count_in_flight count_shipped_24h trend breach_reasons; do
    has=$(printf '%s' "$body" | jq ".effective | has(\"$field\")")
    if [ "$has" = "true" ]; then
        ok "effective.$field present"
    else
        fail "effective.$field missing"
    fi
done

# Grade derivation
eff_pickable=$(printf '%s' "$body" | jq -r '.effective.count_pickable')
eff_grade=$(printf '%s' "$body" | jq -r '.effective.grade')
if [ "$eff_pickable" -ge 2 ] && [ "$eff_grade" = "A" ]; then
    ok "effective.grade=A with count_pickable=$eff_pickable (>=2)"
else
    fail "effective: expected grade=A with pickable>=2, got grade=$eff_grade pickable=$eff_pickable"
fi

# 60s cache idempotency
body2=$(curl -s "http://127.0.0.1:$PORT/api/fleet/pillars")
if [ "$body" = "$body2" ]; then
    ok "60s cache returns identical bytes on second hit"
else
    fail "second call should return cached bytes"
fi

kill_server
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
