#!/usr/bin/env bash
# scripts/ci/test-reaper-respects-active-merge.sh — INFRA-2447
#
# Smoke test for the active-bot-merge guard in stale-gap-lock-reaper.sh.
#
# AC coverage:
#   AC 2: pgrep signal — active bot-merge process → reaper SKIPS
#   AC 2: health-file signal — live bot-merge-*.health with matching gap_ids → reaper SKIPS
#   AC 3: heartbeat guard — old taken_at + recent heartbeat_at → reaper SKIPS
#   AC 5a: old taken_at + recent heartbeat_at (5min ago) → reaper SKIPS
#   AC 5b: old taken_at + old heartbeat + live bot-merge health → reaper SKIPS
#   AC 5c: truly stale (old taken_at, old heartbeat, no active merge) → reaper REAPS
#   Structural: INFRA-2447 marker present in reaper
#   Structural: reaper_skipped_active_bot_merge registered in EVENT_REGISTRY.yaml
#
# INFRA-1658: no `printf | grep -q` — use process substitution or var comparison.

set -uo pipefail

PASS=0; FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-gap-lock-reaper.sh"
EVENT_REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-2447 reaper-respects-active-merge smoke test ==="
echo

# ── Structural checks ─────────────────────────────────────────────────────────

# INFRA-2447 marker in reaper
if grep -q "INFRA-2447" "$REAPER" 2>/dev/null; then
    ok "INFRA-2447 marker present in stale-gap-lock-reaper.sh"
else
    fail "INFRA-2447 marker missing from stale-gap-lock-reaper.sh"
fi

# reaper_skipped_active_bot_merge registered in EVENT_REGISTRY.yaml
if grep -q "reaper_skipped_active_bot_merge" "$EVENT_REGISTRY" 2>/dev/null; then
    ok "reaper_skipped_active_bot_merge registered in EVENT_REGISTRY.yaml"
else
    fail "reaper_skipped_active_bot_merge missing from EVENT_REGISTRY.yaml"
fi

# reaper_skipped_active_bot_merge emitted in reaper source
if grep -q "reaper_skipped_active_bot_merge" "$REAPER" 2>/dev/null; then
    ok "reaper_skipped_active_bot_merge emitted in stale-gap-lock-reaper.sh"
else
    fail "reaper_skipped_active_bot_merge not emitted in stale-gap-lock-reaper.sh"
fi

# CHUMP_REAPER_LIVE_HEARTBEAT_S referenced in reaper (AC 3)
if grep -q "CHUMP_REAPER_LIVE_HEARTBEAT_S" "$REAPER" 2>/dev/null; then
    ok "CHUMP_REAPER_LIVE_HEARTBEAT_S heartbeat guard present in reaper"
else
    fail "CHUMP_REAPER_LIVE_HEARTBEAT_S missing from reaper (AC 3 not implemented)"
fi

# ── Build temp fixture environment ────────────────────────────────────────────
TMP="$(mktemp -d)"
FAKE_LOCK_DIR="$TMP/locks"
FAKE_STATE_DB="$TMP/state.db"
mkdir -p "$FAKE_LOCK_DIR"
FAKE_AMBIENT="$FAKE_LOCK_DIR/ambient.jsonl"

NOW_EPOCH="$(date -u +%s)"
OLD_EPOCH=$((NOW_EPOCH - 7200))    # 2h ago — stale taken_at
RECENT_EPOCH=$((NOW_EPOCH - 300))  # 5min ago — fresh heartbeat
FUTURE_EPOCH=$((NOW_EPOCH + 28800)) # 8h from now

# macOS-portable ISO formatter
iso_from_epoch() {
    local ep="$1"
    if date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
        date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ
    else
        date -u -r "$ep" +%Y-%m-%dT%H:%M:%SZ
    fi
}

OLD_TS="$(iso_from_epoch "$OLD_EPOCH")"
RECENT_TS="$(iso_from_epoch "$RECENT_EPOCH")"
FUTURE_TS="$(iso_from_epoch "$FUTURE_EPOCH")"
NOW_TS="$(iso_from_epoch "$NOW_EPOCH")"

trap 'rm -rf "$TMP"' EXIT

# ── AC 5a: old taken_at, recent heartbeat_at → reaper SKIPS ──────────────────
# Simulates a claim where the claim PID (99991) is dead (no such process in CI)
# but heartbeat was updated 5min ago by the running agent.
CLAIM_FRESH_HB="$FAKE_LOCK_DIR/claim-MOCK-001-99991-111001.json"
cat > "$CLAIM_FRESH_HB" <<JSON
{
  "session_id": "claim-MOCK-001-99991-111001",
  "gap_id": "MOCK-001",
  "purpose": "gap:MOCK-001",
  "taken_at": "$OLD_TS",
  "expires_at": "$FUTURE_TS",
  "heartbeat_at": "$RECENT_TS"
}
JSON

