#!/usr/bin/env bash
# scripts/ci/test-api-roadmap.sh — INFRA-1338
#
# Validates the GET /api/roadmap endpoint:
#   1. Static wiring: handler defined + module registered + route wired
#   2. 60s cache primitives present (OnceLock, RwLock, CACHE_TTL_SECS=60)
#   3. Response shape keys (milestones / generated_at_iso / roadmap_error)
#   4. Docs updated in WEB_API_REFERENCE.md
#   5. Frontend INFRA-1207 component consumes /api/roadmap (and removed
#      the client-side markdown fallback)
#   6. HTTP round-trip (if binary available): schema + cache idempotency
#      (second call within 60s returns same generated_at_iso)
#   7. Missing-file path: 200 (not 500) with empty milestones + error field

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1338 /api/roadmap test ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
grep -q 'handle_roadmap' "$REPO_ROOT/src/routes/roadmap.rs" \
    && ok "handle_roadmap defined in src/routes/roadmap.rs" \
    || fail "handle_roadmap missing from src/routes/roadmap.rs"

grep -q 'pub mod roadmap' "$REPO_ROOT/src/routes/mod.rs" \
    && ok "roadmap module exported from src/routes/mod.rs" \
    || fail "src/routes/mod.rs does not export pub mod roadmap"

grep -q '"/api/roadmap"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/roadmap route registered in web_server.rs" \
    || fail "/api/roadmap route not registered in web_server.rs"

# ── 2. 60s cache primitives ─────────────────────────────────────────────────
grep -q 'OnceLock' "$REPO_ROOT/src/routes/roadmap.rs" \
    && ok "OnceLock present" \
    || fail "OnceLock missing — required for in-process cache"

grep -q 'RwLock' "$REPO_ROOT/src/routes/roadmap.rs" \
    && ok "RwLock present" \
    || fail "RwLock missing — required for in-process cache"

grep -qE 'CACHE_TTL_SECS:[[:space:]]*u64[[:space:]]*=[[:space:]]*60' "$REPO_ROOT/src/routes/roadmap.rs" \
    && ok "CACHE_TTL_SECS = 60 constant present" \
    || fail "CACHE_TTL_SECS = 60 constant missing"

# ── 3. Response shape keys ──────────────────────────────────────────────────
for key in milestones generated_at_iso roadmap_error cache_age_secs; do
    grep -q "\"$key\"" "$REPO_ROOT/src/routes/roadmap.rs" \
        && ok "response key '$key' present" \
        || fail "response key '$key' missing"
done

# ── 4. Docs updated ─────────────────────────────────────────────────────────
grep -q '/api/roadmap' "$REPO_ROOT/docs/api/WEB_API_REFERENCE.md" \
    && ok "WEB_API_REFERENCE.md documents /api/roadmap" \
    || fail "WEB_API_REFERENCE.md missing /api/roadmap section"

# ── 5. Frontend wired ───────────────────────────────────────────────────────
grep -q "fetch('/api/roadmap')" "$REPO_ROOT/web/v2/app.js" \
    && ok "frontend <chump-view-roadmap> fetches /api/roadmap" \
    || fail "frontend does not fetch /api/roadmap"

# The client-side markdown parser fallback is gone post-INFRA-1338.
if grep -q '#parseMarkdown' "$REPO_ROOT/web/v2/app.js"; then
    fail "client-side #parseMarkdown fallback still present (INFRA-1338 should remove it)"
else
    ok "client-side #parseMarkdown fallback removed"
fi

# ── 6. HTTP round-trip (if binary available) ────────────────────────────────
if [[ ! -x "$BIN" ]]; then
    echo "  [info] chump binary missing at $BIN; skipping HTTP round-trip"
    echo
    echo "=== Results: $PASS passed, $FAIL failed (HTTP tier skipped) ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

PORT="${TEST_PORT:-13857}"
TMP="$(mktemp -d)"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'kill_server; rm -rf "$TMP"' EXIT

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump" "$SANDBOX_ROOT/.chump-locks" "$SANDBOX_ROOT/docs"

# Synthetic ROADMAP.md with two milestones — one shipped, one in progress.
cat > "$SANDBOX_ROOT/docs/ROADMAP.md" <<'EOF'
# Chump Roadmap — fixture

## Week 1 — Front door (May 6 → 13) ✅ SHIPPED

**Outcome.** A solo dev can run chump gen and get a working PR.

**Implementing gaps:**
- **INFRA-100** — gap one (P0 m)
- **INFRA-101** — gap two (P1 s)

