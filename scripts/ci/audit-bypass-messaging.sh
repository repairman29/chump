#!/usr/bin/env bash
# audit-bypass-messaging.sh — INFRA-4537 (INFRA-1861 slice)
#
# CI/QA AC (INFRA-1861): "every check that produces FAIL must have a 'how to
# bypass cleanly' line in its output." This script is the enforcement job:
# it scans the log of every job that FAILED in the current workflow run and
# asserts each one contains a line starting with "How to bypass cleanly:".
#
# Rationale: a failing check that doesn't tell the operator/agent how to
# bypass it (or that it can't be bypassed) forces spelunking through docs —
# exactly the "cause not immediately legible" pain INFRA-1861 calls out.
#
# Usage:
#   audit-bypass-messaging.sh --run-id <id> [--repo owner/name]
#
# Exit codes: 0 = every failed job's log has the bypass line (or no job
#             failed); 1 = at least one failed job's log is missing it;
#             2 = invocation/lookup error.
#
# Requires: gh CLI authenticated (GH_TOKEN in CI).

set -euo pipefail

RUN_ID="${GITHUB_RUN_ID:-}"
REPO="${GH_REPO:-}"

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        --repo)   REPO="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[audit-bypass-messaging] unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$RUN_ID" ]]; then
    echo "[audit-bypass-messaging] ERROR: --run-id (or \$GITHUB_RUN_ID) is required" >&2
    exit 2
fi

REPO_ARGS=()
[[ -n "$REPO" ]] && REPO_ARGS=(--repo "$REPO")

jobs_json="$(gh run view "$RUN_ID" "${REPO_ARGS[@]}" --json jobs 2>&1)" || {
    echo "[audit-bypass-messaging] ERROR: failed to fetch run $RUN_ID: $jobs_json" >&2
    exit 2
}

# Own job (this check itself) is still "in_progress" while we run — exclude it
# by name so we don't try to fetch our own not-yet-written log.
self_name="${GITHUB_JOB:-audit-bypass-messaging}"

mapfile -t failed_jobs < <(printf '%s' "$jobs_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
self_name = sys.argv[1]
for j in data.get("jobs", []):
    if j.get("conclusion") == "failure" and j.get("name") != self_name:
        print(str(j["databaseId"]) + "\t" + j["name"])
' "$self_name")

if [[ ${#failed_jobs[@]} -eq 0 ]]; then
    echo "[audit-bypass-messaging] no failed jobs in run $RUN_ID — nothing to audit. PASS"
    exit 0
fi

missing=0
for line in "${failed_jobs[@]}"; do
    job_id="${line%%$'\t'*}"
    job_name="${line#*$'\t'}"

    log="$(gh run view "$RUN_ID" "${REPO_ARGS[@]}" --job "$job_id" --log 2>&1)" || {
        echo "[audit-bypass-messaging] WARN: could not fetch log for job '$job_name' ($job_id) — treating as missing" >&2
        log=""
    }

    if printf '%s\n' "$log" | grep -qE '(^|	)How to bypass cleanly:'; then
        echo "[audit-bypass-messaging] OK: '$job_name' includes a bypass line"
    else
        echo "[audit-bypass-messaging] FAIL: '$job_name' failed but its output has no 'How to bypass cleanly:' line"
        missing=$((missing + 1))
    fi
done

if [[ "$missing" -gt 0 ]]; then
    echo "[audit-bypass-messaging] $missing failing job(s) missing a bypass line. FAIL"
    exit 1
fi

echo "[audit-bypass-messaging] all failing jobs include a bypass line. PASS"
exit 0
