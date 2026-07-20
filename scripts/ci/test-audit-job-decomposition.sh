#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086
#
# Smoke-check: docs/process/AUDIT_JOB_DECOMPOSITION.md enumerates every
# scripts/ci/test-*.sh script invoked by the `fast-checks` job in
# .github/workflows/ci.yml (the job historically called "audit" in fleet
# doctrine — see META-086 survey for the rename history).
#
# Exit 0 — every audit-job test script is listed in the survey doc.
# Exit 1 — one or more audit-job test scripts are missing from the survey doc.
# Exit 2 — bad environment (missing file, etc.).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"
SURVEY_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

for f in "$CI_YML" "$SURVEY_DOC"; do
    if [[ ! -f "$f" ]]; then
        echo "[audit-job-decomposition] FAIL: required file missing: $f" >&2
        exit 2
    fi
done

# Extract the fast-checks job body (from its header to the next top-level
# job key) and pull every scripts/ci/test-*.sh reference out of it.
job_scripts="$(awk '
    /^  fast-checks:$/ { in_job=1 }
    in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  fast-checks:$/ { in_job=0 }
    in_job { print }
' "$CI_YML" | grep -oE 'scripts/ci/test-[a-zA-Z0-9_-]+\.sh' | sed 's#scripts/ci/##' | sort -u)"

if [[ -z "$job_scripts" ]]; then
    echo "[audit-job-decomposition] FAIL: no scripts/ci/test-*.sh found in fast-checks job — parser likely broken" >&2
    exit 2
fi

missing=()
while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    if ! grep -qF "$script" "$SURVEY_DOC"; then
        missing+=("$script")
    fi
done <<< "$job_scripts"

total=$(echo "$job_scripts" | wc -l | tr -d ' ')

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[audit-job-decomposition] FAIL: ${#missing[@]}/${total} audit-job test script(s) missing from $SURVEY_DOC:" >&2
    for m in "${missing[@]}"; do
        echo "  - $m" >&2
    done
    exit 1
fi

echo "[audit-job-decomposition] PASS: all ${total} audit-job (fast-checks) test scripts are listed in $SURVEY_DOC"
exit 0
