#!/usr/bin/env bash
# scripts/ci/test-gh-in-ci-guarded.sh
# RESILIENT-018: lint gate — any scripts/ci/test-NAME.sh that calls `gh api`
# or `gh pr` directly must source scripts/ci/lib/ci-guards.sh (and call
# check_gh_token_or_skip) first, so it degrades to a WARN+skip rather than a
# hard CI failure when the workflow didn't wire GH_TOKEN/GITHUB_TOKEN.
#
# Precedent: e2e-pwa fails persistently because a gh-dependent code path runs
# in a workflow that never exported GH_TOKEN (see INFRA-1846, RESILIENT-018).
#
# Exit 0 = no new unguarded gh callers.
# Exit 1 = new unguarded gh caller found in scripts/ci/test-*.sh.
#
# Usage:
#   bash scripts/ci/test-gh-in-ci-guarded.sh
#   bash scripts/ci/test-gh-in-ci-guarded.sh --advisory   # always exits 0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/ci/gh-in-ci-guard-allowlist.txt"
ADVISORY=0
if [[ "${1:-}" == "--advisory" ]]; then
  ADVISORY=1
fi

GH_PATTERN='^\s*(gh api |gh pr (list|view|merge|comment|edit|review))'

load_allowlist() {
  if [[ ! -f "$ALLOWLIST" ]]; then
    echo "[gh-in-ci-guard] WARN: allowlist not found at $ALLOWLIST — treating as empty" >&2
    return
  fi
  grep -v '^\s*#' "$ALLOWLIST" | grep -v '^\s*$' | awk '{print $1}'
}

ALLOWED_FILES=()
while IFS= read -r line; do
  ALLOWED_FILES+=("$line")
done < <(load_allowlist)

is_allowed() {
  local rel="$1"
  for allowed in "${ALLOWED_FILES[@]:-}"; do
    [[ "$rel" == "$allowed" ]] && return 0
  done
  return 1
}

VIOLATIONS=0
VIOLATION_LINES=()

while IFS= read -r -d '' file; do
  rel="${file#$REPO_ROOT/}"
  grep -qEe "$GH_PATTERN" "$file" 2>/dev/null || continue
  grep -q 'ci-guards\.sh' "$file" 2>/dev/null && continue
  if ! is_allowed "$rel"; then
    VIOLATIONS=$((VIOLATIONS + 1))
    while IFS= read -r match; do
      VIOLATION_LINES+=("$rel: $match")
    done < <(grep -nEe "$GH_PATTERN" "$file" 2>/dev/null)
  fi
done < <(find "$REPO_ROOT/scripts/ci" -maxdepth 1 -name "test-*.sh" -print0)

if [[ $VIOLATIONS -gt 0 ]]; then
  echo "[gh-in-ci-guard] FAIL: $VIOLATIONS new unguarded gh caller(s) in scripts/ci/test-*.sh" >&2
  echo "" >&2
  echo "  These test scripts call 'gh api'/'gh pr ...' without sourcing" >&2
  echo "  scripts/ci/lib/ci-guards.sh and calling check_gh_token_or_skip first." >&2
  echo "" >&2
  echo "  Matching lines:" >&2
  for v in "${VIOLATION_LINES[@]}"; do
    echo "    $v" >&2
  done
  echo "" >&2
  echo "  Fix: source scripts/ci/lib/ci-guards.sh and call" >&2
  echo "  check_gh_token_or_skip before the gh call. See CLAUDE.md / RESILIENT-018." >&2
  echo "" >&2
  echo "  If this script pre-dates the mandate, add it to" >&2
  echo "  scripts/ci/gh-in-ci-guard-allowlist.txt and file a migration gap." >&2

  if [[ $ADVISORY -eq 1 ]]; then
    echo "[gh-in-ci-guard] Advisory mode — not blocking." >&2
    exit 0
  fi
  exit 1
else
  echo "[gh-in-ci-guard] PASS: no unguarded gh callers in scripts/ci/test-*.sh (${#ALLOWED_FILES[@]} allowlisted)"
  exit 0
fi
