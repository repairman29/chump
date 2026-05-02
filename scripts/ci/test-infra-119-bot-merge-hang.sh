#!/usr/bin/env bash
# INFRA-119 — verify queue-health-monitor.sh detects stale bot-merge health files.
#
# Simulates a hung bot-merge by writing a .health file whose last_heartbeat_at
# is 10 minutes in the past, then asserts the monitor's --dry-run output
# contains a bot_merge_hung alert for that file.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PASS=0
FAIL=0

check() {
    local desc="$1" result="$2"
    if [[ "$result" == "ok" ]]; then
        echo "[test-infra-119] PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "[test-infra-119] FAIL: $desc — $result" >&2
        FAIL=$((FAIL + 1))
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_LOCKS="$TMPDIR_BASE/chump-locks"
mkdir -p "$FAKE_LOCKS"

# ── Case 1: health file with last_heartbeat_at 10 min ago → alert expected ───
STALE_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
stale = datetime.now(timezone.utc) - timedelta(minutes=10)
print(stale.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

cat > "$FAKE_LOCKS/bot-merge-99999.health" <<EOF
{"pid":99999,"started_at":"2026-05-02T00:00:00Z","current_step":"gh pr create","last_heartbeat_at":"$STALE_TS"}
EOF

output="$(QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$FAKE_LOCKS" \
    bash scripts/ops/queue-health-monitor.sh --dry-run 2>&1 || true)"

if echo "$output" | grep -q "bot_merge_hung"; then
    check "stale health file triggers bot_merge_hung alert" "ok"
else
    check "stale health file triggers bot_merge_hung alert" "expected 'bot_merge_hung' in output; got: $output"
fi

if echo "$output" | grep -q "99999"; then
    check "alert includes the pid from the health file" "ok"
else
    check "alert includes the pid from the health file" "expected pid 99999 in output; got: $output"
fi

if echo "$output" | grep -q "gh pr create"; then
    check "alert includes current_step from health file" "ok"
else
    check "alert includes current_step from health file" "expected step 'gh pr create' in output; got: $output"
fi

# ── Case 2: fresh health file (30s ago) → no alert ───────────────────────────
FRESH_LOCKS="$TMPDIR_BASE/chump-locks-fresh"
mkdir -p "$FRESH_LOCKS"

FRESH_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
fresh = datetime.now(timezone.utc) - timedelta(seconds=30)
print(fresh.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

cat > "$FRESH_LOCKS/bot-merge-88888.health" <<EOF
{"pid":88888,"started_at":"2026-05-02T00:00:00Z","current_step":"cargo clippy","last_heartbeat_at":"$FRESH_TS"}
EOF

output2="$(QUEUE_HEALTH_LOCK_DIR_OVERRIDE="$FRESH_LOCKS" \
    bash scripts/ops/queue-health-monitor.sh --dry-run 2>&1 || true)"

if ! echo "$output2" | grep -q "bot_merge_hung"; then
    check "fresh health file does not trigger alert" "ok"
else
    check "fresh health file does not trigger alert" "unexpected 'bot_merge_hung' in output; got: $output2"
fi

# ── Case 3: structural checks on bot-merge.sh ────────────────────────────────
bash -n scripts/coord/bot-merge.sh
check "bot-merge.sh passes bash -n syntax check" "ok"

bash -n scripts/ops/queue-health-monitor.sh
check "queue-health-monitor.sh passes bash -n syntax check" "ok"

if grep -q "_bm_health_init" scripts/coord/bot-merge.sh; then
    check "bot-merge.sh contains _bm_health_init" "ok"
else
    check "bot-merge.sh contains _bm_health_init" "missing _bm_health_init"
fi

if grep -q "bot-merge-.*\.health" scripts/ops/queue-health-monitor.sh; then
    check "queue-health-monitor.sh scans bot-merge-*.health files" "ok"
else
    check "queue-health-monitor.sh scans bot-merge-*.health files" "missing health file scan"
fi

if grep -q "bot_merge_hung" scripts/ops/queue-health-monitor.sh; then
    check "queue-health-monitor.sh emits bot_merge_hung alert kind" "ok"
else
    check "queue-health-monitor.sh emits bot_merge_hung alert kind" "missing bot_merge_hung"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "[test-infra-119] Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "[test-infra-119] OK"
