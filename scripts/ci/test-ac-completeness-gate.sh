#!/usr/bin/env bash
# test-ac-completeness-gate.sh — INFRA-1401
#
# Smoke-tests pre-commit-ac-completeness.sh:
#  1. Hook script exists and is executable
#  2. SCRIPT_RE pattern is present in hook
#  3. Gap with AC referencing missing test file → hook exits 1
#  4. Gap with AC referencing file that IS staged → hook exits 0
#  5. Gap with AC referencing file that already exists in HEAD → hook exits 0
#  6. Commit with no gap ID → hook exits 0 (not checked)
#  7. AC-Backfill-Reason trailer bypasses the gate
#  8. CHUMP_AC_COMPLETENESS_CHECK=0 bypasses the gate
#  9. AC referencing a non-script path (e.g. docs/) → not flagged (out of scope)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-ac-completeness.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1401 AC-completeness gate test ==="
echo

# ── 1. Hook exists and is executable ─────────────────────────────────────────
[[ -x "$HOOK" ]] \
  && ok "pre-commit-ac-completeness.sh exists and is executable" \
  || fail "pre-commit-ac-completeness.sh missing or not executable"

grep -q "INFRA-1401" "$HOOK" \
  && ok "INFRA-1401 reference present in hook" \
  || fail "INFRA-1401 reference missing"

grep -q "SCRIPT_RE" "$HOOK" \
  && ok "SCRIPT_RE filename pattern defined" \
  || fail "SCRIPT_RE missing from hook"

grep -q "AC-Backfill-Reason" "$HOOK" \
  && ok "AC-Backfill-Reason bypass trailer referenced" \
  || fail "AC-Backfill-Reason bypass missing"

grep -q "CHUMP_AC_COMPLETENESS_CHECK" "$HOOK" \
  && ok "CHUMP_AC_COMPLETENESS_CHECK env bypass defined" \
  || fail "CHUMP_AC_COMPLETENESS_CHECK missing"

grep -q "pre_commit_ac_test_missing" "$HOOK" \
  && ok "kind=pre_commit_ac_test_missing ambient emit present" \
  || fail "ambient emit missing from hook"

# ── 2. Synthetic git repo tests ───────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q
git config user.email "test@test.local"
git config user.name "Test"
touch .gitkeep
git add .gitkeep
git commit -q -m "init"

# Helper: set COMMIT_EDITMSG (what the hook reads) and run the hook
run_hook() {
  local subject="$1"
  local extra_body="${2:-}"
  printf '%s\n%s' "$subject" "$extra_body" > "$TMP/.git/COMMIT_EDITMSG"
  local actual_exit=0
  CHUMP_AC_COMPLETENESS_CHECK=1 bash "$HOOK" 2>/dev/null || actual_exit=$?
  echo "$actual_exit"
}

# Helper: create a synthetic gap YAML with AC referencing a test script
make_gap_yaml() {
  local gap_id="$1"
  local test_script="$2"
  mkdir -p "$TMP/docs/gaps"
  cat > "$TMP/docs/gaps/${gap_id}.yaml" << GAPEOF
- id: $gap_id
  domain: TEST
  title: "Synthetic test gap"
  status: open
  acceptance_criteria:
    - "Smoke test $test_script verifies the feature"
GAPEOF
  git add "docs/gaps/${gap_id}.yaml" 2>/dev/null || true
}

# Test 3: Gap AC references missing test → blocked (exit 1)
make_gap_yaml "TEST-001" "scripts/ci/test-missing-feature.sh"
actual=$(run_hook "feat(TEST-001): add missing feature")
[[ "$actual" == "1" ]] \
  && ok "missing test file in AC → hook exits 1 (blocked)" \
  || fail "missing test in AC did not block (exit $actual, expected 1)"

# Test 4: Gap AC references file that IS staged → allowed (exit 0)
mkdir -p "$TMP/scripts/ci"
echo "#!/bin/bash" > "$TMP/scripts/ci/test-present-feature.sh"
git add "scripts/ci/test-present-feature.sh"
make_gap_yaml "TEST-002" "scripts/ci/test-present-feature.sh"
actual=$(run_hook "feat(TEST-002): add present feature")
[[ "$actual" == "0" ]] \
  && ok "staged test file in AC → hook exits 0 (allowed)" \
  || fail "staged test in AC wrongly blocked (exit $actual, expected 0)"

# Test 5: Gap AC references file that exists in HEAD → allowed (exit 0)
# Commit the file first, then test
git commit -q -m "add test script"
make_gap_yaml "TEST-003" "scripts/ci/test-present-feature.sh"
actual=$(run_hook "feat(TEST-003): use committed feature")
[[ "$actual" == "0" ]] \
  && ok "HEAD-committed test file in AC → hook exits 0 (allowed)" \
  || fail "HEAD-committed test in AC wrongly blocked (exit $actual, expected 0)"

# Test 6: Commit subject has no gap ID → not checked (exit 0)
actual=$(run_hook "chore: update changelog")
[[ "$actual" == "0" ]] \
  && ok "no gap ID in subject → hook exits 0 (skipped)" \
  || fail "commit without gap ID wrongly blocked (exit $actual, expected 0)"

# Test 7: AC-Backfill-Reason trailer bypasses the gate
make_gap_yaml "TEST-004" "scripts/ci/test-another-missing.sh"
actual=$(run_hook "feat(TEST-004): feature without test" $'\n\nAC-Backfill-Reason: test ships in follow-up PR to unblock release')
[[ "$actual" == "0" ]] \
  && ok "AC-Backfill-Reason trailer → hook exits 0 (bypassed)" \
  || fail "AC-Backfill-Reason bypass did not work (exit $actual, expected 0)"

# Test 8: CHUMP_AC_COMPLETENESS_CHECK=0 env bypass
make_gap_yaml "TEST-005" "scripts/ci/test-yet-another-missing.sh"
printf 'feat(TEST-005): env bypass test\n' > "$TMP/.git/COMMIT_EDITMSG"
actual=0
CHUMP_AC_COMPLETENESS_CHECK=0 bash "$HOOK" 2>/dev/null || actual=$?
[[ "$actual" == "0" ]] \
  && ok "CHUMP_AC_COMPLETENESS_CHECK=0 → hook exits 0 (bypassed)" \
  || fail "env bypass did not suppress hook (exit $actual, expected 0)"

# Test 9: AC referencing docs/ path → not flagged (SCRIPT_RE only matches scripts/)
make_gap_yaml "TEST-006" "docs/process/SOME_GUIDE.md"
# The yaml also happens to have a reference that SCRIPT_RE wouldn't match
# Override the gap yaml to only contain a docs reference
cat > "$TMP/docs/gaps/TEST-006.yaml" << GAPEOF
- id: TEST-006
  domain: TEST
  title: "Docs-only AC"
  status: open
  acceptance_criteria:
    - "Update docs/process/SOME_GUIDE.md with examples"
GAPEOF
git add "docs/gaps/TEST-006.yaml" 2>/dev/null || true
actual=$(run_hook "feat(TEST-006): docs only change")
[[ "$actual" == "0" ]] \
  && ok "docs/ path in AC (not scripts/) → hook exits 0 (not flagged)" \
  || fail "docs/ path wrongly flagged (exit $actual, expected 0)"

cd "$REPO_ROOT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
