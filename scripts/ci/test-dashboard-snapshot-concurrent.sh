#!/usr/bin/env bash
# scripts/ci/test-dashboard-snapshot-concurrent.sh — INFRA-1498
#
# INFRA-1485 follow-up: build_dashboard_snapshot() (src/web_server.rs, inside
# handle_dashboard_stream) used to shell out to `pgrep` via blocking
# std::process::Command from inside an async handler — a slow/hung pgrep
# would stall the whole tokio worker thread and regress /api/health latency
# for every other in-flight request. This test asserts that opening N
# concurrent /api/dashboard/stream SSE connections (each of which invokes
# build_dashboard_snapshot() on connect) does not push /api/health p95
# latency above 500ms.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
SSE_PIDS=()
cleanup() {
    for p in "${SSE_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

source "$(dirname "$0")/lib/discover-chump-bin.sh"
[[ -x "$CHUMP_BIN" ]] || fail "no chump binary at $CHUMP_BIN (set CHUMP_BIN)"

SHIP_LOG_DIR="$TMP/.chump/ship_log"
mkdir -p "$SHIP_LOG_DIR" "$TMP/.chump-locks"
NOW_EPOCH="$(date +%s)"
printf '[%s] Round 1 (ship) ok\n' "$NOW_EPOCH" > "$SHIP_LOG_DIR/ship-log.txt"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG="$TMP/server.log"

CHUMP_REPO="$TMP" \
CHUMP_BINARY_STALENESS_CHECK=0 \
    "$CHUMP_BIN" --web --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null \
    || fail "server failed to start (log: $(cat "$LOG"))"

# Open 10 concurrent SSE dashboard streams — each triggers
# build_dashboard_snapshot() (and its internal pgrep call) on connect.
for i in $(seq 1 10); do
    curl -sN --max-time 5 "http://127.0.0.1:$PORT/api/dashboard/stream" \
        -H "Accept: text/event-stream" >/dev/null 2>&1 &
    SSE_PIDS+=("$!")
done

# While those 10 streams are live, hammer /api/health and measure p95.
LATENCIES="$TMP/latencies.txt"
: > "$LATENCIES"
for _ in $(seq 1 40); do
    T0=$(python3 -c 'import time; print(time.time())')
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null
    T1=$(python3 -c 'import time; print(time.time())')
    python3 -c "print(($T1-$T0)*1000)" >> "$LATENCIES"
done

for p in "${SSE_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
SSE_PIDS=()

python3 - "$LATENCIES" <<'EOF'
import sys
path = sys.argv[1]
vals = sorted(float(l) for l in open(path) if l.strip())
assert vals, "no latency samples collected"
idx = max(0, int(len(vals) * 0.95) - 1)
p95 = vals[idx]
print(f"p95 latency: {p95:.1f}ms over {len(vals)} samples")
assert p95 < 500, f"/api/health p95 latency {p95:.1f}ms >= 500ms while 10 concurrent dashboard streams were open"
EOF
ok "/api/health p95 < 500ms with 10 concurrent /api/dashboard/stream connections"

ok "ALL INFRA-1498 dashboard-snapshot-concurrent checks passed"
