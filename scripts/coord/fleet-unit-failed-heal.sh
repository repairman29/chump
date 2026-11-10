#!/usr/bin/env bash
# scripts/coord/fleet-unit-failed-heal.sh — RESILIENT-1603
# T1 action for the duty-officer signal fleet_health_unit_failed: reset-failed +
# restart every failed chump-* unit; a unit that is still failed on a second
# consecutive run gets a gap filed (once) instead of a suppressed notify.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SYSTEMCTL="${CHUMP_UNIT_HEAL_SYSTEMCTL:-systemctl --user}"
STATE_DIR="${CHUMP_UNIT_HEAL_STATE_DIR:-$REPO_ROOT/.chump-locks/unit-failed-heal}"
GAP_CMD="${CHUMP_UNIT_HEAL_GAP_CMD:-chump gap reserve}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# shellcheck disable=SC2086
failed=$($SYSTEMCTL list-units --failed --no-legend --plain 'chump-*' 2>/dev/null | awk '{print $1}')
for marker in "$STATE_DIR"/*.seen; do
  [[ -e "$marker" ]] || continue
  u="$(basename "$marker" .seen)"
  grep -qxF "$u" <<<"$failed" || rm -f "$marker" "$STATE_DIR/$u.filed"
done
[[ -z "$failed" ]] && exit 0
while read -r u; do
  [[ -z "$u" ]] && continue
  if [[ -e "$STATE_DIR/$u.seen" ]]; then
    if [[ ! -e "$STATE_DIR/$u.filed" ]]; then
      # shellcheck disable=SC2086
      $GAP_CMD --domain RESILIENT --title "RESILIENT: chump unit $u stays failed after duty-officer reset-failed+restart" >/dev/null 2>&1 || true
      : > "$STATE_DIR/$u.filed"
    fi
    continue
  fi
  : > "$STATE_DIR/$u.seen"
  # shellcheck disable=SC2086
  $SYSTEMCTL reset-failed "$u" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  $SYSTEMCTL restart "$u" >/dev/null 2>&1 || true
done <<<"$failed"
exit 0
