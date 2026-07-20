#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086 AC #5
#
# Smoke-check: docs/process/AUDIT_JOB_DECOMPOSITION.md's survey table lists
# every scripts/ci/test-*.sh that .github/workflows/ci.yml's `fast-checks`
# ("audit") job actually invokes. Prevents the survey from silently going
# stale as new gates are added to the job without updating the doc.
#
# Exit 0 — every audit-job test script appears in the survey doc.
# Exit 1 — one or more audit-job test scripts are missing from the survey doc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"
SURVEY_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

for f in "$CI_YML" "$SURVEY_DOC"; do
    if [[ ! -f "$f" ]]; then
        echo "[audit-job-decomposition] FAIL: required file missing: $f" >&2
        exit 1
    fi
done

# Extract the fast-checks job body (from "  fast-checks:" to the next
# top-level job key), then pull every `scripts/ci/test-*.sh` reference in it.
# (Uses a while-read loop rather than `mapfile` for bash-3.2 portability —
# macOS ships bash 3.2 by default.)
ci_scripts=()
while IFS= read -r line; do
    [[ -n "$line" ]] && ci_scripts+=("$line")
done < <(
    awk '/^  fast-checks:$/{flag=1} flag && /^  [a-zA-Z_-]+:$/ && !/^  fast-checks:$/{flag=0} flag' "$CI_YML" \
    | grep -oE 'scripts/ci/test-[a-zA-Z0-9_-]+\.sh' \
    | sed 's#scripts/ci/##' \
    | sort -u
)

if [[ ${#ci_scripts[@]} -eq 0 ]]; then
    echo "[audit-job-decomposition] FAIL: no scripts/ci/test-*.sh found in fast-checks job — parsing broke" >&2
    exit 1
fi

missing=()
for script in "${ci_scripts[@]}"; do
    if ! grep -qF "\`$script\`" "$SURVEY_DOC"; then
        missing+=("$script")
    fi
done

echo "[audit-job-decomposition] fast-checks job invokes ${#ci_scripts[@]} test scripts"

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[audit-job-decomposition] FAIL: ${#missing[@]} script(s) missing from $SURVEY_DOC:" >&2
    for m in "${missing[@]}"; do
        echo "  - $m" >&2
    done
    exit 1
fi

echo "[audit-job-decomposition] OK: all ${#ci_scripts[@]} audit-job test scripts are listed in $SURVEY_DOC"
exit 0
