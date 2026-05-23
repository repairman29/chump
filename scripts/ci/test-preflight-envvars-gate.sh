#!/usr/bin/env bash
# scripts/ci/test-preflight-envvars-gate.sh — INFRA-1787
#
# Verifies src/preflight.rs registers the env-var-coverage gate per the
# INFRA-1731 pattern (event-registry mirror, shipped #2377). Static checks
# on the Rust source — runtime gate behavior is covered by chump preflight
# integration tests + the env-var-coverage CI script itself.
#
# Assertions:
#   1. preflight.rs invokes scripts/ci/test-env-var-coverage.sh as a Step
#   2. The gate is wrapped in CHUMP_PREFLIGHT_SKIP_ENVVARS bypass branch
#   3. Bypass emits kind=preflight_envvars_bypassed via ambient_emit
#   4. preflight_envvars_bypassed is allowlisted in event-registry-reserved.txt

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

failures=0

assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if ! grep -qE -- "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $desc"
        echo "       file: ${file#"$REPO_ROOT/"}"
        echo "       pattern: $pattern"
        failures=$((failures + 1))
    fi
}

# 1. preflight.rs references the CI script
assert_grep "$PREFLIGHT" \
    "test-env-var-coverage.sh" \
    "preflight.rs invokes test-env-var-coverage.sh as a Step"

# 2. bypass branch with the documented env var
assert_grep "$PREFLIGHT" \
    "CHUMP_PREFLIGHT_SKIP_ENVVARS" \
    "preflight.rs honors CHUMP_PREFLIGHT_SKIP_ENVVARS bypass"

# 3. bypass emits the documented event kind
assert_grep "$PREFLIGHT" \
    '"preflight_envvars_bypassed"' \
    "preflight.rs emits kind=preflight_envvars_bypassed on bypass"

# 4. bypass emit kind is allowlisted
assert_grep "$RESERVED" \
    "^preflight_envvars_bypassed" \
    "event-registry-reserved.txt allowlists preflight_envvars_bypassed"

# 5. INFRA-1787 comment present (regression marker)
assert_grep "$PREFLIGHT" \
    "INFRA-1787" \
    "preflight.rs has INFRA-1787 attribution comment"

# 6. env-vars gate appears AFTER event-registry-audit gate (ordering)
# (rough check: line number of env-var-coverage step > line number of
# event-registry-audit step in preflight.rs)
line_registry=$(grep -n "event-registry-audit\"" "$PREFLIGHT" | head -1 | cut -d: -f1)
line_envvars=$(grep -n "env-var-coverage\"" "$PREFLIGHT" | head -1 | cut -d: -f1)
if [[ -z "$line_registry" || -z "$line_envvars" ]]; then
    echo "FAIL: could not locate one of the gate names in preflight.rs"
    failures=$((failures + 1))
elif [[ "$line_envvars" -le "$line_registry" ]]; then
    echo "FAIL: env-var-coverage gate should appear after event-registry-audit"
    echo "       registry=$line_registry envvars=$line_envvars"
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1787: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1787: chump preflight has env-var-coverage gate with bypass + audit emit"
