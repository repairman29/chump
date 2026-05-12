#!/usr/bin/env bash
# scripts/ci/test-cli-arg-validation.sh — CREDIBLE-016
#
# Validates that critical chump CLI commands show proper error messages when
# called with missing required args or unknown flags.
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Resolve chump binary: prefer local build (worktree CI), fall back to PATH
CHUMP="${REPO_ROOT}/target/debug/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="${HOME}/.cargo/bin/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump' first)"
    exit 0
fi

echo "=== CREDIBLE-016: CLI argument validation ==="
echo "  binary: $CHUMP"
echo

# Check that a command exits non-zero and its combined output matches a pattern.
check_error() {
    local label="$1"; shift
    local pattern="$1"; shift
    local output
    output=$("$CHUMP" "$@" 2>&1) || true
    # Capture real exit code without relying on $? after 'local'
    "$CHUMP" "$@" >/dev/null 2>&1; local _rc=$?
    if [[ $_rc -eq 0 ]]; then
        fail "$label: expected non-zero exit, got 0"
    elif echo "$output" | grep -qi "$pattern"; then
        ok "$label"
    else
        fail "$label: output did not match '$pattern' (got: ${output:0:120})"
    fi
}

# 1. chump gap set <no args> → Usage:
check_error "gap set: no args shows Usage" "Usage:" gap set

# 2. chump gap set --bad-flag → Error: unknown flag
check_error "gap set: unknown flag shows Error" "Error:" gap set --bad-flag

# 3. chump gap show <no args> → Usage:
check_error "gap show: no args shows Usage" "Usage:" gap show

# 4. chump gap ship <no args> → Usage:
check_error "gap ship: no args shows Usage" "Usage:" gap ship

# 5. chump gap reserve <no args> → Usage:
check_error "gap reserve: no args shows Usage" "Usage:" gap reserve

# 6. chump gap preflight <no args> → Usage:
check_error "gap preflight: no args shows Usage" "Usage:" gap preflight

# 7. chump claim <no args> → Usage:
check_error "claim: no args shows Usage" "Usage:" claim

# 8. chump gap decompose <no args> → Usage:
check_error "gap decompose: no args shows Usage" "Usage:" gap decompose

# 9. chump lesson-grade <no args> → Usage:
check_error "lesson-grade: no args shows Usage" "Usage:" lesson-grade

# 10. chump pr-coupling-cost <no args> → Usage:
check_error "pr-coupling-cost: no args shows Usage" "Usage:" pr-coupling-cost

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
