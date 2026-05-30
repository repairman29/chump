#!/usr/bin/env bash
# test-cascade-trigger-paths.sh — INFRA-2207 (P1/xs)
#
# Asserts scripts/coord/cascade-rebase-trigger-paths.txt contains the
# minimum set of hot paths whose change on main wedges every open PR.
# Each entry is a real-world incident replay:
#   - bootstrap-manifest.yaml: #2752 fix-installer-manifest unwedged pr-hygiene
#   - event-registry-reserved.txt: every PR runs event-registry-coverage
#   - pre-commit + install-hooks.sh: every PR re-runs hooks on rebase
#
# Regression covered: 10 PRs stuck on pr-hygiene fail for hours after #2752
# landed; manual cascade-rebase was needed instead of the queue-driver auto-cascade.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRIGGER_FILE="$REPO_ROOT/scripts/coord/cascade-rebase-trigger-paths.txt"

if [[ ! -f "$TRIGGER_FILE" ]]; then
    echo "FAIL: $TRIGGER_FILE missing"
    exit 1
fi

REQUIRED_PATHS=(
    "Cargo.toml"
    "rust-toolchain.toml"
    ".github/workflows/ci.yml"
    "scripts/setup/bootstrap-manifest.yaml"
    "scripts/ci/event-registry-reserved.txt"
    "scripts/git-hooks/pre-commit"
    "scripts/setup/install-hooks.sh"
)

pass=0
fail=0

for p in "${REQUIRED_PATHS[@]}"; do
    if grep -Fxq "$p" "$TRIGGER_FILE"; then
        echo "PASS: $p present"
        pass=$((pass+1))
    else
        echo "FAIL: $p MISSING from cascade-rebase-trigger-paths.txt"
        fail=$((fail+1))
    fi
done

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-cascade-trigger-paths: ALL $pass required paths present"
    exit 0
else
    echo "test-cascade-trigger-paths: $pass passed, $fail missing"
    exit 1
fi
