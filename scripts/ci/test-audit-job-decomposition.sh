#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086
#
# Smoke test: docs/process/AUDIT_JOB_DECOMPOSITION.md must list every
# scripts/ci/test-*.sh invoked by the audit job (.github/workflows/audit.yml).
# Prevents the survey from silently going stale as new gates are added to
# the shard matrix.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

WORKFLOW=".github/workflows/audit.yml"
SURVEY="docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [[ ! -f "$WORKFLOW" ]]; then
    echo "FAIL: $WORKFLOW not found"
    exit 1
fi
if [[ ! -f "$SURVEY" ]]; then
    echo "FAIL: $SURVEY not found — run the META-086 survey"
    exit 1
fi

invoked=()
while IFS= read -r script; do
    invoked+=("$script")
done < <(grep -oE 'scripts/ci/test-[a-zA-Z0-9_-]+\.sh' "$WORKFLOW" | sort -u)

missing=()
for script in "${invoked[@]}"; do
    if ! grep -qF "$script" "$SURVEY"; then
        missing+=("$script")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "FAIL: ${#missing[@]} audit-job script(s) missing from $SURVEY:"
    printf '  %s\n' "${missing[@]}"
    echo "Update the survey (META-086) to keep it in sync with the audit job."
    exit 1
fi

echo "PASS: all ${#invoked[@]} audit-job test scripts are listed in $SURVEY"
