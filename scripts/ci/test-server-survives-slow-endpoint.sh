#!/usr/bin/env bash
# scripts/ci/test-server-survives-slow-endpoint.sh — INFRA-1496
#
# INFRA-1485 audited web_server.rs for blocking std::process::Command
# shellouts on the async request path; INFRA-1496 is one of the named
# residual sites: POST /api/broadcast shells out to scripts/coord/broadcast.sh
# via a blocking Command::output(). This test proves that a slow
# broadcast.sh does NOT stall the tokio runtime — GET /api/health must stay
# fast even while 3 concurrent /api/broadcast calls are stuck in a slow
# broadcast.sh.
#
# Run: bash scripts/ci/test-server-survives-slow-endpoint.sh
# Exit 0 = pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
[ -x "$BIN" ] || { echo "[test-server-survives-slow-endpoint] chump binary missing at $BIN; cargo build first" >&2; exit 1; }

PORT="${TEST_PORT:-13849}"
TMP="$(mktemp -d)"
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump-locks" "$SANDBOX_ROOT/scripts/coord/lib"

# A deliberately slow stand-in for broadcast.sh (AC4: artificially slow
# broadcast.sh, sleep 5) so we can prove /api/health does not regress.
cat > "$SANDBOX_ROOT/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
echo '{"ok":true}'
EOF
chmod +x "$SANDBOX_ROOT/scripts/coord/broadcast.sh"

git -C "$SANDBOX_ROOT" init -q
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t add -A
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t commit -q -m s

SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; }
trap 'kill_server; rm -rf "$TMP"' EXIT

start_server() {
    (cd "$SANDBOX_ROOT" && CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" "$BIN" --web) \
        > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    fail "server failed to start: $(tail -20 "$SERVER_LOG")"
    exit 1
}
start_server

# Fire 3 concurrent /api/broadcast calls that each block ~5s inside the slow
# broadcast.sh, running in the background.
for i in 1 2 3; do
    curl -s -o /dev/null \
        -H 'content-type: application/json' \
        -X POST "http://127.0.0.1:$PORT/api/broadcast" \
        -d '{"event":"STUCK","subject":"INFRA-1496-load","rationale":"slow-endpoint test"}' &
done

# While those 3 are in flight, hammer /api/health and record latencies (ms).
LAT_FILE="$TMP/latencies.txt"
: > "$LAT_FILE"
for _ in $(seq 1 20); do
    start_ns=$(date +%s%N)
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1
    end_ns=$(date +%s%N)
    echo $(( (end_ns - start_ns) / 1000000 )) >> "$LAT_FILE"
    sleep 0.1
done

wait

# p95 over the 20 samples = the 19th of 20 sorted values.
P95=$(sort -n "$LAT_FILE" | sed -n '19p')
[ -n "$P95" ] || P95=$(sort -n "$LAT_FILE" | tail -1)

echo "latencies (ms): $(tr '\n' ' ' < "$LAT_FILE")"
echo "p95: ${P95}ms"

if [ "$P95" -lt 500 ]; then
    ok "/api/health p95 (${P95}ms) stays under 500ms while 3 concurrent broadcast.sh calls are slow"
else
    fail "/api/health p95 (${P95}ms) regressed past 500ms — broadcast.sh shellout may be blocking the runtime"
fi

kill_server

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
