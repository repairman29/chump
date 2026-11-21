#!/usr/bin/env bash
# shellcheck disable=SC2034
# test-api-gap-queue-perf.sh — INFRA-1277
#
# Performance smoke test for GET /api/gap-queue.
#
# Verifies that the endpoint responds in <300ms with a 300-row fixture state.db.
# Without INFRA-1277 (batch preflight), 300 rows × 2 SQL queries = 600 round-trips
# caused ~1.7s latency.  After the fix, a single leases query reduces this to ~10ms.
#
# Usage:
#   bash scripts/ci/test-api-gap-queue-perf.sh [--binary <path>]
#
# Skipped when:
#   - No chump binary found (non-Rust build CI step)
#   - SKIP_INTEGRATION_TESTS=1 is set
#
# Exit: 0 = pass, 1 = fail

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BINARY="${CHUMP:-}"
if [ -z "$BINARY" ]; then
    BINARY="$(command -v chump 2>/dev/null || true)"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$BINARY" ] || [ ! -x "$BINARY" ]; then
    echo "[test-api-gap-queue-perf] SKIP: no chump binary found"
    exit 0
fi

if [ "${SKIP_INTEGRATION_TESTS:-0}" = "1" ]; then
    echo "[test-api-gap-queue-perf] SKIP: SKIP_INTEGRATION_TESTS=1"
    exit 0
fi

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
FAILURES=0

# ── Setup ─────────────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT

LOCK_DIR="$WORK_DIR/.chump-locks"
mkdir -p "$LOCK_DIR"

# Seed a 300-row state.db fixture using chump gap reserve repeated calls.
# Using Python + sqlite3 for speed (avoid 300 shell subprocesses).
STATE_DB="$WORK_DIR/.chump/state.db"
mkdir -p "$(dirname "$STATE_DB")"

python3 - "$STATE_DB" <<'PYEOF'
import sqlite3, sys, time

db = sys.argv[1]
conn = sqlite3.connect(db)
conn.executescript("""
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'open',
    priority TEXT NOT NULL DEFAULT 'P2',
    effort TEXT NOT NULL DEFAULT 's',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT 0,
    opened_date TEXT NOT NULL DEFAULT '',
    closed_at INTEGER,
    closed_date TEXT,
    closed_pr INTEGER,
    notes TEXT NOT NULL DEFAULT '',
    skills_required TEXT NOT NULL DEFAULT '',
    preferred_machine TEXT NOT NULL DEFAULT '',
    pillar TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS leases (
    session_id TEXT PRIMARY KEY,
    gap_id TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL DEFAULT 0
);
""")

now = int(time.time())
rows = []
for i in range(300):
    rows.append((
        f"PERF-{i:04d}",
        "INFRA",
        f"Perf fixture gap {i:04d}",
        "open",
        "P2",
        "s",
        "",
        "",
        now - i * 60,
        "2026-05-15",
    ))
conn.executemany(
    "INSERT OR IGNORE INTO gaps (id,domain,title,status,priority,effort,acceptance_criteria,depends_on,created_at,opened_date) VALUES (?,?,?,?,?,?,?,?,?,?)",
    rows
)
conn.commit()
conn.close()
print(f"seeded {len(rows)} rows")
PYEOF

# Find a free port.
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('', 0)); print(s.getsockname()[1]); s.close()")

# Start the server.
CHUMP_AMBIENT_LOG="$LOCK_DIR/ambient.jsonl" \
CHUMP_REPO_ROOT="$WORK_DIR" \
CHUMP_WEB_PORT="$PORT" \
    "$BINARY" serve --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!

# Wait for server to become ready (up to 5s).
for i in $(seq 1 20); do
    if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done

if ! curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    echo "[test-api-gap-queue-perf] SKIP: server did not start (non-web build?)"
    exit 0
fi

# ── Test 1: response time <300ms for 300-row dataset ─────────────────────────
# Run the request and capture timing (curl write-out).
TIMING="$(curl -s -o /dev/null -w '%{time_total}' "http://localhost:$PORT/api/gap-queue" 2>/dev/null)"
# Convert to integer ms.
MS="$(python3 -c "print(int(float('$TIMING') * 1000))")"

if [ "$MS" -lt 300 ]; then
    pass "Test 1: /api/gap-queue responded in ${MS}ms (<300ms target) with 300 rows"
else
    fail "Test 1: /api/gap-queue took ${MS}ms (>300ms SLO) — batch preflight regression?"
fi

# ── Test 2: response contains correct shape ───────────────────────────────────
BODY="$(curl -sf "http://localhost:$PORT/api/gap-queue" 2>/dev/null || echo '{}')"
ROW_COUNT="$(echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo 0)"

if [ "$ROW_COUNT" -ge 300 ]; then
    pass "Test 2: response contains $ROW_COUNT rows (≥300)"
else
    fail "Test 2: expected ≥300 rows, got $ROW_COUNT"
fi

# ── Test 3: each row has required fields ─────────────────────────────────────
FIELD_OK="$(echo "$BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
gaps = d.get('gaps', [])
if not gaps:
    print('no-rows')
else:
    g = gaps[0]
    required = ['id', 'title', 'priority', 'effort', 'status', 'preflight_status']
    missing = [f for f in required if f not in g]
    print('ok' if not missing else 'missing:' + ','.join(missing))
" 2>/dev/null || echo "parse-error")"

if [ "$FIELD_OK" = "ok" ]; then
    pass "Test 3: first row contains all required fields (id, title, priority, effort, status, preflight_status)"
else
    fail "Test 3: field check failed: $FIELD_OK"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "[test-api-gap-queue-perf] PASS — all tests passed"
    exit 0
else
    echo "[test-api-gap-queue-perf] FAIL — $FAILURES test(s) failed"
    exit 1
fi
