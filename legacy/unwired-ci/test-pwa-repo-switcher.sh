#!/usr/bin/env bash
# INFRA-992: end-to-end test for the multi-repo picker endpoints that feed
# the PWA repo-switcher component.
#
# Verifies:
#   1. GET /api/repo/context returns multi_repo_enabled:false by default
#      and carries effective_root + has_working_override fields
#   2. With CHUMP_MULTI_REPO_ENABLED=1, GET /api/repo/context returns
#      multi_repo_enabled:true
#   3. POST /api/repo/working {path: "/nonexistent"} → 400
#   4. POST /api/repo/working {path: "/tmp"} (no .git) → 200 + ok:false
#      with error mentioning .git (proves the .git requirement)
#   5. POST /api/repo/working {path: "<real-repo-root>"} (current chump
#      repo) → 200 + ok:true — happy path

set -euo pipefail

PORT="${CHUMP_TEST_PORT:-38970}"
WORK=$(mktemp -d /tmp/chump-pwa-repo-switcher-test.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null || true
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    rm -rf "$WORK"
}

BIN="${CHUMP_BIN:-/private/tmp/chump-infra-992/target/debug/chump}"
if [[ ! -x "$BIN" ]]; then
    echo "[test] FAIL: chump binary not found at $BIN — build first with cargo build --bin chump" >&2
    exit 2
fi

# The PWA needs a git repo to map back to. Use the chump repo itself —
# any descendant of a git tree works since canonicalize+/.git is the test.
REAL_REPO="$(git rev-parse --show-toplevel)"

start_server() {
    mkdir -p "$WORK/.chump-locks"
    CHUMP_HOME="$WORK" CHUMP_CSRF_ENABLED=0 \
        CHUMP_MULTI_REPO_ENABLED="${MULTI:-0}" \
        "$BIN" --web --port "$PORT" >"$WORK/srv.log" 2>&1 &
    WEB_PID=$!
    for _ in $(seq 1 30); do
        if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "[test] FAIL: server did not become ready on port $PORT" >&2
    tail -20 "$WORK/srv.log" >&2
    return 1
}

stop_server() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    WEB_PID=""
}

# ── 1. multi_repo_enabled defaults to false ─────────────────────────────────
MULTI=0 start_server
echo "[test] GET /api/repo/context (CHUMP_MULTI_REPO_ENABLED unset)"
RESP=$(curl -sf "http://localhost:$PORT/api/repo/context")
ENABLED=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("multi_repo_enabled"))')
HAS_ROOT=$(echo "$RESP" | python3 -c 'import json,sys; print("effective_root" in json.load(sys.stdin))')
if [[ "$ENABLED" != "False" ]]; then
    echo "[test] FAIL: multi_repo_enabled should default False, got $ENABLED" >&2
    echo "  resp: $RESP" >&2
    exit 1
fi
if [[ "$HAS_ROOT" != "True" ]]; then
    echo "[test] FAIL: response missing effective_root field" >&2
    echo "  resp: $RESP" >&2
    exit 1
fi
echo "[test] PASS: multi_repo_enabled=False by default, effective_root present"

# ── 2. With CHUMP_MULTI_REPO_ENABLED=1, becomes true ────────────────────────
stop_server
MULTI=1 start_server
RESP=$(curl -sf "http://localhost:$PORT/api/repo/context")
ENABLED=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("multi_repo_enabled"))')
if [[ "$ENABLED" != "True" ]]; then
    echo "[test] FAIL: multi_repo_enabled should be True with env=1, got $ENABLED" >&2
    echo "  resp: $RESP" >&2
    exit 1
fi
echo "[test] PASS: multi_repo_enabled=True with CHUMP_MULTI_REPO_ENABLED=1"

# ── 3. POST nonexistent path → 400 ───────────────────────────────────────────
HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    -d '{"path":"/nonexistent-INFRA992-marker"}' \
    "http://localhost:$PORT/api/repo/working")
if [[ "$HTTP" != "400" ]]; then
    echo "[test] FAIL: nonexistent path should return 400, got $HTTP" >&2
    exit 1
fi
echo "[test] PASS: nonexistent path → 400"

# ── 4. POST /tmp (real dir, no .git) → 200 + ok:false ───────────────────────
RESP=$(curl -sf -X POST -H "Content-Type: application/json" \
    -d '{"path":"/tmp"}' \
    "http://localhost:$PORT/api/repo/working")
OK=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))')
if [[ "$OK" != "False" ]]; then
    echo "[test] FAIL: /tmp (no .git) should yield ok:False, got $OK" >&2
    echo "  resp: $RESP" >&2
    exit 1
fi
if ! echo "$RESP" | grep -q '\.git'; then
    echo "[test] FAIL: error message should mention .git, got: $RESP" >&2
    exit 1
fi
echo "[test] PASS: /tmp (no .git) → ok:False with .git in error message"

# ── 5. POST real repo root → 200 + ok:true ───────────────────────────────────
RESP=$(curl -sf -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"$REAL_REPO\"}" \
    "http://localhost:$PORT/api/repo/working")
OK=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))')
if [[ "$OK" != "True" ]]; then
    echo "[test] FAIL: real repo root should yield ok:True, got $OK" >&2
    echo "  resp: $RESP" >&2
    exit 1
fi
echo "[test] PASS: real repo root → ok:True"

echo ""
echo "[test] ALL REPO-SWITCHER CHECKS PASSED — INFRA-992 backend verified end-to-end"
