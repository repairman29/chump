#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086
#
# Smoke-check: every `bash scripts/ci/*.sh` invocation in ci.yml's
# `fast-checks` job (the "audit job") appears in the survey table in
# docs/process/AUDIT_JOB_DECOMPOSITION.md — catches silent drift between
# the job's actual script list and the decomposition survey.
#
# Exit 0 — every audit-job script is listed in the survey doc.
# Exit 1 — one or more scripts are invoked by the job but missing from the doc.
# Exit 2 — bad environment (missing file).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"
SURVEY_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [[ ! -f "$CI_YML" ]]; then
    echo "[audit-job-decomposition] FAIL: $CI_YML not found" >&2
    exit 2
fi
if [[ ! -f "$SURVEY_DOC" ]]; then
    echo "[audit-job-decomposition] FAIL: $SURVEY_DOC not found" >&2
    exit 2
fi

# Extract the fast-checks job block: from "  fast-checks:" to the next
# top-level (2-space-indented) "key:" line.
job_block="$(awk '
    /^  fast-checks:$/ { in_job=1; print; next }
    in_job && /^  [a-zA-Z_-]+:$/ { exit }
    in_job { print }
' "$CI_YML")"

if [[ -z "$job_block" ]]; then
    echo "[audit-job-decomposition] FAIL: could not locate fast-checks job block in $CI_YML" >&2
    exit 2
fi

scripts=()
while IFS= read -r line; do
    [[ -n "$line" ]] && scripts+=("$line")
done < <(printf '%s\n' "$job_block" | grep -oE 'scripts/ci/[a-zA-Z0-9_.-]+\.sh' | sort -u)

if [[ "${#scripts[@]}" -eq 0 ]]; then
    echo "[audit-job-decomposition] FAIL: found zero scripts/ci/*.sh invocations in fast-checks job" >&2
    exit 2
fi

missing=()
for s in "${scripts[@]}"; do
    if ! grep -qF "$s" "$SURVEY_DOC"; then
        missing+=("$s")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "[audit-job-decomposition] FAIL: ${#missing[@]} audit-job script(s) missing from $SURVEY_DOC:" >&2
    for m in "${missing[@]}"; do
        echo "  - $m" >&2
    done
    exit 1
fi

echo "[audit-job-decomposition] OK: all ${#scripts[@]} audit-job scripts are listed in $SURVEY_DOC"
exit 0
