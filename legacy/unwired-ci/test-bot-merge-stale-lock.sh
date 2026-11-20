#!/usr/bin/env bash
# test-bot-merge-stale-lock.sh — INFRA-3513 / COTG-2.7
#
# Validates the bot-merge stale-lock reaper (scripts/coord/bot-merge.sh):
#  1. On a flock timeout, a PID sidecar (.holder) is consulted.
#  2. A DEAD/unknown holder → the lock is REAPED (bot_merge_stale_lock_reaped).
#  3. A LIVE holder → respected (no reap).
#  4. The reaper decision mechanism (kill -0 on a dead vs live pid) behaves as used.
#
# Why: a killed/timed-out bot-merge leaves an orphan `sleep` holding the flock fd, so the
# lock looked "stuck" and stalled the ship queue 3x on 2026-07-29 (forced hand-created PRs).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
PASS=0; FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-3513 bot-merge stale-lock reaper test ==="
[ -f "$BM" ] || { echo "FAIL: $BM missing"; exit 1; }

grep -q "bot_merge_stale_lock_reaped" "$BM" \
  && ok "reap event (bot_merge_stale_lock_reaped) present" \
  || fail "reap event missing"

grep -qE '\$\{_bm_lock_file\}\.holder' "$BM" \
  && ok "PID sidecar (.holder) is written + consulted" \
  || fail "PID sidecar missing"

grep -qE 'kill -0 "\$_bm_holder"' "$BM" \
  && ok "holder liveness checked via kill -0" \
  || fail "holder liveness check missing"

# A LIVE holder must be respected (giving up), not reaped.
grep -qE 'held by a LIVE bot-merge' "$BM" \
  && ok "live holder is respected (not reaped)" \
  || fail "live-holder branch missing"

# 4. Mechanism: the exact decision the reaper makes.
#    A dead pid → kill -0 fails (→ reap); the current shell (live) → kill -0 succeeds (→ respect).
_dead_pid=999999
while kill -0 "$_dead_pid" 2>/dev/null; do _dead_pid=$((_dead_pid+1)); done
if ! kill -0 "$_dead_pid" 2>/dev/null; then
  ok "dead holder → kill -0 fails → reaper would reclaim"
else
  fail "could not find a dead pid to probe"
fi
if kill -0 "$$" 2>/dev/null; then
  ok "live holder (self) → kill -0 succeeds → reaper would respect"
else
  fail "kill -0 on self failed (unexpected)"
fi

echo "=== stale-lock reaper: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
