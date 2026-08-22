#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# CREDIBLE: pillar-balance analyzer. Counts pickable open gaps per pillar
# (EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE, classified by title prefix)
# and emits ambient alerts when a pillar is starved (<2 pickable) or
# overweight (>50% of the total pickable pool). Exits non-zero if any
# alert fired. Wired into `chump gap audit-priorities`.
#
# "Pickable" here mirrors the picker's own criteria: priority P0/P1,
# effort xs/s (m is allowed but flagged WARN), acceptance_criteria that
# isn't a TODO/TBD stub, and no unresolved (non-done) dependency.
#
# Bash-3.2 compatible: no `declare -A`, `declare -n`, `mapfile`, or
# `readarray` (the fleet's macOS workers run /bin/bash 3.2).
#
# Usage:
#   pillar-balance-check.sh [--json]
#   CHUMP_BIN=/path/to/chump pillar-balance-check.sh
#   CHUMP_AMBIENT_LOG=/path/to/ambient.jsonl pillar-balance-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
WANT_JSON=0
FLOOR=2

for a in "$@"; do
    case "$a" in
        --json) WANT_JSON=1 ;;
    esac
done

mkdir -p "$(dirname "$AMBIENT")"

ALL_JSON="$("$CHUMP_BIN" gap list --json 2>/dev/null || echo '[]')"
if [[ -z "$ALL_JSON" ]]; then
    ALL_JSON='[]'
fi

JQ_FILTER='
def pillar_of(t):
  (t | ascii_upcase) as $u
  | if ($u | startswith("EFFECTIVE:")) then "EFFECTIVE"
    elif ($u | startswith("CREDIBLE:")) then "CREDIBLE"
    elif ($u | startswith("RESILIENT:")) then "RESILIENT"
    elif ($u | startswith("ZERO-WASTE:")) then "ZERO-WASTE"
    else null end;

def ac_vague:
  (. // "") as $raw
  | ($raw | fromjson?) as $parsed
  | if ($parsed == null) then true
    elif (($parsed | type) == "array" and ($parsed | length) == 0) then true
    elif (($parsed | type) == "array") then
      ($parsed | all(
          (if type == "string" then . else tostring end
           | ascii_upcase
           | gsub("^\\s+|\\s+$"; "")) as $t
          | ($t == "" or $t == "TODO" or $t == "TBD" or $t == "TBC" or $t == "N/A"
             or ($t | startswith("TODO")) or ($t | startswith("TBD")))
        ))
    else false end;

def deps_blocked($statusmap):
  (. // "") as $raw
  | ($raw | fromjson? // []) as $deps
  | ($deps | type) == "array" and ($deps | length) > 0
    and ([ $deps[] | ($statusmap[.] // "MISSING") ] | any(. != "done"));

. as $all
| (reduce $all[] as $g ({}; . + {($g.id): $g.status})) as $statusmap
| [ $all[] | select(.status == "open")
    | . + {pillar: pillar_of(.title)}
    | select(.pillar != null) ] as $tagged
| [ $tagged[] | select(
      (.priority == "P0" or .priority == "P1")
      and (.effort == "xs" or .effort == "s" or .effort == "m")
      and ((.acceptance_criteria | ac_vague) | not)
      and ((.depends_on | deps_blocked($statusmap)) | not)
    ) ] as $pickable
| {
    total: ($pickable | length),
    pillars: (["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]
      | map(. as $p | {pillar: $p, count: ([$pickable[] | select(.pillar == $p)] | length)}))
  }
'

SUMMARY="$(echo "$ALL_JSON" | jq -c "$JQ_FILTER" 2>/dev/null || echo '{"total":0,"pillars":[]}')"
TOTAL="$(echo "$SUMMARY" | jq -r '.total')"
TOTAL="${TOTAL:-0}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ALERTS_FIRED=0
ALERT_LINES=""

while IFS=$'\t' read -r PILLAR COUNT; do
    [[ -z "$PILLAR" ]] && continue

    if [[ "$COUNT" -lt "$FLOOR" ]]; then
        ALERTS_FIRED=1
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":%d}\n' \
            "$TS" "$PILLAR" "$COUNT" "$FLOOR" >> "$AMBIENT"
        ALERT_LINES="${ALERT_LINES}STARVED: $PILLAR has $COUNT pickable (floor=$FLOOR)"$'\n'
    fi

    if [[ "$TOTAL" -gt 0 ]]; then
        PCT=$(( COUNT * 100 / TOTAL ))
        if [[ "$PCT" -gt 50 ]]; then
            ALERTS_FIRED=1
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$TS" "$PILLAR" "$COUNT" "$PCT" >> "$AMBIENT"
            ALERT_LINES="${ALERT_LINES}OVERWEIGHT: $PILLAR has $COUNT/$TOTAL pickable (${PCT}%)"$'\n'
        fi
    fi
done < <(echo "$SUMMARY" | jq -r '.pillars[] | "\(.pillar)\t\(.count)"')

if [[ "$WANT_JSON" -eq 1 ]]; then
    echo "$SUMMARY" | jq -c --argjson fired "$ALERTS_FIRED" '. + {alerts_fired: ($fired == 1)}'
else
    echo "=== pillar-balance-check (INFRA-902) ==="
    echo "Total pickable pool: $TOTAL"
    echo "$SUMMARY" | jq -r '.pillars[] | "  \(.pillar): \(.count) pickable"'
    if [[ -n "$ALERT_LINES" ]]; then
        echo
        printf '%s' "$ALERT_LINES"
    fi
fi

if [[ "$ALERTS_FIRED" -eq 1 ]]; then
    exit 1
fi
exit 0
