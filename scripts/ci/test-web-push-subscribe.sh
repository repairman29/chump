#!/usr/bin/env bash
# scripts/ci/test-web-push-subscribe.sh — INFRA-1301
#
# Smoke checks for Web Push subscription infrastructure:
#   1. VAPID gen produces well-formed 65-byte P-256 key
#   2. VAPID gen is idempotent
#   3. GET /api/push/vapid-public-key falls back to .chump/push-keys.json
#   4. POST /api/push/subscribe stores endpoint (uses existing Phase 3.1 endpoint)
#   5. Service worker has push + notificationclick handlers
#   6. push-subscribe.js exposes enable/disable + integrates with REST

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="$REPO_ROOT/target/debug/chump"
GEN="$REPO_ROOT/scripts/setup/gen-vapid-keys.sh"
SW="$REPO_ROOT/web/v2/sw.js"
SUB_JS="$REPO_ROOT/web/v2/push-subscribe.js"
HTML="$REPO_ROOT/web/v2/index.html"
[ -x "$BIN" ] || { echo "[test] chump binary missing at $BIN; cargo build first" >&2; exit 1; }

PORT="${TEST_PORT:-13851}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Test 1: VAPID gen produces well-formed 65-byte key ─────────────────
SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m s
CHUMP_PUSH_KEYS_FILE="$SANDBOX/.chump/push-keys.json" bash "$GEN" >/dev/null
pub=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('vapid_public_key',''))" "$SANDBOX/.chump/push-keys.json")
python3 -c "
import base64, sys
key = sys.argv[1]
raw = base64.urlsafe_b64decode(key + '==')
assert len(raw) == 65, f'expected 65-byte raw, got {len(raw)}'
assert raw[0] == 0x04, f'expected 0x04 prefix, got 0x{raw[0]:02x}'
" "$pub" || fail "VAPID public key wrong shape: $pub"
ok "VAPID gen produces 65-byte P-256 uncompressed point"

# ── Test 2: idempotent ─────────────────────────────────────────────────
out=$(CHUMP_PUSH_KEYS_FILE="$SANDBOX/.chump/push-keys.json" bash "$GEN")
echo "$out" | grep -q "already present" || fail "re-run should be no-op: $out"
pub2=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('vapid_public_key',''))" "$SANDBOX/.chump/push-keys.json")
[ "$pub" = "$pub2" ] || fail "key should remain stable across re-runs"
ok "VAPID gen idempotent"

# ── Test 3: start server + GET /api/push/vapid-public-key falls back to file ─
(cd "$SANDBOX" && CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" "$BIN" --web) > "$TMP/srv.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break; sleep 0.5; done
resp=$(curl -s "http://127.0.0.1:$PORT/api/push/vapid-public-key")
got=$(echo "$resp" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('vapid_public_key',''))")
[ "$got" = "$pub" ] || fail "GET should return file-resident key; got '$got' expected '$pub'"
ok "GET /api/push/vapid-public-key falls back to .chump/push-keys.json"

# ── Test 4: env var still wins over file ──────────────────────────────
kill "$SERVER_PID" 2>/dev/null
sleep 1
PORT2=$((PORT + 100))   # well outside Test 5+ reuse range
(cd "$SANDBOX" && CHUMP_WEB_PORT="$PORT2" CHUMP_WEB_TOKEN="" CHUMP_VAPID_PUBLIC_KEY="env-override-key" "$BIN" --web) > "$TMP/srv2.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$PORT2/api/health" >/dev/null && break; sleep 0.5; done
got=$(curl -s "http://127.0.0.1:$PORT2/api/push/vapid-public-key" | \
    python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('vapid_public_key',''))")
[ "$got" = "env-override-key" ] || fail "env var should override file; got '$got'"
ok "CHUMP_VAPID_PUBLIC_KEY env var wins over file"
PORT="$PORT2"  # remaining tests target this server

# ── Test 5: POST /api/push/subscribe stores endpoint ───────────────────
code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' \
    -X POST "http://127.0.0.1:$PORT/api/push/subscribe" \
    -d '{"endpoint":"https://example.com/p/abc","keys":{"p256dh":"x","auth":"y"}}')
[ "$code" = "204" ] || fail "subscribe expected 204, got $code"
ok "POST /api/push/subscribe persists endpoint"

# ── Test 6: service worker has push + notificationclick ────────────────
grep -q "addEventListener('push'" "$SW" || fail "sw.js missing push handler"
grep -q "addEventListener('notificationclick'" "$SW" || fail "sw.js missing notificationclick"
ok "sw.js exposes push + notificationclick handlers"

# ── Test 7: push-subscribe.js wiring ───────────────────────────────────
grep -q "chumpEnablePush" "$SUB_JS" || fail "missing chumpEnablePush"
grep -q "chumpDisablePush" "$SUB_JS" || fail "missing chumpDisablePush"
grep -q "/api/push/vapid-public-key" "$SUB_JS" || fail "client must fetch VAPID key"
grep -q "/api/push/subscribe" "$SUB_JS" || fail "client must POST subscribe"
grep -q "/api/push/unsubscribe" "$SUB_JS" || fail "client must POST unsubscribe on disable"
ok "push-subscribe.js exposes enable/disable + REST integration"

# ── Test 8: script tag registered ──────────────────────────────────────
grep -q 'src="push-subscribe.js"' "$HTML" || fail "push-subscribe.js not registered"
ok "push-subscribe.js registered in index.html"

echo
echo "All INFRA-1301 Web Push subscription tests passed."
