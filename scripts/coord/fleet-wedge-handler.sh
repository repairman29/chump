#!/usr/bin/env bash
# fleet-wedge-handler.sh — INFRA-845
#
# Detection + escalation + recovery for fleet_wedge events.
#
# Behavior:
#   1. Scan recent ambient.jsonl for kind=fleet_wedge events.
#   2. On first wedge after a clean window: mark fleet-state.wedged=true,
#      scale down workers 3-5 (tmux kill-pane), emit fleet_scale_change.
#   3. If wedge persists > CHUMP_WEDGE_ESCALATE_S seconds (default 1800):
#      emit fleet_wedge_escalated, append to docs/incidents/YYYY-MM-DD-wedge.md,
#      POST to CHUMP_PAGER_WEBHOOK if set, set wedge_escalated=true.
#   4. When no fleet_wedge events have arrived in last CHUMP_WEDGE_CLEAR_S
#      seconds (default 1800) AND wedged=true: emit fleet_wedge_resolved,
#      reset wedge state.
#
# This script is intended to be invoked from emergency-fast-path.sh on each
# 5-min scheduled tick (INFRA-841 frequency-aware scheduling).
#
# Env:
#   CHUMP_AMBIENT_LOG          path to ambient.jsonl
#   CHUMP_FLEET_STATE          path to fleet-state.json
#   CHUMP_WEDGE_ESCALATE_S     seconds before escalation (default 1800 = 30min)
#   CHUMP_WEDGE_CLEAR_S        seconds of quiet before resolution (default 1800)
#   CHUMP_PAGER_WEBHOOK        optional URL to POST escalation payload to
#   CHUMP_WEDGE_DRY_RUN=1      skip mutations (test mode)

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FLEET_STATE="${CHUMP_FLEET_STATE:-$REPO_ROOT/.chump-locks/fleet-state.json}"
ESCALATE_S="${CHUMP_WEDGE_ESCALATE_S:-1800}"
CLEAR_S="${CHUMP_WEDGE_CLEAR_S:-1800}"
DRY_RUN="${CHUMP_WEDGE_DRY_RUN:-0}"
_FAST_PATH="$REPO_ROOT/scripts/coord/emergency-fast-path.sh"

_emit() {
  local kind="$1"; shift
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$*" \
    >> "$AMBIENT" 2>/dev/null || true
}

# Read a top-level field from fleet-state.json (empty on miss).
# Python booleans get lower-cased so shell `[[ "$v" == "true" ]]` works.
_fs_get() {
  local key="$1"
  [[ -f "$FLEET_STATE" ]] || { echo ""; return; }
  python3 -c "
import json
try:
    d = json.load(open('$FLEET_STATE'))
    v = d.get('$key', '')
    if v is None:
        print('')
    elif isinstance(v, bool):
        print('true' if v else 'false')
    else:
        print(v)
except Exception:
    print('')
"
}

# Write a top-level field via emergency-fast-path.sh (flock-protected) or
# direct fallback. Skipped in dry-run mode.
_fs_set() {
  local key="$1" val="$2"
  [[ "$DRY_RUN" == "1" ]] && return 0
  if [[ -x "$_FAST_PATH" ]]; then
    bash "$_FAST_PATH" set-field "$key" "$val" >/dev/null 2>&1 || true
  elif command -v python3 &>/dev/null && [[ -f "$FLEET_STATE" ]]; then
    python3 -c "
import json, sys
d = json.load(open('$FLEET_STATE'))
d['$key'] = '$val' if '$val' not in ('true','false') else ('$val' == 'true')
json.dump(d, open('$FLEET_STATE','w'))
" || true
  fi
}

# Count fleet_wedge events in last N seconds.
_count_recent_wedges() {
  local window_s="${1:-300}"
  [[ -f "$AMBIENT" ]] || { echo 0; return; }
  local cutoff
  cutoff="$(python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(seconds=$window_s)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  awk -v c="$cutoff" '/"kind":"fleet_wedge"/ {
    # crude ts extraction; line is JSON
    if (match($0, /"ts":"[^"]+"/)) {
      ts = substr($0, RSTART+6, RLENGTH-7)
      if (ts > c) count++
    }
  } END { print count+0 }' "$AMBIENT"
}

# Get the timestamp of the most recent fleet_wedge event, or empty.
_last_wedge_ts() {
  [[ -f "$AMBIENT" ]] || { echo ""; return; }
  grep '"kind":"fleet_wedge"' "$AMBIENT" 2>/dev/null \
    | tail -n 1 \
    | python3 -c "
import sys, re
line = sys.stdin.read()
m = re.search(r'\"ts\":\"([^\"]+)\"', line)
print(m.group(1) if m else '')
" || echo ""
}

_age_seconds() {
  local ts="$1"
  [[ -z "$ts" ]] && { echo 999999; return; }
  python3 -c "
import datetime
try:
    t = datetime.datetime.strptime('$ts', '%Y-%m-%dT%H:%M:%SZ')
    delta = datetime.datetime.utcnow() - t
    print(int(delta.total_seconds()))
except Exception:
    print(999999)
"
}

