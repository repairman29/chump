#!/usr/bin/env bash
# test-fleet-brief.sh — INFRA-721
#
# Verifies `chump fleet brief` Rust subcommand:
#   1. Outputs the header line
#   2. Counts commit events as ships (not kind=commit)
#   3. Counts alert events by kind (pr_stuck, silent_agent)
#   4. --json flag emits valid JSON with required fields
#   5. Exits 0 and doesn't fall through to rest of main()
#   6. Reads ambient.jsonl from CHUMP_REPO (not CWD)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN"
    echo "  Run: cargo build --bin chump"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Build a synthetic CHUMP_REPO with ambient.jsonl and state.db ──────────────
mkdir -p "$TMP/repo/.chump-locks"
mkdir -p "$TMP/repo/.chump"

NOW_TS="$(date -u +%s)"
RECENT_ISO="$(date -u -r "$((NOW_TS - 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$((NOW_TS - 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
OLD_ISO="2026-01-01T00:00:00Z"
ALERT_RECENT_ISO="$(date -u -r "$((NOW_TS - 600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$((NOW_TS - 600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# Write ambient.jsonl with:
#   - 3 commit events in 24h window
#   - 1 commit event older than 24h (should not be counted)
#   - 2 pr_stuck alerts (recent)
#   - 1 silent_agent alert (recent, within 30m)
#   - 1 silent_agent alert (old, outside 30m but within 24h)
cat >"$TMP/repo/.chump-locks/ambient.jsonl" <<EOF
{"ts":"$RECENT_ISO","event":"commit","sha":"aaa00001","msg":"test ship 1","session":"s1","worktree":"wt1"}
{"ts":"$RECENT_ISO","event":"commit","sha":"aaa00002","msg":"test ship 2","session":"s1","worktree":"wt1"}
{"ts":"$RECENT_ISO","event":"commit","sha":"aaa00003","msg":"test ship 3","session":"s2","worktree":"wt2"}
{"ts":"$OLD_ISO","event":"commit","sha":"aaa00099","msg":"old ship outside window","session":"s3","worktree":"wt3"}
{"ts":"$RECENT_ISO","event":"alert","kind":"pr_stuck","pr":1001,"reason":"CI red","session":"s1"}
{"ts":"$RECENT_ISO","event":"alert","kind":"pr_stuck","pr":1002,"reason":"DIRTY","session":"s2"}
{"ts":"$ALERT_RECENT_ISO","event":"ALERT","kind":"silent_agent","note":"session=s3 gap=INFRA-X last_event_age=99m","session":"monitor"}
{"ts":"$OLD_ISO","event":"ALERT","kind":"silent_agent","note":"old silent agent outside 30m","session":"monitor"}
EOF

# ── Test 1: header line present ───────────────────────────────────────────────
echo "Test 1: output contains fleet brief header"
OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief 2>/dev/null)"
if echo "$OUT" | grep -q "Fleet brief"; then
    echo "  PASS"
else
    echo "  FAIL: missing Fleet brief header"
    echo "$OUT" | sed 's/^/  /'
    exit 1
fi

# ── Test 2: commits counted as ships ─────────────────────────────────────────
echo "Test 2: commit events counted as ships (3, not 0 or 4)"
if echo "$OUT" | grep -qE "^Ships: 3"; then
    echo "  PASS (Ships: 3)"
else
    echo "  FAIL: expected 'Ships: 3'"
    echo "$OUT" | grep -i "ship" | sed 's/^/  /'
    exit 1
fi

# ── Test 3: alert(30m) counts only recent ALERT events ───────────────────────
echo "Test 3: Alerts(30m) shows only alerts in last 30 min (1)"
if echo "$OUT" | grep -qE "Alerts\(30m\): 1"; then
    echo "  PASS (Alerts(30m): 1)"
else
    echo "  FAIL: expected 'Alerts(30m): 1'"
    echo "$OUT" | grep -i alert | sed 's/^/  /'
    exit 1
fi

# ── Test 4: --json emits valid JSON with required fields ──────────────────────
echo "Test 4: --json flag emits valid JSON"
JSON_OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief --json 2>/dev/null)"
REQUIRED_FIELDS="ships_24h auto_fixed manual_rescues stalls_gt_4h fleet_wedges silent_agents pr_stuck alerts pillar_mix suggestions"
all_ok=1
for field in $REQUIRED_FIELDS; do
    if ! echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
        echo "  FAIL: missing field '$field' in JSON output"
        all_ok=0
    fi
done
if [[ "$all_ok" -eq 1 ]]; then
    SHIPS="$(echo "$JSON_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['ships_24h'])")"
    if [[ "$SHIPS" == "3" ]]; then
        echo "  PASS (valid JSON, ships_24h=3)"
    else
        echo "  FAIL: ships_24h=$SHIPS expected 3"
        exit 1
    fi
else
    exit 1
fi

# ── Test 5: exits 0 ───────────────────────────────────────────────────────────
echo "Test 5: exits 0 (no fall-through to rest of main)"
CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 0 ]]; then
    echo "  PASS (exit 0)"
else
    echo "  FAIL: exit code $RC (expected 0)"
    exit 1
fi

# ── Test 6: --window filters to shorter window ────────────────────────────────
echo "Test 6: --window 1800 (30 min) excludes 1h-old commits"
SHORT_OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief --window 1800 2>/dev/null)"
if echo "$SHORT_OUT" | grep -qE "^Ships: 0"; then
    echo "  PASS (Ships: 0 when window=30m)"
else
    echo "  FAIL: expected Ships: 0 with 30m window (all commits are 1h old)"
    echo "$SHORT_OUT" | grep -i "ship" | sed 's/^/  /'
    exit 1
fi

echo ""
echo "All fleet-brief tests passed (6/6)."
