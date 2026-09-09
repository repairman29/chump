#!/usr/bin/env bash
# scripts/ops/lib/human-touch-timeline.sh — RESILIENT: the durability gauge's
# canonical HUMAN-TOUCH timeline.
#
# A "human touch" is an operator/manual intervention — the fleet needing a
# person, or a person acting on it. This is the SAME family the vital-signs
# human_intervention sign counts (operator-pages-24h.sh's kind-set) widened to
# every intervention marker the fleet actually emits: the fleet recalling the
# operator (operator_recall / trunk_red_operator_recall), a page reaching the
# phone (operator_page / operator_paged / pager_notified / operator_page_ack),
# and a human hand landing on the work (manual_rescue / operator_rescue_invoked
# / operator_recovery_requested). Kept in ONE place so the gauge and any future
# reader converge on one definition of "a human touched the machine".
#
# The set is env-overridable (CHUMP_DURABILITY_HUMAN_KINDS, space-separated) so
# a node that emits a different intervention marker can widen it without a code
# change.
#
# Usage (sourced):
#   source scripts/ops/lib/human-touch-timeline.sh
#   human_touch_timeline "$AMBIENT_LOG" "$SINCE_ISO"   # -> sorted ISO ts, one per line
#   last_human_touch    "$AMBIENT_LOG" "$SINCE_ISO"    # -> latest ISO ts (or empty)
#
# Usage (direct):
#   scripts/ops/lib/human-touch-timeline.sh <ambient_log> <since_iso>
set -uo pipefail

# The canonical human-touch kind-set. operator_notify_suppressed / _direct_message
# are deliberately EXCLUDED — a suppressed or owed-message DM is not a human
# intervention (see notify-operator.sh's escalation discipline).
_DURABILITY_HUMAN_KINDS_DEFAULT="operator_recall trunk_red_operator_recall operator_page operator_paged pager_notified operator_page_ack manual_rescue operator_rescue_invoked operator_recovery_requested operator_escalation"

_human_kinds_regex() {
  local kinds="${CHUMP_DURABILITY_HUMAN_KINDS:-$_DURABILITY_HUMAN_KINDS_DEFAULT}"
  # space-separated -> alternation
  printf '"kind":"(%s)"' "$(printf '%s' "$kinds" | tr ' ' '|' | sed 's/|\{2,\}/|/g; s/^|//; s/|$//')"
}

# human_touch_timeline <ambient_log> <since_iso> -> ascending ISO timestamps,
# one per line, of every human-touch event at/after <since_iso>.
human_touch_timeline() {
  local ambient_log="${1:?human_touch_timeline: ambient_log required}"
  local since="${2:-1970-01-01T00:00:00Z}"
  [[ -f "$ambient_log" ]] || return 0
  local rx; rx="$(_human_kinds_regex)"
  grep -hE "$rx" "$ambient_log" 2>/dev/null \
    | awk -v c="$since" -F'"ts":"' '{split($2,a,"\""); if(a[1]!="" && a[1]>=c) print a[1]}' \
    | sort
}

# last_human_touch <ambient_log> <since_iso> -> the latest human-touch ISO ts in
# window, or empty string when none.
last_human_touch() {
  human_touch_timeline "$1" "${2:-1970-01-01T00:00:00Z}" | tail -n1
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  human_touch_timeline "${1:-.chump-locks/ambient.jsonl}" "${2:-1970-01-01T00:00:00Z}"
fi
