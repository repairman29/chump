#!/usr/bin/env bash
# test-audit-job-decomposition.sh — META-086
# Asserts docs/process/AUDIT_JOB_DECOMPOSITION.md enumerates every
# scripts/ci/test-*.sh invoked by the ci.yml `fast-checks` (audit) job,
# and that every script it lists actually exists in scripts/ci/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"
SURVEY_DOC="docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [[ ! -f "$SURVEY_DOC" ]]; then
  echo "FAIL: $SURVEY_DOC does not exist" >&2
  exit 1
fi

# Extract the fast-checks job block: from its `  fast-checks:` header to the
# next top-level (2-space-indented) job key.
job_scripts=$(awk '
  /^  fast-checks:/ { in_job=1 }
  in_job && /^  [a-zA-Z_-]+:$/ && !/^  fast-checks:/ { in_job=0 }
  in_job { print }
' "$CI_YML" | grep -oE 'scripts/ci/test-[a-zA-Z0-9_-]+\.sh' | sort -u)

missing=0
while IFS= read -r script; do
  [[ -z "$script" ]] && continue
  if [[ ! -f "$script" ]]; then
    echo "FAIL: $script referenced by ci.yml fast-checks job but does not exist on disk" >&2
    missing=1
    continue
  fi
  if ! grep -qF "$script" "$SURVEY_DOC"; then
    echo "FAIL: $script is invoked by ci.yml fast-checks job but missing from $SURVEY_DOC" >&2
    missing=1
  fi
done <<< "$job_scripts"

if [[ "$missing" -ne 0 ]]; then
  echo "FAIL: audit-job survey doc is out of sync with ci.yml — see above" >&2
  exit 1
fi

count=$(echo "$job_scripts" | grep -c .)
echo "OK: all $count fast-checks (audit job) test scripts are listed in $SURVEY_DOC"
