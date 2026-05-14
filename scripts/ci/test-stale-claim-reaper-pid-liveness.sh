#!/usr/bin/env bash
# scripts/ci/test-stale-claim-reaper-pid-liveness.sh — INFRA-1208
#
# INFRA-1164 added expires_at-based reaping for claim-*.json files. But the
# default lease TTL is 8h, so a session that crashes 30 min in leaves a
# dead lease sitting for 7.5h until TTL expires. INFRA-1208 extends the
# reaper to ALSO sweep based on PID liveness (session_id encodes the PID).
#
# Tests:
#   1. Reaper dry-run identifies a claim file whose PID is dead but
#      expires_at is far in the future.
#   2. Reaper --execute deletes only the dead-PID claim, leaves the
#      live-PID claim intact.
#   3. Reaper emits kind=stale_gap_lock_reaped with reason=pid_dead.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-gap-lock-reaper.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$REAPER" ]] || fail "reaper script missing or not executable"

# Isolated test dir
TMP=$(mktemp -d -t reaper-pid-test-XXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

# Future expires_at (now + 8h)
FUTURE_ISO=$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=8)).isoformat().replace('+00:00','Z'))")

# Pick a definitely-dead PID. Use a very high number that can't possibly be running.
DEAD_PID=99999
# Sanity: confirm DEAD_PID is not running
if ps -p "$DEAD_PID" >/dev/null 2>&1; then
    DEAD_PID=98765
fi
if ps -p "$DEAD_PID" >/dev/null 2>&1; then
    fail "could not find a dead PID for the test (both 99999 and 98765 are alive!)"
fi

# Pick a live PID — our own.
LIVE_PID=$$

# Create dead-PID claim with future expires_at
cat > "$TMP/.chump-locks/claim-test-dead-${DEAD_PID}-1.json" <<EOF
{
  "session_id": "claim-test-dead-${DEAD_PID}-1",
  "paths": [],
  "taken_at": "2026-05-14T10:00:00Z",
  "expires_at": "$FUTURE_ISO",
  "heartbeat_at": "2026-05-14T10:00:00Z",
  "purpose": "gap:TEST-DEAD",
  "gap_id": "TEST-DEAD"
}
EOF

# Create live-PID claim with future expires_at — should NOT be reaped
cat > "$TMP/.chump-locks/claim-test-live-${LIVE_PID}-1.json" <<EOF
{
  "session_id": "claim-test-live-${LIVE_PID}-1",
  "paths": [],
  "taken_at": "2026-05-14T10:00:00Z",
  "expires_at": "$FUTURE_ISO",
  "heartbeat_at": "2026-05-14T10:00:00Z",
  "purpose": "gap:TEST-LIVE",
  "gap_id": "TEST-LIVE"
}
EOF

# Initial state: both files present
[[ -f "$TMP/.chump-locks/claim-test-dead-${DEAD_PID}-1.json" ]] || fail "dead claim file not created"
[[ -f "$TMP/.chump-locks/claim-test-live-${LIVE_PID}-1.json" ]] || fail "live claim file not created"

# 1. Dry-run identifies the dead-pid claim
out=$(CHUMP_LOCK_DIR="$TMP/.chump-locks" "$REAPER" 2>&1)
echo "$out" | grep -q "WOULD REAP claim (pid=${DEAD_PID} dead)" \
    || fail "dry-run did not flag dead-PID claim. output: $out"
echo "$out" | grep -q "test-live-${LIVE_PID}" \
    && fail "dry-run incorrectly flagged live-PID claim"
ok "dry-run: identifies dead-PID claim, leaves live-PID claim alone"

# 2. --execute: dead deleted, live retained
CHUMP_LOCK_DIR="$TMP/.chump-locks" "$REAPER" --execute > "$TMP/run.log" 2>&1
[[ ! -f "$TMP/.chump-locks/claim-test-dead-${DEAD_PID}-1.json" ]] \
    || fail "--execute did NOT delete dead-PID claim"
[[ -f "$TMP/.chump-locks/claim-test-live-${LIVE_PID}-1.json" ]] \
    || fail "--execute incorrectly deleted live-PID claim"
ok "--execute: deletes dead-PID claim, retains live-PID claim"

# 3. Ambient event has kind=stale_gap_lock_reaped, reason=pid_dead, pid=<int>
grep -q '"kind":"stale_gap_lock_reaped"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "ambient event missing kind=stale_gap_lock_reaped"
grep -q '"reason":"pid_dead"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "ambient event missing reason=pid_dead"
grep -qE "\"pid\":${DEAD_PID}" "$TMP/.chump-locks/ambient.jsonl" \
    || fail "ambient event missing pid=${DEAD_PID}"
grep -q '"source":"claim_file"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "ambient event missing source=claim_file"
ok "ambient event: kind + reason + pid + source all correct"

echo
echo "All INFRA-1208 stale-claim-reaper-pid-liveness tests passed."
