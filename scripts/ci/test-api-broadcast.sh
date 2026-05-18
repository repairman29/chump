#!/usr/bin/env bash
# scripts/ci/test-api-broadcast.sh — INFRA-1296
#
# Verifies POST /api/broadcast end-to-end:
#   1. Valid STUCK posts → 200 + ambient line
#   2. Valid FEEDBACK posts → 200 + feedback.jsonl line
#   3. Invalid event name → 400
#   4. Missing subject on INTENT → 400
#   5. Missing kind on FEEDBACK → 400

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
[ -x "$BIN" ] || { echo "[test-api-broadcast] chump binary missing at $BIN; cargo build first" >&2; exit 1; }

PORT="${TEST_PORT:-13848}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; kill_server; exit 1; }

# Server in its own LOCK_DIR sandbox so we don't pollute the real ambient.
SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump-locks" "$SANDBOX_ROOT/scripts/coord/lib" "$SANDBOX_ROOT/scripts/dev"
# Copy the broadcast.sh + operator-id.sh into sandbox so the handler resolves them
cp "$REPO_ROOT/scripts/coord/broadcast.sh" "$SANDBOX_ROOT/scripts/coord/broadcast.sh"
cp "$REPO_ROOT/scripts/coord/lib/operator-id.sh" "$SANDBOX_ROOT/scripts/coord/lib/operator-id.sh"
git -C "$SANDBOX_ROOT" init -q
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t add -A
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t commit -q -m s

SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; }

start_server() {
    # Empty token disables auth (CHUMP_WEB_TOKEN unset).
    (cd "$SANDBOX_ROOT" && CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" "$BIN" --web) \
        > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    fail "server failed to start: $(tail -20 "$SERVER_LOG")"
}
start_server

post() {
    curl -s -o "$TMP/resp.body" -w '%{http_code}' \
        -H 'content-type: application/json' \
        -X POST "http://127.0.0.1:$PORT/api/broadcast" \
        -d "$1"
}

AMBIENT="$SANDBOX_ROOT/.chump-locks/ambient.jsonl"
FB="$SANDBOX_ROOT/.chump-locks/feedback.jsonl"

# ── Test 1: STUCK 200 + ambient line ──────────────────────────────────────
code=$(post '{"event":"STUCK","subject":"INFRA-9001","rationale":"test stuck"}')
[ "$code" = "200" ] || fail "STUCK expected 200, got $code, body: $(cat "$TMP/resp.body")"
[ -f "$AMBIENT" ] || fail "ambient.jsonl missing after STUCK"
grep -q '"event": "STUCK"' "$AMBIENT" || fail "STUCK not in ambient: $(cat "$AMBIENT")"
grep -q '"subject"\?' "$AMBIENT" || grep -q '"gap": "INFRA-9001"' "$AMBIENT" \
    || fail "subject INFRA-9001 not in ambient"
ok "STUCK 200 + lands in ambient.jsonl"

# ── Test 2: FEEDBACK 200 + feedback.jsonl line ───────────────────────────
code=$(post '{"event":"FEEDBACK","kind":"proposal","subject":"pwa-row-merge-state","rationale":"surface inline"}')
[ "$code" = "200" ] || fail "FEEDBACK expected 200, got $code, body: $(cat "$TMP/resp.body")"
[ -f "$FB" ] || fail "feedback.jsonl missing"
grep -q '"kind": "proposal"' "$FB" || fail "FEEDBACK proposal not in feedback.jsonl"
ok "FEEDBACK 200 + lands in feedback.jsonl"

# ── Test 3: invalid event → 400 ──────────────────────────────────────────
code=$(post '{"event":"BOGUS","subject":"x"}')
[ "$code" = "400" ] || fail "invalid event expected 400, got $code"
ok "invalid event → 400"

# ── Test 4: INTENT missing subject → 400 ─────────────────────────────────
code=$(post '{"event":"INTENT"}')
[ "$code" = "400" ] || fail "INTENT missing subject expected 400, got $code"
ok "INTENT missing subject → 400"

# ── Test 5: FEEDBACK missing kind → 400 ──────────────────────────────────
code=$(post '{"event":"FEEDBACK","subject":"sub"}')
[ "$code" = "400" ] || fail "FEEDBACK missing kind expected 400, got $code"
ok "FEEDBACK missing kind → 400"

# ── Test 6: ALERT missing kind → 400 ─────────────────────────────────────
code=$(post '{"event":"ALERT","rationale":"alert"}')
[ "$code" = "400" ] || fail "ALERT missing kind expected 400, got $code"
ok "ALERT missing kind → 400"

# ── Test 7: HANDOFF missing to_session AND recipient → 400 ───────────────
code=$(post '{"event":"HANDOFF","subject":"INFRA-99"}')
[ "$code" = "400" ] || fail "HANDOFF missing dst expected 400, got $code"
ok "HANDOFF missing destination → 400"

kill_server
echo
echo "All INFRA-1296 /api/broadcast tests passed."
