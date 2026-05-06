#!/usr/bin/env bash
# Regression for INFRA-524: picker self-blocks when .gap-<ID>.lock belongs to
# the calling session. gap-preflight.sh should bypass lease check in that case.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"

GAP_ID="INFRA-524-SELFLOCK-TEST"
SESSION="fleet-test-agent1-99999-1234567890"
OTHER_SESSION="fleet-test-agent2-88888-9999999999"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
future="$(python3 -c 'import datetime; print((datetime.datetime.utcnow()+datetime.timedelta(hours=4)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

# Write a JSON lease from the OTHER session claiming the same gap — this would
# normally cause check_lease_claim to block. The .gap-<ID>.lock written by OUR
# session should short-circuit before the JSON lease is read.
cat > "$LOCK_DIR/${OTHER_SESSION}.json" <<JSON
{
  "session_id": "$OTHER_SESSION",
  "gap_id": "$GAP_ID",
  "taken_at": "$now",
  "expires_at": "$future",
  "heartbeat_at": "$now",
  "purpose": "fleet:pick_and_claim",
  "speculative": false
}
JSON

# ── Test 1: no lock file → blocked by the other session's lease ───────────────
echo "Test 1: without .gap-lock, other session's lease blocks"
set +e
out="$(CHUMP_LOCK_DIR="$LOCK_DIR" CHUMP_SESSION_ID="$SESSION" \
       CHUMP_PREFLIGHT_NATS_CHECK=0 CHUMP_PREFLIGHT_PR_CHECK=0 \
       CHUMP_ALLOW_UNREGISTERED_GAP=1 \
       bash "$ROOT/scripts/coord/gap-preflight.sh" "$GAP_ID" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    echo "  FAIL: expected gap-preflight to block (no lock file), but it passed"
    echo "$out"
    exit 1
fi
echo "  PASS: correctly blocked by other session's lease (exit $rc)"

# ── Test 2: lock file from OUR session → should bypass and pass ───────────────
echo "Test 2: with .gap-lock owned by our session, preflight should pass"
printf '%s %s\n' "$SESSION" "$(date +%s)" > "$LOCK_DIR/.gap-${GAP_ID}.lock"

set +e
out="$(CHUMP_LOCK_DIR="$LOCK_DIR" CHUMP_SESSION_ID="$SESSION" \
       CHUMP_PREFLIGHT_NATS_CHECK=0 CHUMP_PREFLIGHT_PR_CHECK=0 \
       CHUMP_ALLOW_UNREGISTERED_GAP=1 \
       bash "$ROOT/scripts/coord/gap-preflight.sh" "$GAP_ID" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    echo "  FAIL: expected gap-preflight to pass with our .gap-lock, got exit $rc"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "INFRA-524"; then
    echo "  FAIL: expected INFRA-524 bypass note in output"
    echo "$out"
    exit 1
fi
echo "  PASS: self-lock bypass worked (exit $rc)"

# ── Test 3: lock file from a DIFFERENT session → still blocked ────────────────
echo "Test 3: .gap-lock from different session — still blocked by lease check"
printf '%s %s\n' "$OTHER_SESSION" "$(date +%s)" > "$LOCK_DIR/.gap-${GAP_ID}.lock"

set +e
out="$(CHUMP_LOCK_DIR="$LOCK_DIR" CHUMP_SESSION_ID="$SESSION" \
       CHUMP_PREFLIGHT_NATS_CHECK=0 CHUMP_PREFLIGHT_PR_CHECK=0 \
       CHUMP_ALLOW_UNREGISTERED_GAP=1 \
       bash "$ROOT/scripts/coord/gap-preflight.sh" "$GAP_ID" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    echo "  FAIL: expected block when lock belongs to other session"
    echo "$out"
    exit 1
fi
echo "  PASS: lock from different session does not bypass lease check (exit $rc)"

echo ""
echo "All INFRA-524 self-lock bypass tests passed."
