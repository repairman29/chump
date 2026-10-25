#!/usr/bin/env bash
# RESILIENT-1706: verify slim migration (RESILIENT-1691) and cuphead-stop resilience.
# Usage: slim-migration-verify.sh [--static|--live] [--watch-secs N]
#   --static (default): manifest placement checks only (safe anywhere, CI-friendly)
#   --live: also check this node's units, Mac LaunchAgents, fleet-doctor
#   --watch-secs N: poll fleet-doctor + heartbeat for N seconds (run on slim
#                   WHILE cuphead is stopped by the operator; this script never
#                   stops cuphead itself)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/scripts/ops/organ-manifest.yaml"
MODE=static WATCH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --static) MODE=static ;;
    --live) MODE=live ;;
    --watch-secs) WATCH="${2:?}"; MODE=live; shift ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
  shift
done
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }

# AC5: every organ declares a home; count per home
if [[ ! -f "$MANIFEST" ]]; then bad "AC5 organ manifest missing"; else
  missing=$(awk '/^  - unit:/{if(u&&!h)print u; u=$3; h=0} /^    home:/{h=1} END{if(u&&!h)print u}' "$MANIFEST")
  [[ -z "$missing" ]] && ok "AC5 every organ declares home" || bad "AC5 organs without home: $missing"
  for h in cuphead slim mac closetjunky; do
    echo "INFO  organs home=$h: $(grep -c "^    home: $h\$" "$MANIFEST")"
  done
  # Intake (discord) must live on slim once migrated (RESILIENT-1705)
  awk '/^  - unit:/{u=$3} /^    home:/{if(u ~ /discord/)print u, $2}' "$MANIFEST" | while read -r u h; do
    [[ "$h" == slim ]] && echo "PASS  AC5 $u home=slim" || echo "FAIL  AC5 $u home=$h (expected slim)"
  done | tee /tmp/.slim-verify-discord.$$ ; grep -q '^FAIL' /tmp/.slim-verify-discord.$$ && fail=1; rm -f /tmp/.slim-verify-discord.$$
fi

if [[ "$MODE" == live ]]; then
  # AC1: units on this node limited to build-path organs when run on cuphead
  if [[ "$(hostname)" == cuphead ]] && command -v systemctl >/dev/null; then
    allow='node-orchestrator|worker|conductor|nba-dispatch|review-organ|node-refresh|reaper|pr-auto-rebase'
    extra=$(systemctl list-units 'chump-*' --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -Ev "$allow" || true)
    [[ -z "$extra" ]] && ok "AC1 cuphead runs only build-path organs" || bad "AC1 non-build-path units on cuphead: $(echo $extra)"
  else
    echo "SKIP  AC1 (not on cuphead)"
  fi
  # AC2: Mac LaunchAgents
  if [[ "$(uname)" == Darwin ]]; then
    extra=$(ls ~/Library/LaunchAgents/com.chump.* 2>/dev/null | grep -Ev 'observer|watch-only' || true)
    [[ -z "$extra" ]] && ok "AC2 no non-observer chump LaunchAgents" || bad "AC2 LaunchAgents: $(echo $extra)"
  else
    echo "SKIP  AC2 (not macOS)"
  fi
  # AC4: fleet-doctor
  if bash "$ROOT/scripts/coord/fleet-doctor-strict.sh" >/dev/null 2>&1; then ok "AC4 fleet-doctor GREEN"; else bad "AC4 fleet-doctor not GREEN"; fi
  # AC3: watch window
  if (( WATCH > 0 )); then
    end=$(( $(date +%s) + WATCH )); n=0; red=0
    while (( $(date +%s) < end )); do
      n=$((n+1))
      bash "$ROOT/scripts/coord/fleet-doctor-strict.sh" >/dev/null 2>&1 || { red=$((red+1)); echo "RED   sample $n at $(date -u +%H:%M:%SZ)"; }
      sleep 30
    done
    (( red == 0 )) && ok "AC3/AC4 $n samples over ${WATCH}s all GREEN" || bad "AC3/AC4 $red/$n samples RED"
  fi
fi
exit $fail
