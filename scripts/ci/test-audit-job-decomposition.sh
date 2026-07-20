#!/usr/bin/env bash
# META-086: smoke test for docs/process/AUDIT_JOB_DECOMPOSITION.md.
#
# Asserts the survey doc lists every scripts/ci/*.sh invoked by the
# fast-checks job (the CI gate referred to as the "audit job" at INFRA-1856
# filing time) in .github/workflows/ci.yml. Catches silent drift — if a new
# test-*.sh is wired into the job without updating the survey doc, this
# fails fast instead of the doc quietly going stale (INFRA-1856's own
# failure mode: speculative AC that never matched reality).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
SURVEY_DOC="$REPO_ROOT/docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [ ! -f "$CI_YML" ]; then
  echo "FAIL: $CI_YML not found" >&2
  exit 1
fi
if [ ! -f "$SURVEY_DOC" ]; then
  echo "FAIL: $SURVEY_DOC not found" >&2
  exit 1
fi

# Extract the fast-checks job body (from its header to the next top-level
# job key) and pull every scripts/ci/*.sh reference inside it.
job_scripts="$(awk '
  /^  fast-checks:/ { in_job = 1 }
  in_job && /^  [a-zA-Z_-]+:$/ && !/^  fast-checks:/ { in_job = 0 }
  in_job { print }
' "$CI_YML" | grep -oE 'scripts/ci/[a-zA-Z0-9_-]+\.sh' | sort -u)"

if [ -z "$job_scripts" ]; then
  echo "FAIL: no scripts/ci/*.sh references found in fast-checks job — job may have been renamed again" >&2
  exit 1
fi

errors=0
missing=0
while IFS= read -r script_path; do
  base="$(basename "$script_path")"
  if ! grep -qF "\`$base\`" "$SURVEY_DOC"; then
    echo "FAIL: $base is invoked by fast-checks in ci.yml but not listed in $SURVEY_DOC" >&2
    errors=$((errors + 1))
    missing=$((missing + 1))
  fi
done <<<"$job_scripts"

total="$(echo "$job_scripts" | wc -l | tr -d ' ')"

if [ "$errors" -ne 0 ]; then
  echo "FAIL: $missing/$total audit-job scripts missing from survey doc" >&2
  exit 1
fi

echo "OK: all $total fast-checks scripts.ci/*.sh scripts accounted for in $SURVEY_DOC"
exit 0
