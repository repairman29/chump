#!/usr/bin/env bash
# friction-metric.sh (MISSION-044 AC5) — READ-ONLY friction trend surface.
# Cut-the-Friction umbrella needs a visible trend for attempts-per-ship /
# turns-to-first-ship; this is the first cut. No state mutation beyond
# appending one line to a local, non-canonical history file so repeated runs
# build a trend (mirrors mission-scoreboard.sh's read-only posture).
#
# Metric definitions (proxies — see docs/gaps/MISSION-044.yaml for the
# language "attempts-per-ship or turns-to-first-ship"):
#   attempts-per-ship   = mean commit count per merged PR in the window.
#                          Each additional commit on a PR branch after the
#                          first is a retry/fixup — i.e. friction.
#   turns-to-first-ship = mean hours from PR-open to PR-merge in the window.
#                          A proxy for how many round-trips a change needed
#                          before it landed.
#
# Usage:
#   scripts/dev/friction-metric.sh [--window 7d] [--json] [--no-history]
#
# Exit codes: 0 always (this is an observability surface, not a gate).
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" 2>/dev/null || true

WINDOW="7d"
JSON=0
NO_HISTORY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window)      WINDOW="$2"; shift 2 ;;
        --json)        JSON=1; shift ;;
        --no-history)  NO_HISTORY=1; shift ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0 ;;
        *) echo "[friction-metric] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# window like "7d" -> gh search "merged:>=YYYY-MM-DD"
win_days="${WINDOW%d}"
if ! [[ "$win_days" =~ ^[0-9]+$ ]]; then
    echo "[friction-metric] --window must look like '7d' (got '$WINDOW')" >&2
    exit 2
fi
since="$(date -u -v-"${win_days}"d +%Y-%m-%d 2>/dev/null || date -u -d "${win_days} days ago" +%Y-%m-%d 2>/dev/null)"

REPO="${FRICTION_METRIC_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo '')}"
SAMPLE_CAP="${FRICTION_METRIC_SAMPLE_CAP:-15}"

pr_list_json="[]"
if command -v gh >/dev/null 2>&1 && [[ -n "$REPO" ]]; then
    # commits connection is too expensive to request in bulk (GraphQL node-limit
    # error above ~a few hundred PRs) — fetch the cheap fields in bulk, then
    # per-PR commit counts below, capped at SAMPLE_CAP to bound API usage.
    pr_list_json=$(gh pr list -R "$REPO" --state merged --search "merged:>=$since" \
        --json number,createdAt,mergedAt --limit 200 2>/dev/null || echo "[]")
    [[ -z "$pr_list_json" ]] && pr_list_json="[]"
fi

pr_numbers=$(echo "$pr_list_json" | python3 -c "
import json, sys
try:
    prs = json.load(sys.stdin)
except Exception:
    prs = []
for pr in prs[:$SAMPLE_CAP]:
    print(pr.get('number'))
" 2>/dev/null)

commits_by_pr=""
if [[ -n "$pr_numbers" ]]; then
    for _n in $pr_numbers; do
        _c=$(gh pr view "$_n" -R "$REPO" --json commits --jq '.commits | length' 2>/dev/null || echo "")
        [[ -n "$_c" ]] && commits_by_pr+="${_n}:${_c} "
    done
fi

read -r ship_count total_commits total_hours <<EOF
$(python3 - "$pr_list_json" "$commits_by_pr" "$SAMPLE_CAP" <<'PY'
import json, sys
from datetime import datetime, timezone

try:
    prs = json.loads(sys.argv[1])
except Exception:
    prs = []
commits_raw = sys.argv[2].split()
cap = int(sys.argv[3])
commits_by_pr = {}
for tok in commits_raw:
    n, c = tok.split(":")
    commits_by_pr[int(n)] = int(c)

def parse(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

count = 0
total_commits = 0
total_hours = 0.0
for pr in prs[:cap]:
    n = commits_by_pr.get(pr.get("number"), 1)
    total_commits += n
    try:
        opened = parse(pr["createdAt"])
        merged = parse(pr["mergedAt"])
        total_hours += (merged - opened).total_seconds() / 3600.0
    except Exception:
        pass
    count += 1

print(f"{count} {total_commits} {total_hours:.2f}")
PY
)
EOF

if [[ "$ship_count" -gt 0 ]]; then
    attempts_per_ship=$(python3 -c "print(f'{${total_commits}/${ship_count}:.2f}')")
    turns_to_first_ship_h=$(python3 -c "print(f'{${total_hours}/${ship_count}:.2f}')")
else
    attempts_per_ship="n/a"
    turns_to_first_ship_h="n/a"
fi

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "$JSON" -eq 1 ]]; then
    printf '{"ts":"%s","window":"%s","repo":"%s","ships":%s,"attempts_per_ship":%s,"turns_to_first_ship_hours":%s}\n' \
        "$now_iso" "$WINDOW" "$REPO" "$ship_count" \
        "${attempts_per_ship/n\/a/null}" "${turns_to_first_ship_h/n\/a/null}"
else
    echo "═══ FRICTION METRIC (MISSION-044) ═══  $now_iso"
    echo "repo=$REPO  window=$WINDOW (merged>=$since)"
    echo
    echo "  ships in window:            $ship_count"
    echo "  attempts-per-ship:          $attempts_per_ship   (mean commits/PR — retries+fixups)"
    echo "  turns-to-first-ship (hrs):  $turns_to_first_ship_h   (mean PR open→merge)"
    echo
    echo "(read-only; trend history in .chump/metrics/friction-metric-history.jsonl)"
fi

if [[ "$NO_HISTORY" -eq 0 ]]; then
    mkdir -p .chump/metrics 2>/dev/null || true
    printf '{"ts":"%s","window":"%s","repo":"%s","ships":%s,"attempts_per_ship":%s,"turns_to_first_ship_hours":%s}\n' \
        "$now_iso" "$WINDOW" "$REPO" "$ship_count" \
        "${attempts_per_ship/n\/a/null}" "${turns_to_first_ship_h/n\/a/null}" \
        >> .chump/metrics/friction-metric-history.jsonl 2>/dev/null || true
fi

exit 0
