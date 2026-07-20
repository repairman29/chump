#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086
#
# Smoke: asserts docs/process/AUDIT_JOB_DECOMPOSITION.md's inventory table
# lists every `scripts/ci/test-*.sh` invoked by the `audit`/`audit-shard` job
# in .github/workflows/audit.yml (moved out of ci.yml by INFRA-2452, still
# called "the audit job" per INFRA-1856/META-070 doctrine). Catches survey
# drift when a new test script is added to the audit job without updating
# the survey.
#
# Exit codes:
#   0 = every audit-job script that exists in scripts/ci/ is listed in the survey
#   1 = at least one audit-job script is missing from the survey; scripts listed
#   2 = bad environment (missing file)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

AUDIT_YML=".github/workflows/audit.yml"
SURVEY_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

for f in "$AUDIT_YML" "$SURVEY_DOC"; do
    if [[ ! -f "$f" ]]; then
        echo "[audit-job-decomposition] ERROR: missing $f" >&2
        exit 2
    fi
done

job_body="$(cat "$AUDIT_YML")"

audit_scripts=()
while IFS= read -r line; do
    [[ -n "$line" ]] && audit_scripts+=("$line")
done < <(grep -oE 'scripts/ci/test-[a-zA-Z0-9_-]+\.sh' <<<"$job_body" | sed 's#scripts/ci/##' | sort -u)

if [[ "${#audit_scripts[@]}" -eq 0 ]]; then
    echo "[audit-job-decomposition] ERROR: found zero test-*.sh scripts in pr-hygiene job — parser likely broken" >&2
    exit 2
fi

missing=()
for script in "${audit_scripts[@]}"; do
    # Only scripts that still exist on disk are in scope — a script the
    # audit job invokes but that was deleted is a separate (CI-red) problem.
    if [[ -f "scripts/ci/$script" ]] && ! grep -qF "\`$script\`" "$SURVEY_DOC"; then
        missing+=("$script")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "[audit-job-decomposition] FAIL: ${#missing[@]} audit-job script(s) missing from $SURVEY_DOC:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "[audit-job-decomposition] Update the survey's inventory table (and re-cluster if needed)." >&2
    exit 1
fi

echo "[audit-job-decomposition] OK: all ${#audit_scripts[@]} audit-job scripts are listed in $SURVEY_DOC"
exit 0
