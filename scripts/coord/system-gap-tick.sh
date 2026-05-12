#!/usr/bin/env bash
# system-gap-tick.sh — INFRA-841
#
# Emit a `kind=system_gap_tick` ambient event for a scheduled task.
# Sourced by opus-curator.sh and emergency-fast-path.sh; can also be
# invoked directly for ad-hoc heartbeat emission.
#
# Usage:
#   source scripts/coord/system-gap-tick.sh
#   emit_system_gap_tick <task_name>
#
#   # or directly:
#   scripts/coord/system-gap-tick.sh emit <task_name>
#
# Env:
#   CHUMP_AMBIENT_LOG       path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   CHUMP_FREQ_YAML         path to system-gap-frequencies.yaml
#                           (default: scripts/coord/system-gap-frequencies.yaml)
#   CHUMP_TICK_DISABLE=1    skip emission (test/dry-run mode)

_sgt_amb() {
  printf '%s' "${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
}

_sgt_yaml() {
  printf '%s' "${CHUMP_FREQ_YAML:-scripts/coord/system-gap-frequencies.yaml}"
}

# _sgt_lookup_interval <task_name> → prints interval_s or empty string.
# Portable (no gawk-only match-with-array). Tolerates the simple two-space
# nested layout used by system-gap-frequencies.yaml.
_sgt_lookup_interval() {
  local task="$1"
  local yaml; yaml="$(_sgt_yaml)"
  [[ -f "$yaml" ]] || { printf ''; return; }
  awk -v t="$task" '
    /^tasks:/ { in_tasks = 1; next }
    in_tasks && /^[a-zA-Z]/ && !/^tasks:/ { in_tasks = 0 }
    in_tasks && /^  [a-z0-9_-]+:[[:space:]]*$/ {
      gsub(/^  /, ""); gsub(/:[[:space:]]*$/, "")
      cur = $0; next
    }
    in_tasks && cur == t && /^    interval_s:[[:space:]]+[0-9]+/ {
      gsub(/^    interval_s:[[:space:]]+/, "")
      gsub(/[[:space:]].*$/, "")
      print; exit
    }
  ' "$yaml"
}

# emit_system_gap_tick <task_name>
# Append a JSON event to ambient.jsonl. Best-effort — never fails the caller.
emit_system_gap_tick() {
  [[ "${CHUMP_TICK_DISABLE:-0}" == "1" ]] && return 0
  local task="${1:-unknown}"
  local interval; interval="$(_sgt_lookup_interval "$task")"
  local interval_field=""
  [[ -n "$interval" ]] && interval_field=',"interval_s":'"$interval"
  local run_id; run_id="$(date +%s)-$$"
  local amb; amb="$(_sgt_amb)"
  mkdir -p "$(dirname "$amb")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"system_gap_tick","task":"%s"%s,"run_id":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task" "$interval_field" "$run_id" \
    >> "$amb" 2>/dev/null || true
}

# Direct CLI invocation: `system-gap-tick.sh emit <task_name>`
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  case "${1:-}" in
    emit)
      emit_system_gap_tick "${2:-unknown}"
      ;;
    lookup)
      _sgt_lookup_interval "${2:-}"
      ;;
    *)
      echo "Usage: $0 {emit <task>|lookup <task>}" >&2
      exit 1
      ;;
  esac
fi
