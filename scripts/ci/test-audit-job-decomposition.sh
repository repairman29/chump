#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086
#
# Smoke-check: every scripts/ci/test-*.sh script actually invoked by the
# `fast-checks` job in .github/workflows/ci.yml (the "audit job") is listed
# in docs/process/AUDIT_JOB_DECOMPOSITION.md. Catches drift where a new
# audit-job step is added but the survey doc isn't updated.
#
# Exit 0 — every fast-checks test-*.sh script appears in the survey doc.
# Exit 1 — one or more scripts are missing from the survey doc.
# Exit 2 — bad environment (missing file, etc.).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"
SURVEY_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [[ ! -f "$CI_YML" ]]; then
    echo "[audit-job-decomposition] ERROR: $CI_YML not found" >&2
    exit 2
fi
if [[ ! -f "$SURVEY_DOC" ]]; then
    echo "[audit-job-decomposition] ERROR: $SURVEY_DOC not found" >&2
    exit 2
fi

# Extract the fast-checks job block: from the "  fast-checks:" line up to
# (but not including) the next top-level (2-space-indented) job key.
fast_checks_block="$(awk '
    /^  fast-checks:$/ { infast=1; print; next }
    infast && /^  [a-zA-Z0-9_-]+:$/ { exit }
    infast { print }
' "$CI_YML")"

scripts=()
while IFS= read -r s; do
    [[ -n "$s" ]] && scripts+=("$s")
done < <(printf '%s\n' "$fast_checks_block" \
    | grep -oE 'scripts/ci/test-[a-zA-Z0-9_-]+\.sh' \
    | sed -E 's#scripts/ci/##' \
    | sort -u)

if [[ "${#scripts[@]}" -eq 0 ]]; then
    echo "[audit-job-decomposition] ERROR: no test-*.sh scripts found in fast-checks job — parse bug?" >&2
    exit 2
fi

missing=()
for s in "${scripts[@]}"; do
    if ! grep -qF "$s" "$SURVEY_DOC"; then
        missing+=("$s")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "[audit-job-decomposition] FAIL: ${#missing[@]} fast-checks script(s) missing from $SURVEY_DOC:" >&2
    for s in "${missing[@]}"; do
        echo "  - $s" >&2
    done
    echo "[audit-job-decomposition] Update $SURVEY_DOC with the new script(s) and their cluster assignment." >&2
    exit 1
fi

echo "[audit-job-decomposition] PASS: all ${#scripts[@]} fast-checks test-*.sh scripts are listed in $SURVEY_DOC"
exit 0
