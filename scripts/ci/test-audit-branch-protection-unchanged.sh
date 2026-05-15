#!/usr/bin/env bash
# scripts/ci/test-audit-branch-protection-unchanged.sh — INFRA-1314
#
# Tests that audit-branch-protection.sh --check-staged fails if an unchanged
# workflow file contains branch-protection rules.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

# TEST 1: Create a NEW workflow file with branch-protection keyword, don't stage it
echo "TEST 1: New workflow with protection keyword, NOT staged"
git checkout . >/dev/null 2>&1 || true
git clean -fd >/dev/null 2>&1 || true

# Stage existing workflows that have protection keywords
# We modify them slightly to make them staged (git requires content changes)
for f in .github/workflows/*.yml; do
    if grep -qi "branch_protection\|enforce_admins\|required_checks" "$f" 2>/dev/null; then
        echo "" >> "$f"  # Add newline to trigger git detection
        git add "$f" 2>/dev/null || true
    fi
done

# Create new workflow file with protection keyword (not tracked yet)
mkdir -p ".github/workflows"
cat > ".github/workflows/test-new-protection-tmp.yml" << 'YAML'
name: Test Protection
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo "test"
      # enforce_admins would go here
YAML

# Stage a different file
echo "change" >> .env.example
git add .env.example

# Run audit - should FAIL because test-new-protection-tmp.yml has protection keyword and is unstaged
if bash scripts/ci/audit-branch-protection.sh --check-staged >/dev/null 2>&1; then
    echo "  ✗ FAIL (expected exit 1)"
    FAIL=$((FAIL + 1))
else
    echo "  ✓ PASS (correctly failed with exit 1)"
    PASS=$((PASS + 1))
fi

# TEST 2: Stage the protection workflow file - should PASS
echo ""
echo "TEST 2: New workflow with protection keyword, NOW staged"
git add ".github/workflows/test-new-protection-tmp.yml"

# Run audit - should PASS
if bash scripts/ci/audit-branch-protection.sh --check-staged >/dev/null 2>&1; then
    echo "  ✓ PASS (correctly passed with exit 0)"
    PASS=$((PASS + 1))
else
    echo "  ✗ FAIL (expected exit 0)"
    FAIL=$((FAIL + 1))
fi

# Clean up
rm -f ".github/workflows/test-new-protection-tmp.yml"
git checkout . >/dev/null 2>&1 || true
git clean -fd >/dev/null 2>&1 || true

echo ""
echo "============ SUMMARY ============"
echo "Passed: $PASS | Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
else
    exit 1
fi
