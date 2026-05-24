#!/usr/bin/env bash
# test-detect-gap-failure-status-filter.sh — INFRA-1888 smoke test.
#
# Verifies that detect-gap-failure.sh skips status=done gaps:
#   1. CHUMP_DETECT_GAP_FAILURE_INCLUDE_DONE=0 (default): only open gap emits gap_failed
#   2. CHUMP_DETECT_GAP_FAILURE_INCLUDE_DONE=1 (bypass): both gaps emit gap_failed
#      + detect_gap_failure_lax event emitted
#   3. --dry-run: no events written to ambient
#
# Network-free: uses synthetic state.db + synthetic lease files.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/detect-gap-failure.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found/executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.chump-locks" "$TMP/.chump"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
DB="$TMP/.chump/state.db"

export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_LOCKS_DIR="$TMP/.chump-locks"
export REPO_ROOT="$TMP"
export CHUMP_STUCK_LEASE_S=1   # 1s threshold so test fixtures are always "stuck"
export CHUMP_STUCK_PR_S=1

# Seed state.db with two gaps: one open, one done
python3 - "$DB" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("""CREATE TABLE gaps (
    id TEXT PRIMARY KEY, status TEXT,
    domain TEXT, title TEXT, priority TEXT, effort TEXT,
    acceptance_criteria TEXT, description TEXT, notes TEXT,
    depends_on TEXT, closed_pr TEXT, closed_date TEXT,
    created_at TEXT, updated_at TEXT
)""")
conn.execute("INSERT INTO gaps VALUES ('INFRA-8881','open','INFRA','open gap','P1','xs','[]','','','[]',NULL,NULL,datetime('now'),datetime('now'))")
conn.execute("INSERT INTO gaps VALUES ('INFRA-8882','done','INFRA','done gap','P1','xs','[]','','','[]','2499','2026-05-24',datetime('now'),datetime('now'))")
conn.commit()
PYEOF

# Synthetic lease files for both gaps (old enough to trigger stuck-lease detection)
NOW_MINUS_10H=$(python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(hours=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

cat > "$TMP/.chump-locks/claim-INFRA-8881-test.json" <<EOF
{"gap_id":"INFRA-8881","taken_at":"$NOW_MINUS_10H","session":"test-session-open"}
EOF
cat > "$TMP/.chump-locks/claim-INFRA-8882-test.json" <<EOF
{"gap_id":"INFRA-8882","taken_at":"$NOW_MINUS_10H","session":"test-session-done"}
EOF

# ── Test 1: default mode — only open gap emits gap_failed ─────────────────────
echo "Test 1: default — only open gap triggers gap_failed"
> "$AMBIENT"
"$SCRIPT" 2>/dev/null || true
open_count=$({ grep -c '"gap_id":"INFRA-8881"' "$AMBIENT" 2>/dev/null; } || true)
done_count=$({ grep -c '"gap_id":"INFRA-8882"' "$AMBIENT" 2>/dev/null; } || true)
if [[ "$open_count" -ge 1 && "$done_count" -eq 0 ]]; then
    echo "  PASS (open=1, done=0)"
else
    echo "  FAIL: expected open>=1 done=0, got open=$open_count done=$done_count"
    cat "$AMBIENT"
    exit 1
fi

# ── Test 2: INCLUDE_DONE=1 bypass — both gaps emit + lax audit event ──────────
echo "Test 2: INCLUDE_DONE=1 bypass — both gaps emit + lax event"
> "$AMBIENT"
CHUMP_DETECT_GAP_FAILURE_INCLUDE_DONE=1 "$SCRIPT" 2>/dev/null || true
open_count=$({ grep -c '"gap_id":"INFRA-8881"' "$AMBIENT" 2>/dev/null; } || true)
done_count=$({ grep -c '"gap_id":"INFRA-8882"' "$AMBIENT" 2>/dev/null; } || true)
lax_count=$({ grep -c '"kind":"detect_gap_failure_lax"' "$AMBIENT" 2>/dev/null; } || true)
if [[ "$open_count" -ge 1 && "$done_count" -ge 1 && "$lax_count" -ge 1 ]]; then
    echo "  PASS (open=$open_count done=$done_count lax=$lax_count)"
else
    echo "  FAIL: expected open>=1 done>=1 lax>=1, got open=$open_count done=$done_count lax=$lax_count"
    cat "$AMBIENT"
    exit 1
fi

# ── Test 3: --dry-run writes nothing to ambient ────────────────────────────────
echo "Test 3: --dry-run writes nothing to ambient"
> "$AMBIENT"
"$SCRIPT" --dry-run 2>/dev/null || true
if [[ ! -s "$AMBIENT" ]]; then
    echo "  PASS"
else
    echo "  FAIL: --dry-run wrote to ambient"
    cat "$AMBIENT"
    exit 1
fi

echo
echo "All 3 detect-gap-failure status-filter smoke tests passed."
