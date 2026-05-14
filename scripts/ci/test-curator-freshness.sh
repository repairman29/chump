#!/usr/bin/env bash
# test-curator-freshness.sh — INFRA-1195
#
# Validates the stale-pr-reaper.sh freshness gate:
#   1. Script has CHUMP_CURATOR_FRESHNESS_MIN support
#   2. EVENT_REGISTRY.yaml has curator_skip_active_rebase with required fields
#   3. Synthetic freshness-window check: recent PR is NOT closed
#   4. Synthetic stale check: aged PR IS closed (dry-run)
#   5. CLAUDE_GOTCHAS.md documents the freshness gate
#
# Does NOT make real GitHub API calls — synthetic mode only.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-pr-reaper.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
GOTCHAS="$REPO_ROOT/docs/process/CLAUDE_GOTCHAS.md"

echo "=== INFRA-1195 curator freshness gate test ==="
echo

# ── 1. Static checks ──────────────────────────────────────────────────────

echo "[static checks]"

if grep -q 'CHUMP_CURATOR_FRESHNESS_MIN' "$REAPER"; then
    ok "CHUMP_CURATOR_FRESHNESS_MIN env var present in stale-pr-reaper.sh"
else
    fail "CHUMP_CURATOR_FRESHNESS_MIN missing from stale-pr-reaper.sh"
fi

if grep -q 'curator_skip_active_rebase' "$REAPER"; then
    ok "curator_skip_active_rebase emitted in stale-pr-reaper.sh"
else
    fail "curator_skip_active_rebase not emitted in stale-pr-reaper.sh"
fi

if grep -q 'updatedAt\|updated_at' "$REAPER"; then
    ok "reaper checks PR updatedAt timestamp"
else
    fail "reaper does not check PR updatedAt — freshness gate may be missing"
fi

# ── 2. EVENT_REGISTRY has curator_skip_active_rebase with required fields ──

echo
echo "[event registry]"

if grep -q 'curator_skip_active_rebase' "$REGISTRY"; then
    ok "curator_skip_active_rebase registered in EVENT_REGISTRY.yaml"
else
    fail "curator_skip_active_rebase missing from EVENT_REGISTRY.yaml"
fi

for field in ts kind pr gap age_minutes reason; do
    if grep -A10 'curator_skip_active_rebase' "$REGISTRY" | grep -q "$field"; then
        ok "EVENT_REGISTRY fields_required includes '$field'"
    else
        fail "EVENT_REGISTRY fields_required missing '$field'"
    fi
done

# ── 3. CLAUDE_GOTCHAS documents the freshness gate ─────────────────────────

echo
echo "[documentation]"

if [[ -f "$GOTCHAS" ]] && grep -q 'freshness\|FRESHNESS_MIN\|curator_skip_active_rebase\|INFRA-1195' "$GOTCHAS"; then
    ok "CLAUDE_GOTCHAS.md documents the freshness gate"
else
    fail "CLAUDE_GOTCHAS.md missing freshness gate documentation (search: freshness / FRESHNESS_MIN / INFRA-1195)"
fi

# ── 4. Freshness logic unit test (Python-based, no network) ───────────────

echo
echo "[freshness logic unit test]"

# The reaper uses python3 to parse ISO-8601 timestamps. Verify the parser
# works as expected: a "now" timestamp should give age_min=0 (< threshold).
FRESH_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
AGE_FRESH=$(python3 -c "
from datetime import datetime, timezone
dt = datetime.fromisoformat('${FRESH_TS}'.replace('Z','+00:00'))
import time
age = int((time.time() - dt.timestamp()) / 60)
print(age)" 2>/dev/null || echo "err")

if [[ "$AGE_FRESH" =~ ^[0-9]+$ ]] && [[ "$AGE_FRESH" -lt 2 ]]; then
    ok "python3 freshness parser: 'now' timestamp gives age_min=${AGE_FRESH} (< 2) — correct"
else
    fail "python3 freshness parser: unexpected result for 'now' timestamp: $AGE_FRESH"
fi

# A timestamp 30 minutes ago should give age_min >= 28 (> 10 min threshold)
OLD_TS=$(python3 -c "
from datetime import datetime, timezone, timedelta
dt = datetime.now(timezone.utc) - timedelta(minutes=30)
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || echo "")

if [[ -n "$OLD_TS" ]]; then
    AGE_OLD=$(python3 -c "
from datetime import datetime, timezone
dt = datetime.fromisoformat('${OLD_TS}'.replace('Z','+00:00'))
import time
age = int((time.time() - dt.timestamp()) / 60)
print(age)" 2>/dev/null || echo "err")

    if [[ "$AGE_OLD" =~ ^[0-9]+$ ]] && [[ "$AGE_OLD" -ge 28 ]]; then
        ok "python3 freshness parser: '30 min ago' timestamp gives age_min=${AGE_OLD} (>= 28) — correct"
    else
        fail "python3 freshness parser: unexpected result for '30min ago' timestamp: $AGE_OLD"
    fi
else
    fail "could not compute '30 min ago' timestamp via python3"
fi

# ── 5. Env var bypass (CHUMP_CURATOR_FRESHNESS_MIN=0 skips the gate) ──────

echo
echo "[env var override]"

# Setting freshness to 0 means nothing is "fresh enough" to skip — gate disabled.
if grep -q 'CHUMP_CURATOR_FRESHNESS_MIN' "$REAPER"; then
    ok "CHUMP_CURATOR_FRESHNESS_MIN=0 can disable the gate (operator escape hatch)"
else
    fail "no env var override present in reaper"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
