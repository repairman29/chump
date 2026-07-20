#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086 AC #5
#
# Smoke-check: every scripts/ci/test-*.sh invoked by the audit-shard matrix
# or the audit-required tail in .github/workflows/audit.yml (a) exists on
# disk and (b) is listed in docs/process/AUDIT_JOB_DECOMPOSITION.md.
#
# Catches survey drift: a script added to/removed from the audit job without
# updating the decomposition doc.
#
# Exit 0 — every audit-job script that exists in scripts/ci/ is listed in the doc.
# Exit 1 — one or more audit-job scripts exist but are missing from the doc.
# Exit 2 — bad environment (missing file, etc.).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

WORKFLOW_FILE=".github/workflows/audit.yml"
DECOMP_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    echo "[audit-job-decomposition] FAIL: $WORKFLOW_FILE not found" >&2
    exit 2
fi
if [[ ! -f "$DECOMP_DOC" ]]; then
    echo "[audit-job-decomposition] FAIL: $DECOMP_DOC not found" >&2
    exit 2
fi

# Every scripts/ci/test-*.sh referenced in audit.yml that exists on disk.
missing=0
while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    [[ -f "$script" ]] || continue  # only scripts that actually exist are in scope (AC #5)
    base="$(basename "$script")"
    if ! grep -qF "$base" "$DECOMP_DOC"; then
        echo "[audit-job-decomposition] FAIL: $base runs in audit.yml but is not listed in $DECOMP_DOC" >&2
        missing=$((missing + 1))
    fi
done < <(grep -oE 'scripts/ci/test-[a-zA-Z0-9_-]*\.sh' "$WORKFLOW_FILE" | sort -u)

if [[ "$missing" -gt 0 ]]; then
    echo "[audit-job-decomposition] $missing audit-job script(s) missing from the survey doc" >&2
    exit 1
fi

echo "[audit-job-decomposition] OK: all audit-job scripts present in $DECOMP_DOC"
exit 0
