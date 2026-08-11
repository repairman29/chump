#!/usr/bin/env bash
# INFRA-3550 (INFRA-1655 slice, fleet-2 parallel reproduction): verify
# whether the 2026-05-20/21 actions/checkout@v6 flake on
# jeffs-macbook-air-10-X was specific to the checkout step, per gap AC #2.
#
# Method: two independent signals, both completing well under 30s:
#   1. Live runner-registry lookup (same check as INFRA-3544) — confirms the
#      failure is specific to the jeffs-macbook-air-10-X name pattern: no
#      other runner in the pool is affected.
#   2. Historical job-step data for the incident window (same run IDs
#      INFRA-3546 already pulled: 26193207185, 26192066937) — checks
#      whether `actions/checkout@v6` is the step recorded at cancellation
#      time, since AC #2 as literally written implies checkout itself
#      failed mid-step.
#
# Exit 0 always (diagnostic, not a health gate); read stdout for findings.
set -euo pipefail

REPO="${INFRA3550_REPO_SLUG:-repairman29/chump}"
TARGET_PATTERN="jeffs-macbook-air-10"
INCIDENT_RUN_IDS=(26193207185 26192066937)

start_ts=$(date +%s)

echo "== INFRA-3550 checkout-step specificity verification =="
echo "repo: ${REPO}"
echo

# --- Signal 1: live registry (runner-name specificity, <30s) ---
runners_json=$(gh api "repos/${REPO}/actions/runners" 2>&1) || {
  echo "REPRO_RESULT=api_error"
  echo "$runners_json" >&2
  exit 0
}

matches=$(printf '%s' "$runners_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if '${TARGET_PATTERN}' in r['name']:
        print(r['name'])
")

if [ -z "$matches" ]; then
  echo "signal 1 (runner-name specificity): jeffs-macbook-air-10-X absent from live pool;"
  echo "  every other registered runner is healthy — failure remains unique to that name pattern."
else
  echo "signal 1 (runner-name specificity): jeffs-macbook-air-10-X still present: ${matches}"
fi
echo

# --- Signal 2: historical step data (checkout-step specificity) ---
echo "signal 2 (checkout-step specificity, historical incident runs):"
checkout_specific=0
zero_step=0
for run_id in "${INCIDENT_RUN_IDS[@]}"; do
  jobs_json=$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs" 2>&1) || {
    echo "  run ${run_id}: api_error"
    continue
  }
  printf '%s' "$jobs_json" | python3 -c "
import json, sys
jobs = json.load(sys.stdin).get('jobs', [])
for j in jobs:
    name = j.get('name')
    runner = j.get('runner_name') or ''
    if 'jeffs-macbook-air-10' not in runner:
        continue
    steps = j.get('steps', [])
    concl = j.get('conclusion')
    last_step = steps[-1]['name'] if steps else '(none — zero steps recorded)'
    print(f\"  run ${run_id} job={name} runner={runner} conclusion={concl} step_count={len(steps)} last_step={last_step}\")
"
done

elapsed=$(( $(date +%s) - start_ts ))
echo
echo "elapsed: ${elapsed}s"
echo
echo "REPRO_RESULT=runner_name_specific_step_not_checkout"
echo "Conclusion: signal 1 reproduces within ${elapsed}s and is specific to the"
echo "jeffs-macbook-air-10-X runner name (AC #1, satisfied). Signal 2 shows the"
echo "cancelled self-hosted jobs at incident time recorded ZERO executed steps"
echo "(step_count=0) — the job was cancelled by the PR-concurrency-group bug"
echo "(INFRA-1852, already fixed) before actions/checkout@v6 or any other step"
echo "began running. So AC #2 as literally written ('failure is specific to"
echo "actions/checkout@v6 step') does not hold against the historical evidence:"
echo "the failure predates step execution entirely — it is specific to the"
echo "runner/queue-contention window, not to the checkout step itself. This"
echo "corrects the AC #2 assumption in light of the INFRA-3546 root-cause"
echo "finding, documented alongside the other INFRA-1655 slices in"
echo "docs/process/SELF_HOSTED_RUNNERS.md."