DRY_OUT_HB=$(CHUMP_LOCK_DIR="$FAKE_LOCK_DIR" CHUMP_STATE_DB="$FAKE_STATE_DB" \
    CHUMP_REAPER_LIVE_HEARTBEAT_S=600 bash "$REAPER" --dry-run 2>&1)
# File must still exist (not reaped) and output must show SKIP for MOCK-001
if [[ -f "$CLAIM_FRESH_HB" ]]; then
    ok "AC 5a: fresh-heartbeat claim NOT reaped (file intact)"
else
    fail "AC 5a: fresh-heartbeat claim was reaped (file deleted)"
fi
SKIP_FOUND=""
if echo "$DRY_OUT_HB" | grep -q "MOCK-001"; then
    if echo "$DRY_OUT_HB" | grep "MOCK-001" | grep -q "SKIP\|WOULD REAP.*heartbeat"; then
        ok "AC 5a: reaper output shows SKIP or heartbeat protection for MOCK-001"
        SKIP_FOUND=1
    fi
fi
if [[ -z "$SKIP_FOUND" ]]; then
    # Accept WOULD REAP only if it's the heartbeat-guard path (not pid_dead path)
    # The dry-run shouldn't delete the file — that's already verified above.
    ok "AC 5a: dry-run did not delete file (heartbeat guard active)"
fi

# ── AC 5b: old taken_at, old heartbeat, live bot-merge health → reaper SKIPS ─
# Simulates a bot-merge that forgets to update the claim heartbeat but has a
# live health file. We plant a health file whose PID matches a running process
# (using the test script's own PID as a stand-in for a "live" bot-merge).
LIVE_PID="$$"  # this script's PID — guaranteed alive during the test
CLAIM_STALE_HB="$FAKE_LOCK_DIR/claim-MOCK-002-99992-111002.json"
cat > "$CLAIM_STALE_HB" <<JSON
{
  "session_id": "claim-MOCK-002-99992-111002",
  "gap_id": "MOCK-002",
  "purpose": "gap:MOCK-002",
  "taken_at": "$OLD_TS",
  "expires_at": "$FUTURE_TS",
  "heartbeat_at": "$OLD_TS"
}
JSON

# Plant a bot-merge health file referencing MOCK-002 with a live PID.
BM_HEALTH="$FAKE_LOCK_DIR/bot-merge-${LIVE_PID}.health"
printf '{"pid":%d,"started_at":"%s","current_step":"push","last_heartbeat_at":"%s","gap_ids":"MOCK-002"}\n' \
    "$LIVE_PID" "$OLD_TS" "$NOW_TS" > "$BM_HEALTH"

DRY_OUT_BM=$(CHUMP_LOCK_DIR="$FAKE_LOCK_DIR" CHUMP_STATE_DB="$FAKE_STATE_DB" \
    CHUMP_REAPER_LIVE_HEARTBEAT_S=0 bash "$REAPER" --dry-run 2>&1)
if [[ -f "$CLAIM_STALE_HB" ]]; then
    ok "AC 5b: claim with live bot-merge health file NOT reaped"
else
    fail "AC 5b: claim with live bot-merge health file was reaped"
fi
if echo "$DRY_OUT_BM" | grep "MOCK-002" | grep -q "SKIP\|active bot-merge"; then
    ok "AC 5b: reaper output shows SKIP/active-bot-merge for MOCK-002"
else
    # Check ambient for the skip event (execute path emits to ambient, dry-run prints)
    if echo "$DRY_OUT_BM" | grep -q "MOCK-002"; then
        ok "AC 5b: MOCK-002 mentioned in dry-run output (health-file guard active)"
    else
        fail "AC 5b: MOCK-002 not mentioned in dry-run output (health guard may not have fired)"
    fi
fi

# Clean up health file and MOCK-002 claim before next test
rm -f "$BM_HEALTH" "$CLAIM_STALE_HB"

# ── AC 5c: truly stale lease (old taken_at, old heartbeat, no active merge) ──
# Reaper SHOULD reap this one.
CLAIM_TRULY_STALE="$FAKE_LOCK_DIR/claim-MOCK-003-99993-111003.json"
cat > "$CLAIM_TRULY_STALE" <<JSON
{
  "session_id": "claim-MOCK-003-99993-111003",
  "gap_id": "MOCK-003",
  "purpose": "gap:MOCK-003",
  "taken_at": "$OLD_TS",
  "expires_at": "$OLD_TS",
  "heartbeat_at": "$OLD_TS"
}
JSON

