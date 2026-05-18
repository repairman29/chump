#!/usr/bin/env bash
# test-api-fleet-health.sh — INFRA-1334
#
# Validates the GET /api/fleet/health endpoint:
#  1. Static wiring: handler defined + route registered + cache present
#  2. Top-level shape: pillars / kpis / slo / graphql_budget / ts keys
#  3. Pillar sub-keys: each pillar has grade/score/count_pickable/...
#  4. KPIs sub-keys: ships_24h / open_count / claimed_count / waste_rate_pct
#  5. SLO sub-keys: status / breach_count / breaches
#  6. Docs updated
#  7. HTTP round-trip (if binary available): grade derivation + cache idempotency

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1334 /api/fleet/health test ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
grep -q 'handle_fleet_health' "$REPO_ROOT/src/routes/health.rs" \
    && ok "handle_fleet_health defined in src/routes/health.rs" \
    || fail "handle_fleet_health missing from src/routes/health.rs"

grep -q 'api/fleet/health' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/fleet/health route registered in web_server.rs" \
    || fail "/api/fleet/health route missing from web_server.rs"

grep -q 'fleet_health_cache\|FleetHealthSnapshot' "$REPO_ROOT/src/routes/health.rs" \
    && ok "60s in-process cache struct present" \
    || fail "in-process cache struct missing"

grep -q 'Duration::from_secs(60)' "$REPO_ROOT/src/routes/health.rs" \
    && ok "60-second TTL present" \
    || fail "60-second TTL not found"

# ── 2. Observability ────────────────────────────────────────────────────────
grep -q 'chump::fleet_health' "$REPO_ROOT/src/routes/health.rs" \
    && ok "tracing::info! with chump::fleet_health target present" \
    || fail "tracing::info! missing from handle_fleet_health"

# ── 3. Response shape keys ──────────────────────────────────────────────────
for key in pillars kpis slo graphql_budget ts; do
    grep -q "\"$key\"" "$REPO_ROOT/src/routes/health.rs" \
        && ok "response key '$key' present" \
        || fail "response key '$key' missing"
done

# ── 4. KPI field keys ───────────────────────────────────────────────────────
for field in ships_24h open_count claimed_count waste_rate_pct; do
    grep -q "\"$field\"" "$REPO_ROOT/src/routes/health.rs" \
        && ok "kpi field '$field' present" \
        || fail "kpi field '$field' missing"
done

# ── 5. SLO field keys ───────────────────────────────────────────────────────
for field in breach_count breaches; do
    grep -q "\"$field\"" "$REPO_ROOT/src/routes/health.rs" \
        && ok "slo field '$field' present" \
        || fail "slo field '$field' missing"
done

# ── 6. Docs ─────────────────────────────────────────────────────────────────
grep -q 'fleet/health' "$REPO_ROOT/docs/api/WEB_API_REFERENCE.md" \
    && ok "WEB_API_REFERENCE.md documents /api/fleet/health" \
    || fail "WEB_API_REFERENCE.md missing /api/fleet/health section"

# ── 7. HTTP round-trip ──────────────────────────────────────────────────────
if [[ ! -x "$BIN" ]]; then
    echo "  [info] chump binary missing at $BIN; skipping HTTP round-trip"
    echo
    echo "=== Results: $PASS passed, $FAIL failed (HTTP tier skipped) ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

PORT="${TEST_PORT:-13856}"
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
# 2 EFFECTIVE + 1 CREDIBLE → effective=A credible=B resilient=F zero_waste=F
seed_gap "INFRA-9001" "EFFECTIVE: health fixture alpha"
seed_gap "INFRA-9002" "EFFECTIVE: health fixture beta"
seed_gap "INFRA-9003" "CREDIBLE: health fixture gamma"

(cd "$SANDBOX_ROOT" && CHUMP_REPO="$SANDBOX_ROOT" "$BIN" gap sync >/dev/null 2>&1) || true

SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }

CHUMP_REPO="$SANDBOX_ROOT" \
    CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" \
    "$BIN" --web > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
done
if ! curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    fail "server failed to start: $(tail -20 "$SERVER_LOG")"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

body=$(curl -s "http://127.0.0.1:$PORT/api/fleet/health")

# Top-level shape
for key in pillars kpis slo ts; do
    has=$(printf '%s' "$body" | jq "has(\"$key\")")
    [ "$has" = "true" ] \
        && ok "top-level key '$key' present" \
        || fail "top-level '$key' missing: $body"
done

# Pillar sub-keys
for field in grade score count_pickable count_in_flight count_shipped_24h trend breach_reasons; do
    has=$(printf '%s' "$body" | jq ".pillars.effective | has(\"$field\")")
    [ "$has" = "true" ] \
        && ok "pillars.effective.$field present" \
        || fail "pillars.effective.$field missing"
done

# KPI sub-keys
for field in ships_24h open_count claimed_count waste_rate_pct; do
    has=$(printf '%s' "$body" | jq ".kpis | has(\"$field\")")
    [ "$has" = "true" ] \
        && ok "kpis.$field present" \
        || fail "kpis.$field missing"
done

# SLO sub-keys
for field in status breach_count breaches; do
    has=$(printf '%s' "$body" | jq ".slo | has(\"$field\")")
    [ "$has" = "true" ] \
        && ok "slo.$field present" \
        || fail "slo.$field missing"
done

# Grade derivation
eff_grade=$(printf '%s' "$body" | jq -r '.pillars.effective.grade')
eff_pickable=$(printf '%s' "$body" | jq -r '.pillars.effective.count_pickable')
[ "$eff_grade" = "A" ] && [ "$eff_pickable" -ge 2 ] \
    && ok "effective.grade=A with count_pickable=$eff_pickable (>=2)" \
    || fail "effective: expected grade=A with pickable>=2, got grade=$eff_grade pickable=$eff_pickable"

# Cache idempotency
body2=$(curl -s "http://127.0.0.1:$PORT/api/fleet/health")
[ "$body" = "$body2" ] \
    && ok "60s cache returns identical bytes on second hit" \
    || fail "second call should return cached bytes"

kill_server
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
