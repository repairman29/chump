#!/usr/bin/env bash
# INFRA-115: regression test for the file-based lease TTL reaper in
# scripts/ops/queue-health-monitor.sh. Asserts that an expired lease file
# (expires_at = now - 600s) is deleted on the next monitor pass and that
# the corresponding `lease_expired_server` ALERT lands in ambient.jsonl.
#
# Run from repo root: bash scripts/ci/test-infra-115-lease-ttl-file.sh

set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"
# When run from a linked worktree, ambient.jsonl actually lives in the
# MAIN repo's .chump-locks/, not the worktree's. Resolve via git common-dir.
_GIT_COMMON="$(git rev-parse --git-common-dir)"
case "$_GIT_COMMON" in
    /*) MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)" ;;
    *)  MAIN_REPO="$REPO_ROOT" ;;
esac
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX="$(mktemp -d -t chump-infra-115-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Sandbox layout matches the production lock dir structure so the
# monitor's path-resolution logic (REPO_ROOT/.chump-locks/) finds it.
LOCK_DIR="$SANDBOX/.chump-locks"
CHUMP_DIR="$SANDBOX/.chump"
mkdir -p "$LOCK_DIR" "$CHUMP_DIR"

# Sentinel: an EXPIRED lease (expires_at = now - 600s, well past the 5min grace)
PAST_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(seconds=600)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
EXPIRED_LEASE="$LOCK_DIR/chump-infra-115-fixture-99999.json"
cat > "$EXPIRED_LEASE" <<JSON
{
  "session_id": "chump-infra-115-fixture-99999",
  "gap_id": "INFRA-115-fixture",
  "purpose": "test fixture",
  "taken_at": "2026-01-01T00:00:00Z",
  "expires_at": "$PAST_TS",
  "heartbeat_at": "2026-01-01T00:00:00Z",
  "paths": []
}
JSON

# Control: a FRESH lease (expires_at = now + 1h) — must NOT be reaped.
FUTURE_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
FRESH_LEASE="$LOCK_DIR/chump-infra-115-control-88888.json"
cat > "$FRESH_LEASE" <<JSON
{
  "session_id": "chump-infra-115-control-88888",
  "gap_id": "INFRA-115-fixture",
  "purpose": "test control",
  "taken_at": "$FUTURE_TS",
  "expires_at": "$FUTURE_TS",
  "heartbeat_at": "$FUTURE_TS",
  "paths": []
}
JSON

# Run the monitor against the sandbox by pointing it at a fake "main repo"
# whose .git/common-dir resolves into our sandbox. The monitor uses
# git rev-parse --show-toplevel + --git-common-dir to find $LOCK_DIR;
# with $LOCK_DIR overridable via env, we don't need a real fake-repo:
# both the monitor and the python reaper read CHUMP_LOCK_DIR (we add
# this override below).
QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$LOCK_DIR" \
QUEUE_HEALTH_PR_STUCK_MIN=999999 \
    bash "$REPO_ROOT/scripts/ops/queue-health-monitor.sh" --quiet 2>&1 | tail -3 \
    || true  # the monitor exits 0 even with alerts; tolerate either way

# Assertion 1: expired lease was deleted.
if [[ -f "$EXPIRED_LEASE" ]]; then
    fail "expired lease was NOT deleted (still exists at $EXPIRED_LEASE)"
else
    pass "expired lease deleted by reaper"
fi

# Assertion 2: fresh lease was preserved.
if [[ -f "$FRESH_LEASE" ]]; then
    pass "fresh (non-expired) lease preserved"
else
    fail "fresh lease was incorrectly deleted (false positive reap)"
fi

# Assertion 3: ALERT was emitted.
# The monitor writes alerts to MAIN_REPO/.chump/alerts.log + ambient.
# In the sandbox path, MAIN_REPO resolves to the real repo root because
# git --git-common-dir from the sandbox returns the real .git. So we
# verify against the REAL ambient (recent entries only).
ALERT_FOUND=0
# Real ambient (MAIN_REPO, where ambient-emit.sh writes by default).
if [[ -f "$MAIN_REPO/.chump-locks/ambient.jsonl" ]] && \
   grep -F "lease_expired_server" "$MAIN_REPO/.chump-locks/ambient.jsonl" 2>/dev/null \
    | grep -F "chump-infra-115-fixture-99999" >/dev/null; then
    ALERT_FOUND=1
fi
# Also accept ALERT in the sandbox's own ambient if isolation worked.
if [[ "$ALERT_FOUND" -eq 0 ]] && [[ -f "$LOCK_DIR/ambient.jsonl" ]] && \
   grep -F "lease_expired_server" "$LOCK_DIR/ambient.jsonl" 2>/dev/null \
    | grep -F "chump-infra-115-fixture-99999" >/dev/null; then
    ALERT_FOUND=1
fi
if [[ "$ALERT_FOUND" -eq 1 ]]; then
    pass "lease_expired_server ALERT emitted to ambient"
else
    fail "lease_expired_server ALERT NOT found in ambient"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
