#!/usr/bin/env bash
# scripts/ci/test-server-survives-slow-endpoint.sh — INFRA-1485 / INFRA-1496
#
# Verifies that a slow shellout inside an axum handler does NOT block the
# tokio runtime and starve /api/health. INFRA-1496 covers the
# /api/broadcast → scripts/coord/broadcast.sh shellout specifically:
# broadcast.sh is swapped for a fixture that sleeps 5s, hit 3x concurrently,
# while /api/health is hammered in parallel — p95 must stay < 500ms.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
[ -x "$BIN" ] || { echo "[test-server-survives-slow-endpoint] chump binary missing at $BIN; cargo build first" >&2; exit 1; }

PORT="${TEST_PORT:-13849}"
TMP="$(mktemp -d)"

unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; kill_server; exit 1; }

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump-locks" "$SANDBOX_ROOT/scripts/coord/lib"
# Fixture broadcast.sh: sleeps 5s (artificially slow) then behaves like the
# real script enough to satisfy the handler (exit 0, no output required).
cat > "$SANDBOX_ROOT/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
exit 0
EOF
chmod +x "$SANDBOX_ROOT/scripts/coord/broadcast.sh"
git -C "$SANDBOX_ROOT" init -q
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t add -A
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t commit -q -m s

SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; }

start_server() {
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

# ── Fire 3 concurrent slow /api/broadcast calls (each blocks 5s in
# broadcast.sh) while hammering /api/health and recording latency. ──────
BROADCAST_PIDS=()
for _ in 1 2 3; do
    curl -s -o /dev/null \
        -H 'content-type: application/json' \
        -X POST "http://127.0.0.1:$PORT/api/broadcast" \
        -d '{"event":"WARN","rationale":"slow-endpoint smoke"}' &
    BROADCAST_PIDS+=("$!")
done

LATENCIES_FILE="$TMP/latencies.txt"
: > "$LATENCIES_FILE"
# Hammer /api/health for ~3s while the broadcasts are in flight.
END=$((SECONDS + 3))
while [ "$SECONDS" -lt "$END" ]; do
    t=$(curl -s -o /dev/null -w '%{time_total}' "http://127.0.0.1:$PORT/api/health")
    echo "$t" >> "$LATENCIES_FILE"
    sleep 0.05
done

wait "${BROADCAST_PIDS[@]}" 2>/dev/null

SAMPLE_COUNT=$(wc -l < "$LATENCIES_FILE" | tr -d ' ')
[ "$SAMPLE_COUNT" -gt 0 ] || fail "no /api/health samples collected"

# p95 in ms via sort + index (nearest-rank method).
P95_MS=$(sort -n "$LATENCIES_FILE" | awk -v n="$SAMPLE_COUNT" '
    BEGIN { idx = int(n * 0.95); if (idx < 1) idx = 1; if (idx > n) idx = n }
    { lines[NR] = $1 }
    END { printf "%.0f", lines[idx] * 1000 }
')

echo "  /api/health samples=$SAMPLE_COUNT p95=${P95_MS}ms (while 3x broadcast.sh sleeping 5s each)"

if [ "$P95_MS" -lt 500 ]; then
    ok "/api/health p95 (${P95_MS}ms) stays < 500ms while broadcast.sh is slow 3x concurrently"
else
    fail "/api/health p95 (${P95_MS}ms) regressed >= 500ms — broadcast.sh shellout is blocking the runtime"
fi

kill_server
echo
echo "All INFRA-1496 slow-endpoint smoke tests passed."
