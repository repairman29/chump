#!/usr/bin/env bash
# scripts/ci/test-brain-graph-renderer.sh — INFRA-1558
#
# Smoke test for the brain graph visualization renderer: spins up the dev
# server, hits /brain, asserts HTTP 200 + DOM contains #cy-container +
# Cytoscape script is loaded. Also checks the supporting API surface
# (/api/brain/node/{id}, /api/brain/graph/stream) exists and responds.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
[ -x "$BIN" ] || { echo "[test] chump binary missing at $BIN; cargo build first" >&2; exit 1; }

PORT="${TEST_PORT:-13871}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── static: required files present ──────────────────────────────────────
[ -f "$REPO_ROOT/web/v2/brain.html" ] || fail "web/v2/brain.html missing"
[ -f "$REPO_ROOT/web/v2/brain.js" ] || fail "web/v2/brain.js missing"
grep -q 'cy-container' "$REPO_ROOT/web/v2/brain.html" || fail "brain.html missing #cy-container"
grep -q 'cytoscape' "$REPO_ROOT/web/v2/brain.html" || fail "brain.html does not load cytoscape"
ok "static: brain.html + brain.js present, brain.html references cytoscape + #cy-container"

SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/web"
cp -r "$REPO_ROOT/web/v2" "$SANDBOX/web/v2"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m s

(cd "$SANDBOX" && CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" "$BIN" --web) > "$TMP/srv.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break; sleep 0.5; done

# ── Test 1: GET /brain returns 200 + expected DOM ───────────────────────
resp=$(curl -s -o "$TMP/brain.html" -w '%{http_code}' "http://127.0.0.1:$PORT/brain")
[ "$resp" = "200" ] || fail "/brain returned $resp (expected 200): $(cat "$TMP/brain.html")"
grep -q 'id="cy-container"' "$TMP/brain.html" || fail "/brain response missing #cy-container"
grep -q 'cytoscape' "$TMP/brain.html" || fail "/brain response missing cytoscape script tag"
ok "/brain returns 200 with #cy-container + cytoscape script"

# ── Test 2: GET /v2/brain.js is served (static) ─────────────────────────
resp=$(curl -s -o "$TMP/brain.js" -w '%{http_code}' "http://127.0.0.1:$PORT/v2/brain.js")
[ "$resp" = "200" ] || fail "/v2/brain.js returned $resp (expected 200)"
grep -q 'cytoscape' "$TMP/brain.js" || fail "/v2/brain.js missing expected content"
ok "/v2/brain.js served statically"

# ── Test 3: GET /api/brain/graph.json still works (pre-existing endpoint) ─
resp=$(curl -s -o "$TMP/graph.json" -w '%{http_code}' "http://127.0.0.1:$PORT/api/brain/graph.json")
[ "$resp" = "200" ] || fail "/api/brain/graph.json returned $resp (expected 200)"
ok "/api/brain/graph.json returns 200"

# ── Test 4: GET /api/brain/node/{id} on an absent node returns 404 (not 500) ─
resp=$(curl -s -o "$TMP/node.json" -w '%{http_code}' "http://127.0.0.1:$PORT/api/brain/node/does-not-exist")
[ "$resp" = "404" ] || fail "/api/brain/node/<missing> returned $resp (expected 404)"
ok "/api/brain/node/{id} returns 404 for an absent node"

# ── Test 5: GET /api/brain/graph/stream opens an SSE connection ─────────
resp=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:$PORT/api/brain/graph/stream")
[ "$resp" = "200" ] || fail "/api/brain/graph/stream returned $resp (expected 200)"
ok "/api/brain/graph/stream opens an SSE connection"

echo "[test-brain-graph-renderer] all checks passed"
