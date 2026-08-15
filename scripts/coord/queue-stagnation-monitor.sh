#!/usr/bin/env bash
# scripts/coord/queue-stagnation-monitor.sh — INFRA-2353 (META-269 sub-4)
#
# Queue-stagnation alarm. operator-recall.sh's QUEUE_STARVE condition only
# fires when pickable_count == 0 — it is blind to the "queue has plenty of
# real work but nobody is claiming it" failure mode (dead workers, wedged
# auth, stuck picker). This monitor closes that gap: it fires when the
# pickable-gap queue is non-trivially large (> threshold) AND zero
# kind=gap_claimed events have landed in ambient.jsonl in the idle window.
#
# Designed for a periodic (e.g. hourly) launchd tick — the 24h default
# window means running more often just re-checks the same rolling window,
# so a coarse cadence is fine.
#
# Usage:
#   queue-stagnation-monitor.sh
#
# Env:
#   CHUMP_QUEUE_STAGNATION_DISABLE       set 1 to short-circuit (default 0)
#   CHUMP_QUEUE_STAGNATION_MIN_PICKABLE  pickable-count threshold (default 10)
#   CHUMP_QUEUE_STAGNATION_WINDOW_SECS   idle window in seconds (default 86400)
#   CHUMP_QUEUE_STAGNATION_STATE_DB      path to state.db (test override)
#   CHUMP_QUEUE_STAGNATION_AMBIENT_PATH  path to ambient.jsonl (test override)
#
# Emitted ambient kinds:
#   scanner-anchor: "kind":"queue_stagnant"
#   scanner-anchor: "kind":"queue_stagnation_monitor_tick"
set -euo pipefail

if [ "${CHUMP_QUEUE_STAGNATION_DISABLE:-0}" = "1" ]; then
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

STATE_DB="${CHUMP_QUEUE_STAGNATION_STATE_DB:-$REPO_ROOT/.chump/state.db}"
AMBIENT_PATH="${CHUMP_QUEUE_STAGNATION_AMBIENT_PATH:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
MIN_PICKABLE="${CHUMP_QUEUE_STAGNATION_MIN_PICKABLE:-10}"
WINDOW_SECS="${CHUMP_QUEUE_STAGNATION_WINDOW_SECS:-86400}"

emit_ambient() {
  local kind="$1" extra_fields="$2"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$AMBIENT_PATH")" 2>/dev/null || true
  local line
  line="$(printf '{"ts":"%s","kind":"%s"%s}' "$ts" "$kind" "$extra_fields")"
  echo "$line" >> "$AMBIENT_PATH"
  echo "[queue-stagnation-monitor] EMIT: $line" >&2
}

# ── pickable-gap count (status='open' in state.db) ─────────────────────────
pickable_count=0
if [ -f "$STATE_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  pickable_count="$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps WHERE status='open';" 2>/dev/null || echo 0)"
fi
pickable_count="${pickable_count//[[:space:]]/}"
case "$pickable_count" in ''|*[!0-9]*) pickable_count=0 ;; esac

# ── gap_claimed events in the idle window ───────────────────────────────────
claimed_count=0
if [ -f "$AMBIENT_PATH" ]; then
  claimed_count="$(python3 - "$AMBIENT_PATH" "$WINDOW_SECS" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

path, window = sys.argv[1], int(sys.argv[2])
now = datetime.now(timezone.utc).timestamp()
since = now - window
count = 0
with open(path, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line or '"kind":"gap_claimed"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        ts = obj.get("ts", "").rstrip("Z")
        try:
            epoch = datetime.fromisoformat(ts).replace(tzinfo=timezone.utc).timestamp()
        except Exception:
            continue
        if epoch >= since:
            count += 1
print(count)
PYEOF
  )"
fi
claimed_count="${claimed_count//[[:space:]]/}"
case "$claimed_count" in ''|*[!0-9]*) claimed_count=0 ;; esac

window_hours=$(( WINDOW_SECS / 3600 ))

if [ "$pickable_count" -gt "$MIN_PICKABLE" ] && [ "$claimed_count" -eq 0 ]; then
  reason="pickable-gap queue has ${pickable_count} open gaps (> ${MIN_PICKABLE}) but 0 gap_claimed events in the last ${window_hours}h; queue is stagnant"
  emit_ambient "queue_stagnant" ",\"pickable_count\":${pickable_count},\"claimed_count\":${claimed_count},\"window_secs\":${WINDOW_SECS},\"reason\":\"${reason}\""

  RECALL_SCRIPT="$REPO_ROOT/scripts/dispatch/operator-recall.sh"
  if [ -x "$RECALL_SCRIPT" ]; then
    CHUMP_AMBIENT_LOG="$AMBIENT_PATH" "$RECALL_SCRIPT" --condition QUEUE_STARVE --reason "$reason" || true
  fi
else
  echo "[queue-stagnation-monitor] ok: pickable=${pickable_count} claimed=${claimed_count} in last ${window_hours}h (threshold=${MIN_PICKABLE})" >&2
fi

emit_ambient "queue_stagnation_monitor_tick" ",\"pickable_count\":${pickable_count},\"claimed_count\":${claimed_count}"

exit 0
