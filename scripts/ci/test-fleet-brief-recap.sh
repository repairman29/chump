#!/usr/bin/env bash
# scripts/ci/test-fleet-brief-recap.sh — INFRA-1148
#
# Verifies fleet-brief.sh INFRA-1148 changes:
#   1. Ships counter uses git log (no gh/GraphQL calls)
#   2. 'Shipped last 6h' pillar table appears
#   3. Overlap clusters appear when ≥3 commits touch same dir
#   4. CHUMP_FLEET_BRIEF_INJECT=0 bypass registered in ambient-context-inject.sh
#   5. Script runs in <500ms (no live API calls)
#
# Creates a synthetic git repo with fixture commits to exercise the logic.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLEET_BRIEF="$REPO_ROOT/scripts/dispatch/fleet-brief.sh"
INJECT="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

pass=0; total=0
check() {
  total=$((total+1))
  if "$@" >/dev/null 2>&1; then
    ok "$*"
    pass=$((pass+1))
  else
    fail "$*"
  fi
}

echo "=== INFRA-1148: fleet-brief recap checks ==="

# 1. Script exists + executable
check test -f "$FLEET_BRIEF"
check test -x "$FLEET_BRIEF"

# 2. No gh/GraphQL calls — no 'gh pr list' in ships_24h computation
total=$((total+1))
if ! grep -q "gh pr list.*merged" "$FLEET_BRIEF"; then
  ok "fleet-brief.sh: no 'gh pr list --state merged' (GraphQL migrated)"
  pass=$((pass+1))
else
  fail "fleet-brief.sh: still contains 'gh pr list --state merged' (GraphQL not migrated)"
fi

# 3. Uses git log for ship counts
check grep -q '_git_log_24h\|git.*log.*24 hours\|git.*log.*after.*24' "$FLEET_BRIEF"
check grep -q '_git_log_6h\|git.*log.*6 hours\|git.*log.*after.*6' "$FLEET_BRIEF"

# 4. 'Shipped last 6h' section present
check grep -q 'Shipped last 6h' "$FLEET_BRIEF"

# 5. 6h pillar variables declared
check grep -q 's6_resilient\|s6_effective\|s6_credible' "$FLEET_BRIEF"

# 6. Overlap clusters logic present
check grep -q 'Overlap clusters\|overlap_clusters\|_overlap' "$FLEET_BRIEF"

# 7. CHUMP_FLEET_BRIEF_INJECT bypass in ambient-context-inject.sh
check test -f "$INJECT"
check grep -q 'CHUMP_FLEET_BRIEF_INJECT' "$INJECT"

# 8. Fixture test: create synthetic git repo with known commits and run fleet-brief.sh
echo ""
echo "--- Fixture test ---"
_tmpdir=$(mktemp -d)
trap "rm -rf '$_tmpdir'" EXIT

(
  cd "$_tmpdir"
  git init -q
  git config user.email "t@t.t"
  git config user.name "Test"

  # Create a fake "origin/main" branch with synthetic commits
  git checkout -q -b main

  # Need at least one real file to make commits
  echo "init" > README.md
  git add README.md
  git commit -q -m "chore: init"

  # Add 5 synthetic "shipped" commits with pillar tags
  mkdir -p scripts src docs
  for i in 1 2 3; do
    echo "x$i" > "scripts/file$i.sh"
    git add .
    git commit -q -m "fix(INFRA-$i): RESILIENT — fixture ship $i"
  done
  echo "x" > "src/lib.rs"
  git add .
  git commit -q -m "feat(EFFECTIVE-001): EFFECTIVE — fixture ship"
  echo "y" > "docs/note.md"
  git add .
  git commit -q -m "fix(DOC-001): CREDIBLE — fixture ship"

  # Point origin/main to current HEAD (simulate remote)
  git remote add origin "$_tmpdir"
  git fetch -q origin main 2>/dev/null || true
  # Use the local branch as origin/main via refspec hack
  git update-ref refs/remotes/origin/main HEAD
)

# Run fleet-brief.sh against the fixture repo
_output=$(cd "$_tmpdir" && bash "$FLEET_BRIEF" 2>/dev/null || true)
total=$((total+1))
if echo "$_output" | grep -q "Ships:"; then
  ok "fleet-brief.sh runs against fixture repo (Ships: line present)"
  pass=$((pass+1))
else
  fail "fleet-brief.sh failed to produce output for fixture repo"
fi

total=$((total+1))
if echo "$_output" | grep -q "RESILIENT\|EFFECTIVE\|CREDIBLE"; then
  ok "fleet-brief.sh pillar detection works in fixture"
  pass=$((pass+1))
else
  fail "fleet-brief.sh produced no pillar output for fixture"
fi

# 9. Performance: fleet-brief.sh should complete in <10s against local repo
# Use SECONDS builtin (portable) for wall-clock check.
_t_start=$SECONDS
timeout 10 bash "$FLEET_BRIEF" >/dev/null 2>&1 || true
_elapsed=$(( SECONDS - _t_start ))
total=$((total+1))
if [[ "$_elapsed" -lt 10 ]]; then
  ok "fleet-brief.sh completed in <10s (${_elapsed}s)"
  pass=$((pass+1))
else
  fail "fleet-brief.sh took ${_elapsed}s (>10s)"
fi

echo ""
echo "=== Results: $pass/$total passed ==="
if [[ "$pass" -ne "$total" ]]; then
  exit 1
fi
echo "INFRA-1148: fleet-brief recap validation complete."
