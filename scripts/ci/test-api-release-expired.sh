#!/usr/bin/env bash
# scripts/ci/test-api-release-expired.sh — PRODUCT-129
#
# Verifies POST /api/lease/release-expired:
#   1. Returns {ok, scanned, released_count, released_ids} shape
#   2. Expired leases are deleted from .chump-locks/
#   3. Non-expired leases are preserved
#   4. Leases with no expires_at are ignored (not deleted)
#   5. Returns scanned count matching total lease files examined
#
# Strategy: spin up chump --web on a random port, seed .chump-locks/ with
# 4 synthetic lease files (2 expired, 1 active, 1 no-expiry), call the
# endpoint, verify response + filesystem state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== PRODUCT-129: POST /api/lease/release-expired tests ==="
echo

source "$(dirname "$0")/lib/discover-chump-bin.sh"
if [[ ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="$(command -v chump 2>/dev/null || true)"
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "SKIP: no chump binary (set CHUMP_BIN or run cargo build first)" >&2
    exit 0
fi

# ── Seed .chump-locks/ with synthetic lease files ────────────────────────────
LOCKS="$TMP/.chump-locks"
mkdir -p "$LOCKS"

# Expired lease 1: ISO8601 expires_at in the past
cat > "$LOCKS/expired-iso-abc123.json" <<'JSON'
{"session_id":"expired-iso-abc123","gap_id":"INFRA-0001","expires_at":"1970-01-01T00:00:01Z"}
JSON

# Expired lease 2: unix-timestamp expires_at (epoch 1 = 1970, clearly past)
cat > "$LOCKS/expired-ts-def456.json" <<'JSON'
{"session":"expired-ts-def456","gap_id":"INFRA-0002","expires_at":1}
JSON

# Active lease: far-future expires_at (year 2099)
cat > "$LOCKS/active-ghi789.json" <<'JSON'
{"session_id":"active-ghi789","gap_id":"INFRA-0003","expires_at":"2099-01-01T00:00:00Z"}
JSON

# Lease with no expires_at: should be scanned but NOT deleted
cat > "$LOCKS/no-expiry-jkl000.json" <<'JSON'
{"session_id":"no-expiry-jkl000","gap_id":"INFRA-0004"}
JSON

# Also need a minimal state.db so the server starts cleanly
DB="$TMP/state.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS gaps (
  id TEXT PRIMARY KEY, domain TEXT NOT NULL, title TEXT NOT NULL,
  description TEXT DEFAULT '', priority TEXT NOT NULL,
  effort TEXT NOT NULL, status TEXT NOT NULL,
  acceptance_criteria TEXT DEFAULT '[]', depends_on TEXT DEFAULT '[]',
  notes TEXT DEFAULT '', source_doc TEXT DEFAULT '',
  created_at INTEGER NOT NULL, closed_at INTEGER,
  opened_date TEXT DEFAULT '', closed_date TEXT DEFAULT '',
  closed_pr INTEGER, skills_required TEXT DEFAULT '',
  preferred_backend TEXT DEFAULT '', preferred_machine TEXT DEFAULT '',
  estimated_minutes TEXT DEFAULT '', required_model TEXT DEFAULT ''
);
SQL

# Pick a random free port
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); print(p)')
LOG="$TMP/server.log"

CHUMP_REPO="$TMP" \
CHUMP_STATE_DB="$DB" \
CHUMP_BINARY_STALENESS_CHECK=0 \
    "$CHUMP_BIN" --web --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!

# Wait up to 10s for server to come up
for _ in $(seq 1 50); do
    sleep 0.2
    if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
done
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: server died at startup. Log:" >&2; cat "$LOG" >&2; exit 1
fi
if ! curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    echo "FAIL: server did not come up in 10s" >&2; cat "$LOG" >&2; exit 1
fi

# ── Call the endpoint ─────────────────────────────────────────────────────────
R="$TMP/response.json"
HTTP_STATUS=$(curl -s -o "$R" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/api/lease/release-expired")

echo "[1. HTTP status and response shape]"
if [[ "$HTTP_STATUS" == "200" ]]; then
    ok "endpoint returns HTTP 200"
else
    fail "endpoint returned HTTP $HTTP_STATUS (expected 200); body=$(cat "$R")"
fi

python3 - <<PYEOF
import json, sys
try:
    d = json.load(open("$R"))
except Exception as e:
    print(f"FAIL: non-JSON response: {e}")
    sys.exit(1)
for field in ("ok", "scanned", "released_count", "released_ids"):
    if field not in d:
        print(f"FAIL: response missing '{field}' field")
        sys.exit(1)
if d["ok"] is not True:
    print(f"FAIL: ok={d['ok']} expected True")
    sys.exit(1)
if not isinstance(d["released_ids"], list):
    print(f"FAIL: released_ids is not a list")
    sys.exit(1)
print("PASS response shape ok=true + scanned + released_count + released_ids")
PYEOF
ok "response JSON shape correct"

echo
echo "[2. Expired lease count]"
python3 - <<PYEOF
import json
d = json.load(open("$R"))
# Expect 2 expired leases deleted (expired-iso-abc123 + expired-ts-def456)
if d["released_count"] != 2:
    print(f"FAIL: released_count={d['released_count']} expected 2")
    raise SystemExit(1)
ids = set(d["released_ids"])
if "expired-iso-abc123" not in ids:
    print(f"FAIL: expired-iso-abc123 not in released_ids={ids}")
    raise SystemExit(1)
if "expired-ts-def456" not in ids:
    print(f"FAIL: expired-ts-def456 not in released_ids={ids}")
    raise SystemExit(1)
print("PASS released_count=2, both expired session IDs present")
PYEOF
ok "expired leases: count=2 with correct IDs"

echo
echo "[3. Filesystem state after release]"
if [[ ! -f "$LOCKS/expired-iso-abc123.json" ]]; then
    ok "expired ISO lease file removed from .chump-locks/"
else
    fail "expired-iso-abc123.json still exists — not deleted"
fi

if [[ ! -f "$LOCKS/expired-ts-def456.json" ]]; then
    ok "expired unix-timestamp lease file removed from .chump-locks/"
else
    fail "expired-ts-def456.json still exists — not deleted"
fi

echo
echo "[4. Non-expired lease preserved]"
if [[ -f "$LOCKS/active-ghi789.json" ]]; then
    ok "active (far-future) lease preserved"
else
    fail "active-ghi789.json was incorrectly deleted"
fi

echo
echo "[5. No-expiry lease preserved]"
if [[ -f "$LOCKS/no-expiry-jkl000.json" ]]; then
    ok "no-expiry lease preserved (not deleted)"
else
    fail "no-expiry-jkl000.json was incorrectly deleted"
fi

echo
echo "[6. Scanned count]"
python3 - <<PYEOF
import json
d = json.load(open("$R"))
# scanned must be >= 4 (all 4 files; ambient.jsonl might also be present)
if d["scanned"] < 4:
    print(f"FAIL: scanned={d['scanned']} expected >= 4")
    raise SystemExit(1)
print(f"PASS scanned={d['scanned']} >= 4")
PYEOF
ok "scanned count covers all synthetic lease files"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
