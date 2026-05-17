#!/usr/bin/env bash
# scripts/ci/test-shell-set-e-coverage.sh — INFRA-1492
#
# Gate: every shell script under scripts/coord/ and scripts/ci/ must have
# 'set -e' (or '-eu' / '-euo pipefail' / '-eo pipefail') in the first 30
# lines, OR appear in scripts/ci/set-e-exemptions.txt.
#
# Rationale: without set -e, a failed command does not abort the script — it
# continues and emits exit code 0, causing the fleet to think operations
# succeeded when they did not (INFRA-1492).
#
# Usage:
#   scripts/ci/test-shell-set-e-coverage.sh        # checks all scripts
#   scripts/ci/test-shell-set-e-coverage.sh --fix  # prints fix commands
#
# Exit codes:
#   0  all scripts have set -e (or are exempted)
#   1  one or more scripts are missing set -e
#   2  usage error

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXEMPTIONS_FILE="$REPO_ROOT/scripts/ci/set-e-exemptions.txt"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; }

FIX_MODE=0
[[ "${1:-}" == "--fix" ]] && FIX_MODE=1

# ── Build cleaned exemption list (strip comments + blanks) ───────────────────
EXEMPTIONS_CLEAN="$(mktemp /tmp/set-e-exemptions-XXXXXX.txt)"
trap 'rm -f "$EXEMPTIONS_CLEAN"' EXIT

if [[ -f "$EXEMPTIONS_FILE" ]]; then
  grep -vE '^[[:space:]]*(#|$)' "$EXEMPTIONS_FILE" | sed 's|^./||' > "$EXEMPTIONS_CLEAN"
fi

# Helper: returns 0 if $1 (relative path) is in the exemption list
is_exempted() {
  local rel="$1"
  grep -qxF "$rel" "$EXEMPTIONS_CLEAN" 2>/dev/null
}

# ── Scan scripts ──────────────────────────────────────────────────────────────
FAILING=""
TOTAL=0
PASSED=0
EXEMPTED_COUNT=0

while IFS= read -r abs_path; do
  TOTAL=$(( TOTAL + 1 ))
  rel="${abs_path#$REPO_ROOT/}"

  if is_exempted "$rel"; then
    EXEMPTED_COUNT=$(( EXEMPTED_COUNT + 1 ))
    continue
  fi

  # Check first 30 lines for set -e / set -euo pipefail / set -eo pipefail
  if head -30 "$abs_path" 2>/dev/null | \
      grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e|^[[:space:]]*set[[:space:]]+-[a-zA-Z]*u[a-zA-Z]*o[[:space:]]+pipefail'; then
    PASSED=$(( PASSED + 1 ))
    continue
  fi

  FAILING="${FAILING}${rel}"$'\n'
done < <(find "$REPO_ROOT/scripts/coord" "$REPO_ROOT/scripts/ci" -name "*.sh" -type f | sort)

# Count failures
FAIL_COUNT=0
if [[ -n "$FAILING" ]]; then
  FAIL_COUNT=$(printf '%s' "$FAILING" | grep -c .)
fi

# ── Report ────────────────────────────────────────────────────────────────────
echo "Shell set-e coverage — scripts/coord/ + scripts/ci/"
printf '  Total:    %d scripts\n' "$TOTAL"
printf '  Passing:  %d (set -e in first 30 lines)\n' "$PASSED"
printf '  Exempted: %d (see scripts/ci/set-e-exemptions.txt)\n' "$EXEMPTED_COUNT"
printf '  Failing:  %d\n' "$FAIL_COUNT"
echo ""

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  ok "All scripts have set -e or are exempted"
  exit 0
fi

fail "The following scripts lack 'set -e' in the first 30 lines and are NOT exempted:"
printf '%s' "$FAILING" | while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  printf '  ✗  %s\n' "$f"
done

echo ""
echo "Fix: add 'set -euo pipefail' on line 2 (after the shebang) of each script above."
echo "     Or add an exemption to scripts/ci/set-e-exemptions.txt with a comment explaining why."
echo ""

if [[ "$FIX_MODE" -eq 1 ]]; then
  echo "# Suggested fix commands:"
  printf '%s' "$FAILING" | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    abs="$REPO_ROOT/$f"
    printf '  # %s\n' "$abs"
  done
fi

exit 1
