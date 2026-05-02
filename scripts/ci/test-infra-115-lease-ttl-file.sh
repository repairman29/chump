#!/usr/bin/env bash
# INFRA-115 — verify queue-health-monitor.sh reaps expired lease files.
#
# Simulates stale lease files with various expiry states and asserts that
# the monitor deletes files expired > 5 min ago (grace period) and emits
# a lease_expired_server ALERT to ambient.jsonl.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PASS=0
FAIL=0

check() {
    local desc="$1" result="$2"
    if [[ "$result" == "ok" ]]; then
        echo "[test-infra-115] PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "[test-infra-115] FAIL: $desc — $result" >&2
        FAIL=$((FAIL + 1))
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Case 1: lease expired 10 min ago → must be deleted + ALERT emitted ───────
LOCKS_EXPIRED="$TMPDIR_BASE/locks-expired"
AMBIENT_EXPIRED="$TMPDIR_BASE/ambient-expired.jsonl"
mkdir -p "$LOCKS_EXPIRED"

EXPIRED_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(seconds=600)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

cat > "$LOCKS_EXPIRED/test-session-expired.json" <<EOF
{"session_id":"test-session-expired","gap_id":"TEST-115","expires_at":"$EXPIRED_TS","taken_at":"$EXPIRED_TS"}
EOF

QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$LOCKS_EXPIRED" \
CHUMP_AMBIENT_LOG="$AMBIENT_EXPIRED" \
    bash scripts/ops/queue-health-monitor.sh 2>&1 || true

if [[ ! -f "$LOCKS_EXPIRED/test-session-expired.json" ]]; then
    check "expired lease (10 min past expiry) was deleted" "ok"
else
    check "expired lease (10 min past expiry) was deleted" "file still exists after monitor run"
fi

if grep -q "lease_expired_server" "$AMBIENT_EXPIRED" 2>/dev/null; then
    check "lease_expired_server ALERT written to ambient.jsonl" "ok"
else
    check "lease_expired_server ALERT written to ambient.jsonl" "not found in $AMBIENT_EXPIRED"
fi

# ── Case 2: lease expired 2 min ago (within 5 min grace) → must NOT delete ───
LOCKS_GRACE="$TMPDIR_BASE/locks-grace"
AMBIENT_GRACE="$TMPDIR_BASE/ambient-grace.jsonl"
mkdir -p "$LOCKS_GRACE"

GRACE_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(seconds=120)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

cat > "$LOCKS_GRACE/test-session-grace.json" <<EOF
{"session_id":"test-session-grace","gap_id":"TEST-GRACE","expires_at":"$GRACE_TS","taken_at":"$GRACE_TS"}
EOF

QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$LOCKS_GRACE" \
CHUMP_AMBIENT_LOG="$AMBIENT_GRACE" \
    bash scripts/ops/queue-health-monitor.sh 2>&1 || true

if [[ -f "$LOCKS_GRACE/test-session-grace.json" ]]; then
    check "recently expired lease (2 min, within 5 min grace) is not deleted" "ok"
else
    check "recently expired lease (2 min, within 5 min grace) is not deleted" "file was incorrectly deleted"
fi

# ── Case 3: lease not yet expired → must NOT delete ──────────────────────────
LOCKS_LIVE="$TMPDIR_BASE/locks-live"
AMBIENT_LIVE="$TMPDIR_BASE/ambient-live.jsonl"
mkdir -p "$LOCKS_LIVE"

FUTURE_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) + timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

cat > "$LOCKS_LIVE/test-session-live.json" <<EOF
{"session_id":"test-session-live","gap_id":"TEST-LIVE","expires_at":"$FUTURE_TS","taken_at":"2026-01-01T00:00:00Z"}
EOF

QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$LOCKS_LIVE" \
CHUMP_AMBIENT_LOG="$AMBIENT_LIVE" \
    bash scripts/ops/queue-health-monitor.sh 2>&1 || true

if [[ -f "$LOCKS_LIVE/test-session-live.json" ]]; then
    check "live (not-yet-expired) lease is not deleted" "ok"
else
    check "live (not-yet-expired) lease is not deleted" "file was incorrectly deleted"
fi

# ── Case 4: non-lease JSON (pr-stuck-state.json) → must NOT delete ────────────
LOCKS_NOLEASE="$TMPDIR_BASE/locks-nolease"
AMBIENT_NOLEASE="$TMPDIR_BASE/ambient-nolease.jsonl"
mkdir -p "$LOCKS_NOLEASE"

cat > "$LOCKS_NOLEASE/pr-stuck-state.json" <<EOF
{"123":{"first_alert_ts":1000,"line":"#123 BLOCKED auto=squash age=50m"}}
EOF

QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$LOCKS_NOLEASE" \
CHUMP_AMBIENT_LOG="$AMBIENT_NOLEASE" \
    bash scripts/ops/queue-health-monitor.sh 2>&1 || true

if [[ -f "$LOCKS_NOLEASE/pr-stuck-state.json" ]]; then
    check "non-lease JSON (pr-stuck-state.json) is not deleted" "ok"
else
    check "non-lease JSON (pr-stuck-state.json) is not deleted" "file was incorrectly deleted"
fi

# ── Case 5: dry-run — expired lease must NOT be deleted, but output mentions alert ──
LOCKS_DRY="$TMPDIR_BASE/locks-dry"
AMBIENT_DRY="$TMPDIR_BASE/ambient-dry.jsonl"
mkdir -p "$LOCKS_DRY"

cat > "$LOCKS_DRY/test-session-dry.json" <<EOF
{"session_id":"test-session-dry","gap_id":"TEST-DRY","expires_at":"$EXPIRED_TS","taken_at":"$EXPIRED_TS"}
EOF

dry_output="$(QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$LOCKS_DRY" \
CHUMP_AMBIENT_LOG="$AMBIENT_DRY" \
    bash scripts/ops/queue-health-monitor.sh --dry-run 2>&1 || true)"

if [[ -f "$LOCKS_DRY/test-session-dry.json" ]]; then
    check "dry-run does not delete expired lease file" "ok"
else
    check "dry-run does not delete expired lease file" "file was incorrectly deleted in dry-run"
fi

if echo "$dry_output" | grep -q "lease_expired_server"; then
    check "dry-run output mentions lease_expired_server alert" "ok"
else
    check "dry-run output mentions lease_expired_server alert" "expected 'lease_expired_server' in dry-run output; got: $dry_output"
fi

# ── Structural checks ─────────────────────────────────────────────────────────
bash -n scripts/ops/queue-health-monitor.sh
check "queue-health-monitor.sh passes bash -n syntax check" "ok"

bash -n scripts/ci/test-infra-115-lease-ttl-file.sh
check "test-infra-115-lease-ttl-file.sh passes bash -n syntax check" "ok"

if grep -q "lease_expired_server" scripts/ops/queue-health-monitor.sh; then
    check "queue-health-monitor.sh emits lease_expired_server alert kind" "ok"
else
    check "queue-health-monitor.sh emits lease_expired_server alert kind" "missing lease_expired_server in monitor"
fi

if grep -q "LEASE_GRACE_SEC" scripts/ops/queue-health-monitor.sh; then
    check "queue-health-monitor.sh has LEASE_GRACE_SEC config knob" "ok"
else
    check "queue-health-monitor.sh has LEASE_GRACE_SEC config knob" "missing LEASE_GRACE_SEC"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "[test-infra-115] Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "[test-infra-115] OK"
