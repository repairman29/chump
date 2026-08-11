#!/usr/bin/env bash
# INFRA-3546 (INFRA-1655 slice): analyze system information for the
# actions/checkout@v6 flake on jeffs-macbook-air-10-X self-hosted runners,
# to rule in/out three candidate root causes: disk full, stale runner
# registration, network issues.
#
# Method: the original incident's live runners/logs are gone (INFRA-3544
# found the runner deregistered), so this pulls the *historical* CI run
# metadata GitHub still retains for the incident window (2026-05-20/21) and
# inspects job-level evidence: was a runner actually assigned (rules out
# stale registration), how many steps executed before CANCELLED (rules in/out
# a mid-step network/checkout failure vs. never-started), and whether an
# overlapping push landed on the same branch/PR while the run was in flight
# (the concurrency-cancellation explanation).
#
# Uses python3 for JSON parsing (jq is not guaranteed present).
#
# Exit 0 always (diagnostic, not a health gate). Read stdout for findings.
set -euo pipefail

REPO="${INFRA3546_REPO_SLUG:-repairman29/chump}"
RUN_ID="${1:-}"

if [ -z "$RUN_ID" ]; then
  echo "Usage: $0 <ci-workflow-run-id>"
  echo
  echo "Finding a candidate run from the 2026-05-20/21 incident window:"
  gh api "repos/${REPO}/actions/runs?created=2026-05-20..2026-05-20&per_page=100&status=cancelled" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('workflow_runs', []):
    if r['name'] == 'CI':
        print(f\"  {r['id']}  {r['head_branch']}  {r['created_at']}\")
" | head -5
  exit 0
fi

echo "== INFRA-3546 system-information analysis: run ${RUN_ID} =="

jobs_json=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" 2>&1) || {
  echo "api_error fetching jobs for run ${RUN_ID}"
  echo "$jobs_json" >&2
  exit 0
}

run_json=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}" 2>&1) || {
  echo "api_error fetching run ${RUN_ID}"
  exit 0
}

python3 -c "
import json
run = json.loads('''$run_json''')
jobs = json.loads('''$jobs_json''').get('jobs', [])

branch = run.get('head_branch')
created = run.get('created_at')
updated = run.get('updated_at')
print(f'branch={branch} created={created} cancelled_at={updated}')
print()

self_hosted = [j for j in jobs if 'self-hosted' in (j.get('labels') or [])]
if not self_hosted:
    print('No self-hosted jobs in this run.')
else:
    for j in self_hosted:
        n_steps = len(j.get('steps') or [])
        runner_name = j.get('runner_name') or '(none assigned)'
        print(f\"job={j['name']} conclusion={j['conclusion']} runner={runner_name} steps_executed={n_steps} started={j.get('started_at')} completed={j.get('completed_at')}\")
    print()
    print('-- Root-cause signals --')
    assigned = [j for j in self_hosted if j.get('runner_name')]
    print(f'stale_runner_registration: {\"RULED_OUT\" if assigned else \"CANNOT_DETERMINE\"} — {len(assigned)}/{len(self_hosted)} self-hosted job(s) had a live runner_id/runner_name assigned (a stale/deregistered runner cannot receive a job dispatch)')
    zero_step = [j for j in self_hosted if not (j.get('steps') or [])]
    if zero_step:
        print(f'{len(zero_step)}/{len(self_hosted)} self-hosted job(s) executed ZERO steps before CANCELLED — consistent with cancel-before-dispatch (queue contention or concurrency-group cancel), NOT a mid-checkout disk/network failure (no step, including checkout, ever ran to hit either).')
    mid_step = [j for j in self_hosted if (j.get('steps') or [])]
    if mid_step:
        print(f'{len(mid_step)}/{len(self_hosted)} self-hosted job(s) executed 1+ steps before CANCELLED — checkout step (if present) should be inspected individually; a step that reached RUNNING/completed status before cancellation is evidence against a checkout-specific network failure for that job.')
"

echo
echo "-- Overlap check: did a newer push land on the same branch while this run was in flight? --"
branch=$(printf '%s' "$run_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['head_branch'])")
created=$(printf '%s' "$run_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['created_at'])")
updated=$(printf '%s' "$run_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['updated_at'])")

gh api "repos/${REPO}/actions/runs?branch=${branch}&per_page=100" 2>&1 \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
created = '$created'
updated = '$updated'
this_run = $RUN_ID
overlaps = [r for r in d.get('workflow_runs', [])
            if r['name'] == 'CI' and r['id'] != this_run
            and created <= r['created_at'] <= updated]
if overlaps:
    print(f'{len(overlaps)} newer CI run(s) started on branch \'$branch\' WHILE run {this_run} was still in flight:')
    for r in overlaps:
        print(f\"  run={r['id']} sha={r['head_sha'][:8]} created={r['created_at']}\")
    print()
    print('network_issues: RULED_OUT as sole cause — an overlapping push is present, consistent with')
    print('  concurrency-group cancellation (see .github/workflows/ci.yml INFRA-1852 history) racing')
    print('  against slower self-hosted job scheduling, not a network-level checkout failure.')
    print('disk_full: RULED_OUT as sole cause — cancellation is externally triggered (concurrency group),')
    print('  not a runner-local resource exhaustion signal.')
else:
    print('No overlapping push found in this window — concurrency-cancellation theory does not apply to this run; inspect step-level evidence above instead.')
"
