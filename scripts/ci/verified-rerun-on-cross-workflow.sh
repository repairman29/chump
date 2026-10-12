#!/usr/bin/env bash
# verified-rerun-on-cross-workflow.sh — RESILIENT-1562
# Event-driven recompute of ci.yml's `verified` job after audit / ACP complete.
# `verified` snapshots audit+ACP once (no wall-clock poll window); if they were
# still running it reports PENDING (red). This script, fired from
# verified-rerun.yml on workflow_run completion of Audit / integrations / CI,
# re-runs the failed jobs of the CI run for the SHA iff:
#   - the CI run is completed (GitHub only allows rerun then), and
#   - `verified` is not success, and
#   - audit and ACP check-runs are both terminal, and
#   - one of them completed AFTER `verified` did (so verified saw stale state).
# The last condition makes it loop-free: a rerun's verified completes later
# than the lanes, so a genuine failure is not re-run again.
# Usage: verified-rerun-on-cross-workflow.sh --sha SHA [--repo owner/repo] [--dry-run]
set -euo pipefail
REPO="${GH_REPO:-repairman29/chump}"; SHA=""; DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha) SHA="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 3 ;;
    esac
done
[[ -n "$SHA" ]] || { echo "--sha required" >&2; exit 3; }

runs="$(gh api "repos/${REPO}/commits/${SHA}/check-runs" --paginate -q '.check_runs' 2>/dev/null || echo '[]')"
verified="$(echo "$runs" | jq -c '[.[] | select(.name=="verified")] | sort_by(.started_at) | last // empty')"
if [[ -z "$verified" ]]; then echo "no verified check-run for $SHA; nothing to do"; exit 0; fi
v_status="$(echo "$verified" | jq -r '.status')"
v_concl="$(echo "$verified" | jq -r '.conclusion // ""')"
v_done="$(echo "$verified" | jq -r '.completed_at // ""')"
if [[ "$v_status" != "completed" || "$v_concl" == "success" ]]; then
    echo "verified status=$v_status conclusion=$v_concl; nothing to do"; exit 0
fi

latest_lane_done=""
for lane in "audit" "ACP protocol smoke test (Zed / JetBrains compatible)"; do
    e="$(echo "$runs" | jq -c --arg n "$lane" '[.[] | select(.name==$n)] | sort_by(.started_at) | last // empty')"
    if [[ -z "$e" || "$(echo "$e" | jq -r '.status')" != "completed" ]]; then
        echo "lane '$lane' not terminal yet; its own completion will re-trigger"; exit 0
    fi
    d="$(echo "$e" | jq -r '.completed_at')"
    [[ "$d" > "$latest_lane_done" ]] && latest_lane_done="$d"
done
if [[ ! "$latest_lane_done" > "$v_done" ]]; then
    echo "verified (done $v_done) already saw terminal lanes (latest $latest_lane_done); no rerun"; exit 0
fi

run_id="$(echo "$verified" | jq -r '.html_url' | sed -n 's#.*/runs/\([0-9]*\).*#\1#p')"
[[ -n "$run_id" ]] || { echo "cannot derive CI run id" >&2; exit 1; }
ci_status="$(gh api "repos/${REPO}/actions/runs/${run_id}" -q .status)"
if [[ "$ci_status" != "completed" ]]; then
    echo "CI run $run_id still $ci_status; CI completion will re-trigger"; exit 0
fi
echo "re-running failed jobs of CI run $run_id (verified stale vs audit/ACP)"
[[ "$DRY" -eq 1 ]] && exit 0
gh run rerun "$run_id" --failed --repo "$REPO"