---

## Week 3 — Orchestrator MVP (May 22 → 28) 🏗️ IN PROGRESS

**Outcome.** Operator types chump orchestrate and the fleet responds.

**Implementing gaps:**
- **INFRA-200** — gap (P1 m)
EOF

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

body=$(curl -s "http://127.0.0.1:$PORT/api/roadmap")
[ -n "$body" ] || fail "empty response from /api/roadmap"

# Top-level keys must be present (200 + JSON, never 500).
for key in milestones generated_at_iso cache_age_secs roadmap_error; do
    has=$(printf '%s' "$body" | jq "has(\"$key\")")
    [ "$has" = "true" ] \
        && ok "top-level key '$key' present" \
        || fail "top-level key '$key' missing in: $body"
done

# Milestones is an array; with the fixture we expect ≥1 entry.
ms_len=$(printf '%s' "$body" | jq '.milestones | length')
[ "$ms_len" -ge 1 ] \
    && ok "milestones array populated (len=$ms_len)" \
    || fail "milestones array empty (len=$ms_len)"

# Each milestone has id, title, status, done_ratio.
for field in id title status done_ratio progress_pct gaps; do
    has=$(printf '%s' "$body" | jq ".milestones[0] | has(\"$field\")")
    [ "$has" = "true" ] \
        && ok "milestones[0].$field present" \
        || fail "milestones[0].$field missing"
done

# First milestone status should be "done" (Week 1 has ✅ SHIPPED tag).
first_status=$(printf '%s' "$body" | jq -r '.milestones[0].status')
[ "$first_status" = "done" ] \
    && ok "Week 1 derived status=done from ✅ SHIPPED title tag" \
    || fail "Week 1: expected status=done, got '$first_status'"

# Cache idempotency: second call within 60s returns same generated_at_iso.
first_ts=$(printf '%s' "$body" | jq -r '.generated_at_iso')
sleep 1
body2=$(curl -s "http://127.0.0.1:$PORT/api/roadmap")
second_ts=$(printf '%s' "$body2" | jq -r '.generated_at_iso')
[ "$first_ts" = "$second_ts" ] && [ -n "$first_ts" ] \
    && ok "60s cache: generated_at_iso unchanged across calls ($first_ts)" \
    || fail "cache miss: first_ts=$first_ts second_ts=$second_ts"

# Cache age advances on second hit (>= 0).
cache_age_2=$(printf '%s' "$body2" | jq -r '.cache_age_secs')
[ "$cache_age_2" -ge 0 ] \
    && ok "cache_age_secs reports >=0 on second hit ($cache_age_2)" \
    || fail "cache_age_secs invalid on second hit: $cache_age_2"

# Missing-file path: rename ROADMAP.md, hit a separate port to bypass cache,
# expect 200 with empty milestones + roadmap_error populated.
kill_server
rm -f "$SANDBOX_ROOT/docs/ROADMAP.md"
PORT2="${TEST_PORT2:-13858}"
CHUMP_REPO="$SANDBOX_ROOT" \
    CHUMP_WEB_PORT="$PORT2" CHUMP_WEB_TOKEN="" \
    "$BIN" --web > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:$PORT2/api/health" >/dev/null 2>&1 && break
    sleep 0.5
done
if curl -sf "http://127.0.0.1:$PORT2/api/health" >/dev/null 2>&1; then
    code=$(curl -s -o /tmp/roadmap_miss.json -w '%{http_code}' "http://127.0.0.1:$PORT2/api/roadmap")
    miss_body="$(cat /tmp/roadmap_miss.json)"
    [ "$code" = "200" ] \
        && ok "missing ROADMAP.md returns HTTP 200 (not 500)" \
        || fail "missing ROADMAP.md returned $code (expected 200): $miss_body"
    miss_len=$(printf '%s' "$miss_body" | jq '.milestones | length')
    [ "$miss_len" = "0" ] \
        && ok "missing ROADMAP.md → empty milestones[]" \
        || fail "missing ROADMAP.md should yield empty milestones, got len=$miss_len"
    err_str=$(printf '%s' "$miss_body" | jq -r '.roadmap_error // ""')
    [ -n "$err_str" ] && [ "$err_str" != "null" ] \
        && ok "missing ROADMAP.md → roadmap_error populated ($err_str)" \
        || fail "missing ROADMAP.md should populate roadmap_error, got '$err_str'"
else
    fail "second server failed to start for missing-file test: $(tail -10 "$SERVER_LOG")"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
