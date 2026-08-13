#!/usr/bin/env bash
# scripts/ci/test-gh-in-ci-guarded.sh — RESILIENT-018
#
# CI lint gate: any scripts/ci/test-*.sh that calls `gh api` or `gh pr ...`
# must `source .../lib/ci-guards.sh` and call `check_gh_token_or_skip` so
# that a workflow which forgot to set GH_TOKEN degrades to a WARN-and-skip
# instead of a hard CI failure (precedent: INFRA-1846 / e2e-pwa).
#
# Existing scripts that pre-date this gate are listed in
# scripts/ci/gh-token-guard-baseline.txt (RESILIENT-018 filed follow-up
# migration gaps per script — see AC#7). New scripts NOT in the baseline
# must comply immediately.
#
# Exit 0 = no new (non-baselined) violations.
# Exit 1 = new script calls gh api/gh pr without sourcing ci-guards.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_DIR="$REPO_ROOT/scripts/ci"
BASELINE="$CI_DIR/gh-token-guard-baseline.txt"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; }

# Matches `gh api ...` / `gh pr <verb> ...` invocations. Excludes comment
# lines and the ci-guards.sh library itself.
GH_PATTERN='(^|[^A-Za-z0-9_.-])gh (api|pr)([^A-Za-z0-9_-]|$)'

load_baseline() {
  [[ -f "$BASELINE" ]] || return
  grep -v '^\s*#' "$BASELINE" | grep -v '^\s*$' | awk '{print $1}'
}

BASELINED=()
while IFS= read -r line; do
  BASELINED+=("$line")
done < <(load_baseline)

is_baselined() {
  local rel="$1"
  for b in "${BASELINED[@]:-}"; do
    [[ "$rel" == "$b" ]] && return 0
  done
  return 1
}

calls_gh() {
  local file="$1"
  grep -vE '^\s*#' "$file" | grep -qE "$GH_PATTERN"
}

sources_guard() {
  local file="$1"
  grep -qE 'ci-guards\.sh' "$file"
}

VIOLATIONS=0
NEW_VIOLATIONS=()

while IFS= read -r -d '' file; do
  rel="${file#$REPO_ROOT/}"
  calls_gh "$file" || continue
  sources_guard "$file" && continue
  if is_baselined "$rel"; then
    continue
  fi
  VIOLATIONS=$((VIOLATIONS + 1))
  NEW_VIOLATIONS+=("$rel")
done < <(find "$CI_DIR" -maxdepth 1 -name 'test-*.sh' -print0 | sort -z)

if [[ $VIOLATIONS -gt 0 ]]; then
  fail "$VIOLATIONS script(s) call gh api/gh pr without sourcing scripts/ci/lib/ci-guards.sh"
  for v in "${NEW_VIOLATIONS[@]}"; do
    echo "  - $v" >&2
  done
  echo "" >&2
  echo "  Fix: source \"\$(dirname \"\$0\")/lib/ci-guards.sh\" and call" >&2
  echo "  check_gh_token_or_skip before the first gh api/gh pr call. If this" >&2
  echo "  is pre-existing debt, add it to $BASELINE with a migration-gap note." >&2
  exit 1
fi

ok "no un-guarded gh api/gh pr callers in scripts/ci/test-*.sh outside the baseline"
exit 0
