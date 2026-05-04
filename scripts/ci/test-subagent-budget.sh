#!/usr/bin/env bash
# INFRA-419 — verify subagent-budget-reaper marks + alerts on stale leases.
#
# Strategy: fixture .chump-locks/ with two lease files — one fresh, one
# beyond budget — run the reaper with a low budget, assert (a) the fresh
# lease is untouched, (b) the stale lease gets budget_exceeded:true, and
# (c) an ambient ALERT kind=subagent_budget_exceeded is appended.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/subagent-budget-reaper.sh"

[[ -x "$REAPER" ]] || { fail "reaper script missing or not executable"; exit 1; }
pass "subagent-budget-reaper.sh exists + executable"

# Build a fixture sandbox so the reaper doesn't touch the real .chump-locks.
fixture=$(mktemp -d)
trap "rm -rf $fixture" EXIT
mkdir -p "$fixture/.chump-locks"

# Fresh lease (1 minute old) — must NOT be reaped.
fresh_taken=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(minutes=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
cat > "$fixture/.chump-locks/sess-fresh.json" <<EOF
{
  "session_id": "test-fresh",
  "gap_id": "INFRA-FRESH",
  "taken_at": "$fresh_taken",
  "expires_at": "2099-01-01T00:00:00Z"
}
EOF

# Stale lease (60 minutes old) — exceeds 5-min budget, no progress signal.
stale_taken=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(minutes=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
cat > "$fixture/.chump-locks/sess-stale.json" <<EOF
{
  "session_id": "test-stale",
  "gap_id": "INFRA-STALE",
  "taken_at": "$stale_taken",
  "expires_at": "2099-01-01T00:00:00Z"
}
EOF

touch "$fixture/.chump-locks/ambient.jsonl"

# Run the reaper against the fixture. The reaper resolves LOCK_DIR via
# REAPER_LOCK_DIR (sourced from reaper-instrumentation.sh), and the ambient
# path via CHUMP_AMBIENT_LOG.
out=$(CHUMP_SUBAGENT_LOCK_DIR="$fixture/.chump-locks" \
      CHUMP_AMBIENT_LOG="$fixture/.chump-locks/ambient.jsonl" \
      CHUMP_SUBAGENT_BUDGET_MIN=5 \
      bash "$REAPER" 2>&1 || true)

# Assertions.
if grep -q '"budget_exceeded"' "$fixture/.chump-locks/sess-stale.json"; then
    pass "stale lease marked budget_exceeded"
else
    fail "stale lease should have been marked budget_exceeded (lease: $(cat "$fixture/.chump-locks/sess-stale.json"))"
fi

if ! grep -q '"budget_exceeded"' "$fixture/.chump-locks/sess-fresh.json"; then
    pass "fresh lease NOT marked (still within budget)"
else
    fail "fresh lease should not have been marked"
fi

if grep -q '"kind":"subagent_budget_exceeded"' "$fixture/.chump-locks/ambient.jsonl"; then
    pass "ambient ALERT kind=subagent_budget_exceeded emitted"
else
    fail "missing ambient ALERT (ambient: $(cat "$fixture/.chump-locks/ambient.jsonl"))"
fi

# Idempotency — re-run should NOT double-alert (already marked).
prior_alerts=$(grep -c '"kind":"subagent_budget_exceeded"' "$fixture/.chump-locks/ambient.jsonl" || echo 0)
CHUMP_SUBAGENT_LOCK_DIR="$fixture/.chump-locks" \
      CHUMP_AMBIENT_LOG="$fixture/.chump-locks/ambient.jsonl" \
      CHUMP_SUBAGENT_BUDGET_MIN=5 \
      bash "$REAPER" 2>&1 >/dev/null || true
new_alerts=$(grep -c '"kind":"subagent_budget_exceeded"' "$fixture/.chump-locks/ambient.jsonl" || echo 0)
if [[ "$new_alerts" -eq "$prior_alerts" ]]; then
    pass "idempotent: re-run does not double-alert (still $prior_alerts)"
else
    fail "re-run created duplicate alerts ($prior_alerts → $new_alerts)"
fi

# Bypass env honored.
if CHUMP_SUBAGENT_REAPER=0 bash "$REAPER" 2>&1 | grep -q "bypass"; then
    pass "CHUMP_SUBAGENT_REAPER=0 bypass honored"
else
    fail "CHUMP_SUBAGENT_REAPER=0 should bypass with message"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
