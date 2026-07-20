#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086
#
# Smoke-check: docs/process/AUDIT_JOB_DECOMPOSITION.md lists every
# scripts/ci/test-*.sh script invoked by the ci.yml fast-checks job (the
# current successor of the historically-named "audit" job — see the doc's
# scope note) that actually exists in scripts/ci/.
#
# Exit 0 — every audit-job script that exists on disk is listed in the survey doc.
# Exit 1 — one or more audit-job scripts are missing from the survey doc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"
SURVEY_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [[ ! -f "$CI_YML" ]]; then
    echo "[audit-job-decomposition] FAIL: $CI_YML not found" >&2
    exit 1
fi
if [[ ! -f "$SURVEY_DOC" ]]; then
    echo "[audit-job-decomposition] FAIL: $SURVEY_DOC not found" >&2
    exit 1
fi

# Isolate the fast-checks job block (from its header to the next top-level job).
JOB_BLOCK="$(awk '/^  fast-checks:$/{flag=1} flag && /^  [a-zA-Z0-9_-]+:$/ && !/^  fast-checks:$/{if(flag && NR>1){exit}} flag{print}' "$CI_YML")"

if [[ -z "$JOB_BLOCK" ]]; then
    echo "[audit-job-decomposition] FAIL: could not isolate fast-checks job block from $CI_YML" >&2
    exit 1
fi

MISSING=0
CHECKED=0
while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    # Only check scripts that actually exist on disk (scope per AC 5).
    if [[ ! -f "scripts/ci/$script" ]]; then
        continue
    fi
    CHECKED=$((CHECKED + 1))
    if ! grep -qF "\`$script\`" "$SURVEY_DOC"; then
        echo "[audit-job-decomposition] MISSING from survey doc: $script" >&2
        MISSING=$((MISSING + 1))
    fi
done < <(echo "$JOB_BLOCK" | grep -oE 'test-[a-zA-Z0-9_-]+\.sh' | sort -u)

echo "[audit-job-decomposition] checked $CHECKED on-disk audit-job scripts against $SURVEY_DOC"

if [[ "$MISSING" -gt 0 ]]; then
    echo "[audit-job-decomposition] FAIL: $MISSING script(s) missing from survey doc" >&2
    exit 1
fi

echo "[audit-job-decomposition] PASS: all $CHECKED audit-job scripts are listed in $SURVEY_DOC"
exit 0
