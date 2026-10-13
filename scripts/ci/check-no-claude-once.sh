#!/usr/bin/env bash
# check-no-claude-once.sh — RESILIENT-1142
#
# Checks that production scripts do not use the prohibited "claude --once" flag.
# The "--once" flag is only acceptable in CI test scripts (scripts/ci/test-*.sh).
#
# Exit 0 = no prohibited flags found
# Exit 1 = at least one prohibited usage detected
#
# Context: This enforces the transition from "claude --once" to "claude -p"
# for auth probes. The --once flag is deprecated in favor of -p.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VIOLATIONS=0

lint_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))

        # Skip comment-only lines
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" == \#* ]] && continue

        # Check for "claude --once" or "claude -o" (short form)
        if [[ "$line" =~ claude[[:space:]]+(--once|-o)([[:space:]]|$|[\"\047]) ]]; then
            echo "$file:$lineno: prohibited 'claude --once' flag found" >&2
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    done < "$file"
}

# Find all shell scripts in scripts/ except test scripts
# Test scripts (scripts/ci/test-*.sh) are allowed to use --once
while IFS= read -r file; do
    lint_file "$file"
done < <(find scripts -name "*.sh" -type f ! -name "test-*.sh" 2>/dev/null | sort)

if [[ "$VIOLATIONS" -gt 0 ]]; then
    echo "check-no-claude-once: $VIOLATIONS occurrence(s) of prohibited 'claude --once' flag" >&2
    exit 1
fi

echo "No prohibited flags found"
exit 0
