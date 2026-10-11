#!/usr/bin/env bash
# rerun-verified-on-lane-complete.sh — RESILIENT-1562
#
# Re-run the `verified` job of the ci.yml run for --sha when it has already
# completed non-green (it timed out PENDING on audit/ACP). Called from
# verified-recompute.yml on workflow_run completion of audit/integrations.
# No-op when ci.yml is still running (verified's own poll will observe the
# terminal state) or verified already succeeded.
#
# Usage: rerun-verified-on-lane-complete.sh --sha SHA [--dry-run]
set -euo pipefail
SHA=""; DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha) SHA="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 3 ;;
    esac
done
[[ -n "$SHA" ]] || { echo "--sha required" >&2; exit 3; }

run="$(gh run list --workflow ci.yml --commit "$SHA" --json databaseId,status -L 1 -q '.[0]' 2>/dev/null || true)"
if [[ -z "$run" || "$run" == "null" ]]; then
    echo "[rerun-verified] no ci.yml run for $SHA; nothing to do"; exit 0
fi
run_id="$(jq -r '.databaseId' <<<"$run")"
if [[ "$(jq -r '.status' <<<"$run")" != "completed" ]]; then
    echo "[rerun-verified] ci run $run_id still active; verified will observe terminal state itself"; exit 0
fi
job="$(gh api "repos/${GH_REPO}/actions/runs/${run_id}/jobs" --paginate -q '.jobs[] | select(.name=="verified") | "\(.id) \(.conclusion)"' | tail -1)"
job_id="${job%% *}"; concl="${job##* }"
if [[ -z "$job_id" || "$concl" == "success" ]]; then
    echo "[rerun-verified] verified absent or already green; nothing to do"; exit 0
fi
echo "[rerun-verified] re-running verified job $job_id (was $concl) in run $run_id"
[[ "$DRY" -eq 1 ]] && exit 0
gh run rerun "$run_id" --job "$job_id"
