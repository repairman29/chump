#!/usr/bin/env bash
# W3.2 — Extract CI / test failure lines + suggested [COS] task; optional fingerprint dedupe (local).
#
# Usage:
#   ./scripts/ci-failure-digest.sh path/to/log.txt
#   cat log.txt | ./scripts/ci-failure-digest.sh -
#   ./scripts/ci-failure-digest.sh --no-dedupe log.txt
#
# Dedupe: SHA-256 of failure excerpts (or first 8k of body if no matches) vs
#   $ROOT/logs/ci-failure-dedupe.tsv (override with CI_FAILURE_DEDUPE_FILE).
#   Disable with CI_FAILURE_DEDUPE=0 or --no-dedupe.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NO_DEDUPE=0
if [[ "${1:-}" == "--no-dedupe" ]]; then
  NO_DEDUPE=1
  shift
fi
LOG="${1:-}"
if [[ -z "$LOG" ]]; then
  echo "usage: $0 [--no-dedupe] <logfile|- for stdin>" >&2
  exit 1
fi

if [[ "$LOG" == "-" ]]; then
  body=$(cat)
else
  body=$(cat "$LOG")
fi

excerpts=$(echo "$body" | grep -E '(^FAIL |^failures:|^error:|^ERROR |^test result:|^#\[error\]|panicked at)' | head -50 || true)
if [[ -z "${excerpts//[$'\t\n\r ']/}" ]]; then
  fp_src=$(printf '%s' "$body" | head -c 8000)
else
  fp_src=$excerpts
fi

fp=$(printf '%s' "$fp_src" | openssl dgst -sha256 2>/dev/null | awk '{print $2}')
if [[ -z "$fp" ]]; then
  fp="no_openssl"
fi

DEDUPE="${CI_FAILURE_DEDUPE:-1}"
DEDUPE_FILE="${CI_FAILURE_DEDUPE_FILE:-$ROOT/logs/ci-failure-dedupe.tsv}"
mkdir -p "$(dirname "$DEDUPE_FILE")"

if [[ "$DEDUPE" != "0" && "$NO_DEDUPE" == "0" && -f "$DEDUPE_FILE" ]] && grep -q "^${fp}	" "$DEDUPE_FILE" 2>/dev/null; then
  prev=$(grep "^${fp}	" "$DEDUPE_FILE" | head -1)
  echo "## Dedupe (same failure fingerprint)"
  echo
  echo "Existing entry: \`$prev\`"
  echo
  echo "Skip opening a duplicate task. To force a new stub: \`$0 --no-dedupe ...\` or remove the line from \`$DEDUPE_FILE\`."
  exit 0
fi

echo "## Failure excerpts (first 50 matching lines)"
echo
if [[ -n "${excerpts//[$'\t\n\r ']/}" ]]; then
  echo "$excerpts"
else
  echo "(no matching lines — widen patterns in script if needed)"
fi
echo
echo "---"
echo "## Suggested task"
if [[ "$LOG" == "-" ]]; then
  base="stdin"
else
  base=$(basename "$LOG")
fi
echo "- **Title:** \`[COS] CI: $base\`"
echo "- **Notes:** paste excerpts above; link CI run URL; assignee chump. fingerprint=\`$fp\`"

if [[ "$DEDUPE" != "0" && "$NO_DEDUPE" == "0" ]]; then
  printf '%s\t%s\t%s\n' "$fp" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base" >>"$DEDUPE_FILE"
  echo
  echo "(Recorded fingerprint in $DEDUPE_FILE — re-run the same log to get a dedupe skip.)"
fi
