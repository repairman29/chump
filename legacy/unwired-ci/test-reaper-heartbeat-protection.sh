#!/usr/bin/env bash
# scripts/ci/test-reaper-heartbeat-protection.sh — INFRA-1236
#
# Verifies the stale-gap-lock-reaper respects heartbeat freshness:
#   1. Claim with dead PID + heartbeat_at = now-30s   → reaper SKIPS
#   2. Claim with dead PID + heartbeat_at = now-700s  → reaper REAPS
#   3. Claim with dead PID + no heartbeat_at          → reaper REAPS (back-compat)
#   4. Skipped lease emits kind=stale_gap_lock_protected
#   5. refresh-claim-heartbeat.sh bumps heartbeat_at to "now"

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-gap-lock-reaper.sh"
REFRESH="$REPO_ROOT/scripts/coord/refresh-claim-heartbeat.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$REAPER" ]]  || fail "reaper missing or not executable: $REAPER"
[[ -x "$REFRESH" ]] || fail "refresh helper missing or not executable: $REFRESH"

TMP="$(mktemp -d -t reaper-hb-test-XXXX)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
touch "$LOCK_DIR/ambient.jsonl"

# Use a clearly-dead PID (99999 is unlikely to exist; ps confirms).
DEAD_PID=99999
while ps -p "$DEAD_PID" >/dev/null 2>&1; do DEAD_PID=$((DEAD_PID+1)); done

make_claim() {
    # make_claim <name> <gap_id> <heartbeat_at>
    local name="$1" gap="$2" hb="$3"
    local gap_lc; gap_lc="$(printf '%s' "$gap" | tr '[:upper:]' '[:lower:]')"
    local sid="claim-${gap_lc}-${DEAD_PID}-1700000000"
    local file="$LOCK_DIR/${sid}.json"
    local now expires
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    expires="$(date -u -v+8H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+8 hours' +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$hb" == "NONE" ]]; then
        printf '{"session_id":"%s","gap_id":"%s","paths":[],"taken_at":"%s","expires_at":"%s","purpose":"gap:%s"}\n' \
            "$sid" "$gap" "$now" "$expires" "$gap" >"$file"
    else
        printf '{"session_id":"%s","gap_id":"%s","paths":[],"taken_at":"%s","expires_at":"%s","heartbeat_at":"%s","purpose":"gap:%s"}\n' \
            "$sid" "$gap" "$now" "$expires" "$hb" "$gap" >"$file"
    fi
    printf '%s\n' "$file"
}

iso_offset() {
    # iso_offset <seconds_ago> → ISO-8601 UTC
    local secs=$1
    python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=$secs)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

# ── Test 1: dead PID + fresh heartbeat → SKIP ───────────────────────────────
HB_FRESH="$(iso_offset 30)"
F1="$(make_claim alpha INFRA-AAA "$HB_FRESH")"
CHUMP_LOCK_DIR="$LOCK_DIR" "$REAPER" --execute >"$TMP/r1.out" 2>&1 || true
[[ -f "$F1" ]] || fail "fresh-heartbeat lease was reaped! reaper output: $(cat "$TMP/r1.out")"
grep -q "stale_gap_lock_protected" "$LOCK_DIR/ambient.jsonl" \
    || fail "expected stale_gap_lock_protected event in ambient.jsonl"
ok "dead PID + fresh heartbeat (30s) → lease preserved + protected event emitted"

# ── Test 2: dead PID + stale heartbeat → REAP ───────────────────────────────
HB_STALE="$(iso_offset 700)"
F2="$(make_claim beta INFRA-BBB "$HB_STALE")"
CHUMP_LOCK_DIR="$LOCK_DIR" "$REAPER" --execute >"$TMP/r2.out" 2>&1 || true
[[ ! -f "$F2" ]] || fail "stale-heartbeat lease was NOT reaped"
ok "dead PID + stale heartbeat (700s) → lease reaped"

# ── Test 3: dead PID + no heartbeat → REAP (back-compat) ────────────────────
F3="$(make_claim gamma INFRA-CCC NONE)"
CHUMP_LOCK_DIR="$LOCK_DIR" "$REAPER" --execute >"$TMP/r3.out" 2>&1 || true
[[ ! -f "$F3" ]] || fail "no-heartbeat lease was NOT reaped (back-compat broke)"
ok "dead PID + no heartbeat → lease reaped (back-compat preserved)"

# ── Test 4: refresh-claim-heartbeat.sh bumps the field ─────────────────────
HB_OLD="$(iso_offset 500)"
F4="$(make_claim delta INFRA-DDD "$HB_OLD")"
SID_DELTA="$(python3 -c "import json; print(json.load(open('$F4'))['session_id'])")"
CHUMP_LOCK_DIR="$LOCK_DIR" "$REFRESH" "$SID_DELTA" >/dev/null 2>&1 \
    || fail "refresh-claim-heartbeat.sh exited non-zero"
NEW_HB="$(python3 -c "import json; print(json.load(open('$F4'))['heartbeat_at'])")"
[[ "$NEW_HB" != "$HB_OLD" ]] || fail "heartbeat_at not bumped"
# Sanity: new heartbeat parses as ISO and is within last 10s.
AGE="$(python3 -c "
import datetime
t = datetime.datetime.fromisoformat('$NEW_HB'.replace('Z', '+00:00'))
print(int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()))
")"
(( AGE >= 0 && AGE < 10 )) || fail "refreshed heartbeat age $AGE s outside [0,10)"
ok "refresh-claim-heartbeat.sh: bumps heartbeat_at to now"

# ── Test 5: now reaper preserves the freshly-refreshed lease ───────────────
CHUMP_LOCK_DIR="$LOCK_DIR" "$REAPER" --execute >"$TMP/r5.out" 2>&1 || true
[[ -f "$F4" ]] || fail "freshly-refreshed lease was reaped"
ok "refreshed lease survives next reaper pass"

# ── Test 6: --by-gap finds the right lease ─────────────────────────────────
F6="$(make_claim eps INFRA-EEE "$(iso_offset 100)")"
CHUMP_LOCK_DIR="$LOCK_DIR" "$REFRESH" INFRA-EEE --by-gap >/dev/null 2>&1 \
    || fail "--by-gap failed to find lease"
ok "refresh-claim-heartbeat.sh --by-gap: resolves by gap_id"

ok "ALL INFRA-1236 reaper heartbeat-protection checks passed"