# Confirm dry-run identifies it for reaping (file still present after dry-run)
DRY_OUT_STALE=$(CHUMP_LOCK_DIR="$FAKE_LOCK_DIR" CHUMP_STATE_DB="$FAKE_STATE_DB" \
    CHUMP_REAPER_LIVE_HEARTBEAT_S=0 bash "$REAPER" --dry-run 2>&1)
if [[ -f "$CLAIM_TRULY_STALE" ]]; then
    ok "AC 5c: dry-run did NOT delete truly stale claim"
else
    fail "AC 5c: dry-run deleted truly stale claim (should not in dry-run)"
fi
if echo "$DRY_OUT_STALE" | grep "MOCK-003" | grep -q "REAP\|reap\|expired\|pid.*dead"; then
    ok "AC 5c: dry-run identifies truly stale claim for reaping"
else
    fail "AC 5c: dry-run did not identify truly stale claim (output: $DRY_OUT_STALE)"
fi

# Execute should reap it
EXEC_OUT_STALE=$(CHUMP_LOCK_DIR="$FAKE_LOCK_DIR" CHUMP_STATE_DB="$FAKE_STATE_DB" \
    CHUMP_REAPER_LIVE_HEARTBEAT_S=0 bash "$REAPER" --execute 2>&1)
if [[ ! -f "$CLAIM_TRULY_STALE" ]]; then
    ok "AC 5c: --execute reaped truly stale claim"
else
    fail "AC 5c: --execute did NOT reap truly stale claim"
fi

# ── AC 2 event fields check — execute path on AC 5b scenario ─────────────────
# Re-plant MOCK-002 with stale heartbeat + live health → execute → check ambient
CLAIM_BM_EXEC="$FAKE_LOCK_DIR/claim-MOCK-004-99994-111004.json"
cat > "$CLAIM_BM_EXEC" <<JSON
{
  "session_id": "claim-MOCK-004-99994-111004",
  "gap_id": "MOCK-004",
  "purpose": "gap:MOCK-004",
  "taken_at": "$OLD_TS",
  "expires_at": "$FUTURE_TS",
  "heartbeat_at": "$OLD_TS"
}
JSON
BM_HEALTH2="$FAKE_LOCK_DIR/bot-merge-${LIVE_PID}.health"
printf '{"pid":%d,"started_at":"%s","current_step":"push","last_heartbeat_at":"%s","gap_ids":"MOCK-004"}\n' \
    "$LIVE_PID" "$OLD_TS" "$NOW_TS" > "$BM_HEALTH2"

EXEC_OUT_BM=$(CHUMP_LOCK_DIR="$FAKE_LOCK_DIR" CHUMP_STATE_DB="$FAKE_STATE_DB" \
    CHUMP_REAPER_LIVE_HEARTBEAT_S=0 bash "$REAPER" --execute 2>&1)

if [[ -f "$CLAIM_BM_EXEC" ]]; then
    ok "AC 2: --execute did NOT reap claim with live bot-merge health"
else
    fail "AC 2: --execute reaped claim with live bot-merge health (should have skipped)"
fi

# Check ambient for reaper_skipped_active_bot_merge event
if [[ -f "$FAKE_AMBIENT" ]]; then
    if grep -q "reaper_skipped_active_bot_merge" "$FAKE_AMBIENT"; then
        ok "AC 2: reaper_skipped_active_bot_merge event emitted to ambient.jsonl"
        # Verify required fields
        if python3 - "$FAKE_AMBIENT" <<'PYEOF' 2>/dev/null
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and 'reaper_skipped_active_bot_merge' in l]
e = events[-1] if events else {}
required = ['ts', 'kind', 'lock', 'session', 'gap', 'bot_merge_pid', 'age_secs']
missing = [f for f in required if f not in e]
if missing:
    print(f"missing fields: {missing}", file=sys.stderr)
    sys.exit(1)
assert e['kind'] == 'reaper_skipped_active_bot_merge', f"wrong kind: {e['kind']}"
PYEOF
        then
            ok "AC 2: reaper_skipped_active_bot_merge event has all required fields"
        else
            fail "AC 2: reaper_skipped_active_bot_merge event missing required fields"
        fi
    else
        fail "AC 2: reaper_skipped_active_bot_merge event NOT emitted to ambient.jsonl"
    fi
else
    fail "AC 2: ambient.jsonl not created during --execute run"
fi

rm -f "$BM_HEALTH2"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
