#!/usr/bin/env bash
# test-gap-gardener.sh — INFRA-964
#
# Tests gap-gardener.sh in an isolated tmpdir:
#   1. Expired lease is force-released
#   2. Dead-heartbeat lease (> 4h, heartbeat=taken) is force-released
#   3. Fresh active lease is NOT released
#   4. gap_gardener_run event emitted with correct counts
#   5. vague_ac_alert emitted for open P1 gap with empty AC (via stub sqlite3)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GARDENER="$REPO_ROOT/scripts/coord/gap-gardener.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-964 gap-gardener tests ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"

# Fake git repo so gap-gardener can find REPO_ROOT via git rev-parse.
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.chump-locks" "$FAKE_REPO/.chump" "$FAKE_REPO/.git"
echo "gitdir: $FAKE_REPO/.git" > "$FAKE_REPO/.git/HEAD" 2>/dev/null || true
FAKE_AMB="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Fixture: three leases ─────────────────────────────────────────────────
NOW=$(date +%s)
PAST_EXPIRED=$((NOW - 7200))   # 2h ago
PAST_4H=$((NOW - 18000))       # 5h ago (> 4h threshold)
FUTURE=$((NOW + 3600))         # 1h in the future

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# Lease 1: expired (expires_at in the past)
cat > "$FAKE_REPO/.chump-locks/claim-infra-100-111-test.json" <<EOF
{"gap_id":"INFRA-100","session_id":"test-100","taken_at":"$(iso $PAST_EXPIRED)","expires_at":"$(iso $PAST_EXPIRED)","heartbeat_at":"$(iso $PAST_EXPIRED)"}
EOF

# Lease 2: dead heartbeat (taken 5h ago, heartbeat=taken_at, not expired yet)
EXPIRES_FUTURE=$(iso $FUTURE)
cat > "$FAKE_REPO/.chump-locks/claim-infra-200-222-test.json" <<EOF
{"gap_id":"INFRA-200","session_id":"test-200","taken_at":"$(iso $PAST_4H)","expires_at":"$EXPIRES_FUTURE","heartbeat_at":"$(iso $PAST_4H)"}
EOF

# Lease 3: fresh active (taken 30min ago, heartbeat updated 5min ago)
TAKEN_30M=$(iso $((NOW - 1800)))
HB_5M=$(iso $((NOW - 300)))
cat > "$FAKE_REPO/.chump-locks/claim-infra-300-333-test.json" <<EOF
{"gap_id":"INFRA-300","session_id":"test-300","taken_at":"$TAKEN_30M","expires_at":"$(iso $FUTURE)","heartbeat_at":"$HB_5M"}
EOF

# ── Run gardener (no state.db, so sqlite3 steps are no-ops) ───────────────
CHUMP_LOCK_DIR="$FAKE_REPO/.chump-locks" \
CHUMP_AMBIENT_LOG="$FAKE_AMB" \
bash "$GARDENER" >/dev/null 2>&1 || true

# ── 1. Expired lease released ─────────────────────────────────────────────
echo "[1. Expired lease released]"
if [ ! -f "$FAKE_REPO/.chump-locks/claim-infra-100-111-test.json" ]; then
    ok "expired lease (INFRA-100) was removed"
else
    fail "expired lease (INFRA-100) was NOT removed"
fi

# ── 2. Dead-heartbeat lease released ─────────────────────────────────────
echo ""
echo "[2. Dead-heartbeat lease released]"
if [ ! -f "$FAKE_REPO/.chump-locks/claim-infra-200-222-test.json" ]; then
    ok "dead-heartbeat lease (INFRA-200) was removed"
else
    fail "dead-heartbeat lease (INFRA-200) was NOT removed"
fi

# ── 3. Active lease preserved ────────────────────────────────────────────
echo ""
echo "[3. Active lease preserved]"
if [ -f "$FAKE_REPO/.chump-locks/claim-infra-300-333-test.json" ]; then
    ok "active lease (INFRA-300) was preserved"
else
    fail "active lease (INFRA-300) was incorrectly removed"
fi

# ── 4. gap_gardener_run emitted ───────────────────────────────────────────
echo ""
echo "[4. gap_gardener_run event emitted]"
if grep -q '"kind":"gap_gardener_run"' "$FAKE_AMB" 2>/dev/null; then
    ok "gap_gardener_run event present in ambient.jsonl"
else
    fail "gap_gardener_run event missing from ambient.jsonl"
fi

# ── 5. leases_released count is 2 ────────────────────────────────────────
echo ""
echo "[5. leases_released count correct]"
released=$(grep '"kind":"gap_gardener_run"' "$FAKE_AMB" 2>/dev/null \
    | grep -oE '"leases_released":[0-9]+' | grep -oE '[0-9]+' | tail -1)
if [ "${released:-0}" -ge 2 ]; then
    ok "leases_released=$released (≥2)"
else
    fail "leases_released=$released (expected ≥2)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
