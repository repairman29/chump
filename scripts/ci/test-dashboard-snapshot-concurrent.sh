#!/usr/bin/env bash
# scripts/ci/test-dashboard-snapshot-concurrent.sh — INFRA-1498
#
# INFRA-1485 follow-up: build_dashboard_snapshot() (src/web_server.rs, used by
# GET /api/dashboard/stream) used to shell out to `pgrep` via blocking
# std::process::Command from inside an async handler, which could stall the
# whole tokio worker thread. Now it's async + tokio::process::Command.
#
# This test fires 10 concurrent /api/dashboard/stream connections (each one
# triggers a build_dashboard_snapshot() call immediately on connect) and
# asserts /api/health p95 latency stays under 500ms while they're in flight.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP"
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    for pid in "${STREAM_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

source "$(dirname "$0")/lib/discover-chump-bin.sh"
[[ -x "$CHUMP_BIN" ]] || fail "no chump binary at $CHUMP_BIN (set CHUMP_BIN)"

mkdir -p "$TMP/.chump-locks" "$TMP/logs"
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

# Fire 10 concurrent SSE connections against /api/dashboard/stream — each
# open triggers one build_dashboard_snapshot() call synchronously before the
# first event is emitted, so 10 concurrent opens exercise 10 concurrent
# pgrep calls.
declare -a STREAM_PIDS
for i in $(seq 1 10); do
    curl -sN --max-time 3 "http://127.0.0.1:$PORT/api/dashboard/stream" >"$TMP/stream-$i.out" 2>&1 &
    STREAM_PIDS+=($!)
done

# While those 10 are in flight, sample /api/health latency.
LATENCIES="$TMP/latencies.txt"
: >"$LATENCIES"
for _ in $(seq 1 20); do
    T=$(curl -s -o /dev/null -w '%{time_total}' "http://127.0.0.1:$PORT/api/health")
    echo "$T" >>"$LATENCIES"
    sleep 0.05
done

for pid in "${STREAM_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

python3 - "$LATENCIES" <<'EOF'
import sys
path = sys.argv[1]
vals = sorted(float(l.strip()) for l in open(path) if l.strip())
assert vals, "no latency samples collected"
p95_idx = max(0, int(len(vals) * 0.95) - 1)
p95 = vals[p95_idx]
assert p95 < 0.5, f"/api/health p95 latency {p95*1000:.0f}ms >= 500ms during 10 concurrent dashboard/stream opens"
EOF
ok "/api/health p95 latency stayed <500ms during 10 concurrent /api/dashboard/stream opens"

ok "ALL INFRA-1498 dashboard-snapshot-concurrent checks passed"