# Scale down: kill tmux worker panes 3-5. Best-effort.
_scale_down() {
  [[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] would kill fleet-worker-{3,4,5}"; return; }
  if command -v tmux &>/dev/null; then
    for n in 3 4 5; do
      tmux kill-pane -t "fleet-worker-${n}" 2>/dev/null || true
    done
  fi
}

# Append a short incident record. Best-effort.
_record_incident() {
  local kind="$1" age_s="$2"
  local today; today="$(date -u +%Y-%m-%d)"
  local path="$REPO_ROOT/docs/incidents/${today}-wedge.md"
  [[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] would append incident to $path"; return; }
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  if [[ ! -f "$path" ]]; then
    {
      echo "# Fleet wedge incident — $today"
      echo
      echo "Records of fleet_wedge events handled by scripts/coord/fleet-wedge-handler.sh."
      echo "INFRA-845: escalation + paging."
      echo
    } > "$path"
  fi
  {
    echo "## $(date -u +%H:%M:%SZ) — $kind"
    echo "- wedge_age_seconds: $age_s"
    echo "- escalate_threshold_s: $ESCALATE_S"
    echo "- handler: scripts/coord/fleet-wedge-handler.sh"
    echo
  } >> "$path"
}

# POST escalation payload to CHUMP_PAGER_WEBHOOK if set.
_page() {
  local age_s="$1"
  local hook="${CHUMP_PAGER_WEBHOOK:-}"
  [[ -z "$hook" ]] && return 0
  [[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] would POST escalation to $hook"; return; }
  if command -v curl &>/dev/null; then
    local payload
    payload="$(python3 -c "
import json, datetime, os
print(json.dumps({
    'kind': 'fleet_wedge_escalation',
    'ts': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'wedge_age_seconds': int('$age_s'),
    'recommendation': 'manual review needed; auto-scale-down already applied',
    'host': os.uname().nodename,
}))")"
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "$payload" --max-time 10 "$hook" >/dev/null 2>&1 || true
    _emit "pager_notified" "\"webhook\":\"set\",\"event\":\"fleet_wedge_escalation\""
  fi
}

# ── Main detection / escalation / recovery flow ───────────────────────────────
main() {
  local wedged_now; wedged_now=$(_fs_get wedged)
  local recent; recent=$(_count_recent_wedges 600)
  local last_ts; last_ts=$(_last_wedge_ts)
  local age_s; age_s=$(_age_seconds "$last_ts")
  local wedge_start; wedge_start=$(_fs_get wedge_start)
  local wedge_escalated; wedge_escalated=$(_fs_get wedge_escalated)

  # 1) Fresh wedge detected: scale down + mark state.
  if [[ "$recent" -gt 0 && "$wedged_now" != "true" ]]; then
    echo "[fleet-wedge-handler] fresh wedge detected; scaling down to 2 workers"
    _scale_down
    _emit "fleet_scale_change" '"from":4,"to":2,"rationale":"fleet_wedge_emergency","handler":"fleet-wedge-handler"'
    _fs_set "wedged" "true"
    _fs_set "wedge_start" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _fs_set "wedge_escalated" "false"
    return 0
  fi

  # 2) Persistent wedge: escalate if past threshold.
  if [[ "$wedged_now" == "true" && "$wedge_escalated" != "true" ]]; then
    local since_start; since_start=$(_age_seconds "$wedge_start")
    if [[ "$since_start" -ge "$ESCALATE_S" ]]; then
      echo "[fleet-wedge-handler] wedge persisted ${since_start}s ≥ ${ESCALATE_S}s — escalating"
      _emit "fleet_wedge_escalated" \
        '"wedge_age_s":'"$since_start"',"threshold_s":'"$ESCALATE_S"',"handler":"fleet-wedge-handler"'
      _record_incident "escalated" "$since_start"
      _page "$since_start"
      _fs_set "wedge_escalated" "true"
    fi
    return 0
  fi

  # 3) Recovery: wedged state but no recent wedge events.
  if [[ "$wedged_now" == "true" && "$recent" -eq 0 && "$age_s" -ge "$CLEAR_S" ]]; then
    echo "[fleet-wedge-handler] no wedge events in ${age_s}s ≥ ${CLEAR_S}s — resolving"
    _emit "fleet_wedge_resolved" \
      '"quiet_window_s":'"$age_s"',"handler":"fleet-wedge-handler"'
    _record_incident "resolved" "$age_s"
    _fs_set "wedged" "false"
    _fs_set "wedge_start" ""
    _fs_set "wedge_escalated" "false"
    return 0
  fi

  # 4) No-op: clean state, no recent wedges.
  echo "[fleet-wedge-handler] clean (wedged=${wedged_now:-false}, recent=${recent})"
  return 0
}

main "$@"
