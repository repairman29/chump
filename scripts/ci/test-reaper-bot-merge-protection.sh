#!/usr/bin/env bash
# scripts/ci/test-reaper-bot-merge-protection.sh — INFRA-2447
#
# Verifies the stale-gap-lock-reaper does NOT reap a claim lease while a
# bot-merge.sh process is actively working the same gap, even when the
# claim's own heartbeat_at is stale/missing and its embedded PID is dead.
#
# Trigger: INFRA-2438 (2026-06-02) — reaper deleted a live lease mid
# bot-merge run because bot-merge never refreshes the claim's heartbeat_at;
# it only maintains its own .chump-locks/bot-merge-<pid>.health file.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-gap-lock-reaper.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$REAPER" ]] || fail "reaper missing or not executable: $REAPER"

TMP="$(mktemp -d -t reaper-bm-test-XXXX)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
touch "$LOCK_DIR/ambient.jsonl"

# Use a clearly-dead PID for the claim itself (99999+ until unused).
DEAD_PID=99999
while ps -p "$DEAD_PID" >/dev/null 2>&1; do DEAD_PID=$((DEAD_PID+1)); done

iso_offset() {
    local secs=$1
    python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=$secs)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

GAP="INFRA-2438"
GAP_LC="$(printf '%s' "$GAP" | tr '[:upper:]' '[:lower:]')"
SID="claim-${GAP_LC}-${DEAD_PID}-1700000000"
CLAIM_FILE="$LOCK_DIR/${SID}.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRES="$(date -u -v+8H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+8 hours' +%Y-%m-%dT%H:%M:%SZ)"
HB_STALE="$(iso_offset 700)"

# Claim: dead PID, stale heartbeat_at — would be reaped under INFRA-1236/1208
# alone. No open PR, no branch ahead — isolate to the bot-merge signal.
printf '{"session_id":"%s","gap_id":"%s","paths":[],"taken_at":"%s","expires_at":"%s","heartbeat_at":"%s","purpose":"gap:%s"}\n' \
    "$SID" "$GAP" "$NOW" "$EXPIRES" "$HB_STALE" "$GAP" >"$CLAIM_FILE"

# Simulate an actively-running bot-merge on this gap: real live PID ($$, this
# test script's own shell), fresh last_heartbeat_at, matching gap_ids.
BM_HEALTH="$LOCK_DIR/bot-merge-$$.health"
printf '{"pid":%d,"started_at":"%s","current_step":"push","last_heartbeat_at":"%s","gap_ids":"%s"}\n' \
    "$$" "$NOW" "$NOW" "$GAP" >"$BM_HEALTH"

CHUMP_LOCK_DIR="$LOCK_DIR" "$REAPER" --execute >"$TMP/r.out" 2>&1 || true

[[ -f "$CLAIM_FILE" ]] \
    || fail "claim was reaped while bot-merge was active — reaper output: $(cat "$TMP/r.out")"
grep -q '"reason":"active_bot_merge"' "$LOCK_DIR/ambient.jsonl" \
    || fail "expected stale_gap_lock_protected reason=active_bot_merge event"
ok "stale heartbeat + dead claim PID, but live bot-merge health file → lease preserved"

# ── Control: same setup, but bot-merge health is stale too → REAP ──────────
GAP2="INFRA-9999"
GAP2_LC="$(printf '%s' "$GAP2" | tr '[:upper:]' '[:lower:]')"
SID2="claim-${GAP2_LC}-${DEAD_PID}-1700000001"
CLAIM_FILE2="$LOCK_DIR/${SID2}.json"
printf '{"session_id":"%s","gap_id":"%s","paths":[],"taken_at":"%s","expires_at":"%s","heartbeat_at":"%s","purpose":"gap:%s"}\n' \
    "$SID2" "$GAP2" "$NOW" "$EXPIRES" "$HB_STALE" "$GAP2" >"$CLAIM_FILE2"

BM_HEALTH2="$LOCK_DIR/bot-merge-$$-stale.health"
HB_BM_STALE="$(iso_offset 300)"
printf '{"pid":%d,"started_at":"%s","current_step":"push","last_heartbeat_at":"%s","gap_ids":"%s"}\n' \
    "$$" "$NOW" "$HB_BM_STALE" "$GAP2" >"$BM_HEALTH2"

CHUMP_LOCK_DIR="$LOCK_DIR" "$REAPER" --execute >"$TMP/r2.out" 2>&1 || true
[[ ! -f "$CLAIM_FILE2" ]] \
    || fail "claim with stale bot-merge health was NOT reaped (control failed)"
ok "stale heartbeat + dead claim PID + stale bot-merge health → lease reaped (control)"

ok "ALL INFRA-2447 reaper bot-merge-protection checks passed"
