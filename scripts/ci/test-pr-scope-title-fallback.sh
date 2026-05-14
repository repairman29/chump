#!/usr/bin/env bash
# CI gate for INFRA-976: check-pr-scope.sh PR_TITLE fallback chain.
# Verifies the script prefers $PR_TITLE env var over gh CLI and commit subject.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/check-pr-scope.sh"
PASS=0; FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"; (( PASS++ )) || true
  else
    echo "  FAIL: $desc"; (( FAIL++ )) || true
  fi

}

echo "=== INFRA-976: check-pr-scope.sh PR_TITLE fallback chain ==="

# Structural checks
check "script exists and executable" test -x "$SCRIPT"
check "captures incoming PR_TITLE env before overwriting" \
  grep -q '_pr_title_from_env' "$SCRIPT"
check "PR_TITLE env var used in fallback chain" bash -c \
  "grep -A3 '_pr_title_from_env' '$SCRIPT' | grep -q 'PR_TITLE\b'"
check "PR_TITLE_ENV kept for backward compat" grep -q 'PR_TITLE_ENV' "$SCRIPT"
check "PR_TITLE_OVERRIDE still highest priority" bash -c \
  "grep -n 'PR_TITLE_OVERRIDE\|_pr_title_from_env\|PR_TITLE_ENV' '$SCRIPT' \
   | grep -v '^.*#' \
   | awk -F: '{print \$1}' \
   | paste - - - \
   | awk '{if (\$1+0 < \$2+0 && \$2+0 < \$3+0) exit 0; else exit 1}'"
check "workflow passes PR_TITLE env to check-pr-scope step" \
  grep -q 'PR_TITLE:.*github.event.pull_request.title' \
  "$REPO_ROOT/.github/workflows/ci.yml"

# Functional: extract the capture block to a temp file and source it
TMPF="$(mktemp /tmp/capture_block_XXXXXX.sh)"
trap 'rm -f "$TMPF"' EXIT
grep -A12 'Capture PR_TITLE from environment' "$SCRIPT" | head -12 > "$TMPF"
echo 'echo "$PR_TITLE"' >> "$TMPF"

test_fallback=$(PR_TITLE="from-env-var" bash "$TMPF" 2>/dev/null)
if [[ "$test_fallback" == "from-env-var" ]]; then
  echo "  PASS: PR_TITLE env var is captured correctly"; (( PASS++ )) || true
else
  echo "  FAIL: PR_TITLE env var not captured (got: '$test_fallback')"; (( FAIL++ )) || true
fi

test_override=$(PR_TITLE="from-env-var" PR_TITLE_OVERRIDE="from-override" bash "$TMPF" 2>/dev/null)
if [[ "$test_override" == "from-override" ]]; then
  echo "  PASS: PR_TITLE_OVERRIDE takes priority over PR_TITLE env"; (( PASS++ )) || true
else
  echo "  FAIL: PR_TITLE_OVERRIDE priority broken (got: '$test_override')"; (( FAIL++ )) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
