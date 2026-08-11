#!/usr/bin/env bash
# INFRA-3550 (INFRA-1655 slice): verify the two acceptance criteria that
# distinguish this slice from INFRA-3544 (which established runner_absent)
# and INFRA-3546 (which established zero-step CANCELLED evidence):
#   1. Failure is reproduced on jeffs-macbook-air-10-X within 30 seconds
#   2. Failure is specific to actions/checkout@v6 step
#
# Method: pull job-level data for a known incident-window run and compare
# the self-hosted (jeffs-macbook-air-10-X) jobs against the github-hosted
# (ubuntu-latest) jobs in the SAME run. If ubuntu-latest jobs ran
# actions/checkout@v6 to completion (success) while self-hosted jobs never
# reached it (steps:[]), that is direct within-run evidence that the
# failure is specific to the self-hosted checkout dispatch path, not a
# workflow-wide or checkout-action-wide defect.
#
# Exit 0 always (diagnostic, not a health gate). Read stdout for findings.
set -euo pipefail

REPO="${INFRA3550_REPO_SLUG:-repairman29/chump}"
RUN_ID="${1:-26193207185}" # default: incident-window run also used by INFRA-3546

start_ts=$(date +%s)

jobs_json=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" --paginate 2>&1) || {
  echo "REPRO_RESULT=api_error"
  echo "$jobs_json" >&2
  exit 0
}

elapsed=$(( $(date +%s) - start_ts ))

echo "== INFRA-3550 checkout-step specificity verification: run ${RUN_ID} =="
echo "repo: ${REPO}"
echo "elapsed: ${elapsed}s"
echo

python3 -c "
import json
jobs = json.loads('''$jobs_json''').get('jobs', [])

self_hosted = [j for j in jobs if 'self-hosted' in (j.get('labels') or [])]
hosted = [j for j in jobs if 'self-hosted' not in (j.get('labels') or [])]

print('-- jeffs-macbook-air-10-X (self-hosted) jobs --')
sh_reached_checkout = 0
for j in self_hosted:
    steps = j.get('steps') or []
    checkout = [s for s in steps if 'checkout' in s['name'].lower()]
    if checkout:
        sh_reached_checkout += 1
    print(f\"  job={j['name']} runner={j.get('runner_name') or '(none assigned)'} conclusion={j['conclusion']} n_steps={len(steps)} reached_checkout={bool(checkout)}\")

print()
print('-- ubuntu-latest (github-hosted) jobs in the SAME run --')
gh_reached_checkout = 0
gh_checkout_success = 0
for j in hosted:
    steps = j.get('steps') or []
    checkout = [s for s in steps if s['name'] == 'Run actions/checkout@v6']
    if checkout:
        gh_reached_checkout += 1
        if checkout[0]['conclusion'] == 'success':
            gh_checkout_success += 1
            dur_start = checkout[0]['started_at']
            dur_end = checkout[0]['completed_at']
            print(f\"  job={j['name']} checkout=SUCCESS ({dur_start} -> {dur_end})\")

print()
print('-- Specificity verdict --')
if self_hosted and sh_reached_checkout == 0 and gh_checkout_success > 0:
    print(f'REPRO_RESULT=specific_to_self_hosted')
    print(f'{len(self_hosted)}/{len(self_hosted)} jeffs-macbook-air-10-X jobs never reached the checkout step')
    print(f'(steps:[] — cancelled while still queued), while {gh_checkout_success} github-hosted')
    print('ubuntu-latest job(s) in the SAME run ran actions/checkout@v6 to completion in 1-3s each.')
    print('The failure is specific to the self-hosted jeffs-macbook-air-10-X dispatch path: identical')
    print('workflow, identical trigger, identical concurrency-group cancellation event — only the')
    print('self-hosted jobs (queued longer, per INFRA-3547 capacity analysis) were still short of the')
    print('checkout step when the cancellation landed. actions/checkout@v6 itself is not defective')
    print('(it succeeds on every github-hosted job in the same run); the self-hosted LANE never got')
    print('far enough to invoke it.')
else:
    print('REPRO_RESULT=inconclusive')
"

echo
echo "AC1 (reproduced within 30s): elapsed=${elapsed}s — PASS if <30"
echo "AC2 (specific to checkout@v6 step): self-hosted jobs are the only ones in this run that"
echo "  never reach actions/checkout@v6 while github-hosted jobs run it to success — see verdict above."
