#!/usr/bin/env bash
# test-fleet-auto-prune.sh — INFRA-650
#
# Validates chump fleet auto-resize (fleet auto-prune-down controller):
#  - auto-resize subcommand exists and responds
#  - no-trigger case: clean environment → no resize
#  - queue-empty trigger: marker set 31 min ago → resize recommended
#  - flat-ship-rate trigger: no pr_merged in 75 min → resize recommended
#  - operator-absent trigger: autonomous mode + 25h absence → resize to 1
#  - --apply writes fleet-desired-size and emits ambient events
#  - fleet_resize_decision event kind emitted
#  - auto-resize in fleet help text

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"

echo "=== INFRA-650 fleet auto-resize test ==="
echo

# Prerequisite: binary exists
if [[ ! -f "$CHUMP" ]]; then
    echo "  SKIP: chump binary not built at $CHUMP; run: cargo build --bin chump"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

setup_env() {
    local root="$1"
    mkdir -p "$root/.chump" "$root/.chump-locks"
    echo "2" > "$root/.chump/fleet-desired-size"
    touch "$root/.chump-locks/ambient.jsonl"
}

# ── 1. Help text includes auto-resize ────────────────────────────────────────
echo "[help text]"
HELP_OUT="$("$CHUMP" fleet 2>&1 || true)"
if echo "$HELP_OUT" | grep -q 'auto-resize'; then
    ok "auto-resize appears in 'chump fleet' help text"
else
    fail "auto-resize missing from 'chump fleet' help text"
fi

# ── 2. No-trigger case ────────────────────────────────────────────────────────
echo
echo "[no-trigger case]"
CLEAN="$TMP/clean"
setup_env "$CLEAN"

OUT="$(CHUMP_REPO="$CLEAN" CHUMP_HOME="$CLEAN" "$CHUMP" fleet auto-resize 2>&1 || true)"
if echo "$OUT" | grep -qi 'no resize trigger'; then
    ok "no-trigger: reports 'no resize trigger fired'"
else
    fail "no-trigger: unexpected output: $OUT"
fi

# ── 3. Queue-empty trigger ────────────────────────────────────────────────────
echo
echo "[queue-empty trigger]"
QEROOT="$TMP/queue-empty"
setup_env "$QEROOT"
OLD_TS=$(( $(date +%s) - 1860 ))  # 31 min ago
echo "$OLD_TS" > "$QEROOT/.chump/queue-empty-since"

OUT="$(CHUMP_REPO="$QEROOT" CHUMP_HOME="$QEROOT" "$CHUMP" fleet auto-resize 2>&1 || true)"
if echo "$OUT" | grep -qi 'QueueEmpty\|queue.empty'; then
    ok "queue-empty trigger fires when marker is 31 min old"
else
    fail "queue-empty trigger did not fire (output: $OUT)"
fi

# ── 4. Flat ship rate trigger ─────────────────────────────────────────────────
echo
echo "[flat-ship-rate trigger]"
FSROOT="$TMP/flat-ship"
setup_env "$FSROOT"
# Write a stale pr_merged event (75 min ago)
STALE_TS="$(python3 -c "
from datetime import datetime, timezone, timedelta
t = datetime.now(timezone.utc) - timedelta(minutes=75)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null)"
printf '{"ts":"%s","kind":"pr_merged","pr":99}\n' "$STALE_TS" > "$FSROOT/.chump-locks/ambient.jsonl"

OUT="$(CHUMP_REPO="$FSROOT" CHUMP_HOME="$FSROOT" "$CHUMP" fleet auto-resize 2>&1 || true)"
if echo "$OUT" | grep -qi 'FlatShipRate\|flat.ship'; then
    ok "flat-ship-rate trigger fires when no merge in 75 min"
else
    fail "flat-ship-rate trigger did not fire (output: $OUT)"
fi

# ── 5. Operator-absent trigger ────────────────────────────────────────────────
echo
echo "[operator-absent trigger]"
OAROOT="$TMP/op-absent"
setup_env "$OAROOT"
touch "$OAROOT/.chump/autonomous-mode"
OLD_ACTIVITY=$(( $(date +%s) - 90000 ))  # 25h ago
echo "$OLD_ACTIVITY" > "$OAROOT/.chump/last-operator-activity"

OUT="$(CHUMP_REPO="$OAROOT" CHUMP_HOME="$OAROOT" "$CHUMP" fleet auto-resize 2>&1 || true)"
if echo "$OUT" | grep -qi 'OperatorAbsent\|operator.absent'; then
    ok "operator-absent trigger fires after 25h absence"
else
    fail "operator-absent trigger did not fire (output: $OUT)"
fi
if echo "$OUT" | grep -q 'recommended=1\|recommended_size.*1'; then
    ok "operator-absent recommends scale to 1"
else
    # recommended_size=1 may appear in JSON output
    if echo "$OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read().strip()); exit(0 if d.get('recommended_size')==1 else 1)" 2>/dev/null; then
        ok "operator-absent recommends scale to 1 (json)"
    else
        fail "operator-absent: expected recommendation to scale to 1 (output: $OUT)"
    fi
fi

# ── 6. --apply writes fleet-desired-size and emits ambient event ──────────────
echo
echo "[--apply behavior]"
APROOT="$TMP/apply"
setup_env "$APROOT"
OLD_TS2=$(( $(date +%s) - 1900 ))
echo "$OLD_TS2" > "$APROOT/.chump/queue-empty-since"

CHUMP_REPO="$APROOT" CHUMP_HOME="$APROOT" "$CHUMP" fleet auto-resize --apply 2>&1 | head -10 || true

NEW_SIZE="$(cat "$APROOT/.chump/fleet-desired-size" 2>/dev/null || echo "2")"
if [[ "$NEW_SIZE" -lt 2 ]]; then
    ok "--apply writes reduced fleet-desired-size ($NEW_SIZE < 2)"
else
    fail "--apply did not reduce fleet-desired-size (got $NEW_SIZE)"
fi

if grep -q 'fleet_resize_decision' "$APROOT/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "--apply emits fleet_resize_decision to ambient.jsonl"
else
    fail "--apply did not emit fleet_resize_decision to ambient.jsonl"
fi

if grep -q 'fleet_scale_change' "$APROOT/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "--apply emits fleet_scale_change to ambient.jsonl"
else
    fail "--apply did not emit fleet_scale_change to ambient.jsonl"
fi

# ── 7. JSON output ────────────────────────────────────────────────────────────
echo
echo "[json output]"
JROOT="$TMP/json"
setup_env "$JROOT"
OLD_TS3=$(( $(date +%s) - 1900 ))
echo "$OLD_TS3" > "$JROOT/.chump/queue-empty-since"

JSON_OUT="$(CHUMP_REPO="$JROOT" CHUMP_HOME="$JROOT" "$CHUMP" fleet auto-resize --json 2>&1 || true)"
if echo "$JSON_OUT" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        assert 'fleet_resize_decision' in d, f'missing field: {d}'
        break
    except json.JSONDecodeError:
        pass
" 2>/dev/null; then
    ok "json output contains fleet_resize_decision field"
else
    fail "json output missing fleet_resize_decision (got: $JSON_OUT)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
