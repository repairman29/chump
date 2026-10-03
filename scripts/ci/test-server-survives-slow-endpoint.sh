#!/usr/bin/env bash
# scripts/ci/test-server-survives-slow-endpoint.sh — INFRA-1496
#
# INFRA-1485 audited blocking std::process::Command shellouts on the async
# web-server request path; INFRA-1496 is one of the named residual sites
# (POST /api/broadcast -> scripts/coord/broadcast.sh). This smoke test
# proves the fix: with broadcast.sh replaced by an artificially slow stub
# (sleep 5), firing it 3x concurrently must NOT block the tokio runtime —
# GET /api/health p95 latency must stay well under 500ms throughout.
#
# Run: bash scripts/ci/test-server-survives-slow-endpoint.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
[ -x "$BIN" ] || { echo "[test] chump binary missing at $BIN; cargo build first" >&2; exit 1; }

PORT="${TEST_PORT:-13849}"
TMP="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): don't let workflow-injected env hijack
# this test's own $TMP sandbox.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; kill_server; exit 1; }

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump-locks" "$SANDBOX_ROOT/scripts/coord/lib"

# Artificially slow broadcast.sh stand-in — mirrors the real CLI shape
# (so handle_broadcast's argv building + exit-code handling still work)
# but sleeps 5s before emitting the ambient line, simulating a wedged
# broadcast.sh (slow disk, lock contention, etc).
cat > "$SANDBOX_ROOT/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
echo '{"ok":true,"event":"'"$2"'"}' >> "$(dirname "$0")/../../.chump-locks/ambient.jsonl"
exit 0
EOF
chmod +x "$SANDBOX_ROOT/scripts/coord/broadcast.sh"

git -C "$SANDBOX_ROOT" init -q
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t add -A
git -C "$SANDBOX_ROOT" -c user.email=t@t -c user.name=t commit -q -m s

SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; }

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

# Fire the slow broadcast.sh path 3x concurrently in the background.
BROADCAST_PIDS=()
for i in 1 2 3; do
    curl -s -o /dev/null \
        -H 'content-type: application/json' \
        -X POST "http://127.0.0.1:$PORT/api/broadcast" \
        -d '{"event":"WARN","rationale":"slow-endpoint-smoke-'"$i"'"}' &
    BROADCAST_PIDS+=("$!")
done

# Hammer /api/health concurrently while the 3 broadcasts are in flight
# (they sleep 5s each). Collect per-request latency in ms.
LATFILE="$TMP/latencies.txt"
: > "$LATFILE"
for _ in $(seq 1 40); do
    t=$(curl -s -o /dev/null -w '%{time_total}' "http://127.0.0.1:$PORT/api/health")
    awk -v t="$t" 'BEGIN{printf "%d\n", t*1000}' >> "$LATFILE"
    sleep 0.1
done

wait "${BROADCAST_PIDS[@]}" 2>/dev/null || true

# p95 = 38th of 40 sorted samples.
N=$(wc -l < "$LATFILE")
P95_IDX=$(( (N * 95 + 99) / 100 ))
[ "$P95_IDX" -lt 1 ] && P95_IDX=1
[ "$P95_IDX" -gt "$N" ] && P95_IDX="$N"
P95=$(sort -n "$LATFILE" | sed -n "${P95_IDX}p")

echo "[test] /api/health latencies (ms), p95 sample #$P95_IDX of $N: $P95"
[ -n "$P95" ] || fail "no latency samples collected"
[ "$P95" -lt 500 ] || fail "p95 /api/health latency ${P95}ms >= 500ms while broadcast.sh slow path in flight — runtime may be blocked"
ok "p95 /api/health latency ${P95}ms < 500ms while 3x concurrent slow broadcast.sh in flight"

kill_server
echo
echo "All INFRA-1496 slow-endpoint survival tests passed."
