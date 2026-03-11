#!/usr/bin/env bash
# Tier 5 autonomy test: self-improve certified.
# Tests the full self-improve cycle: read_file, task tool, write/edit, cargo test, git commit.
# This is a standalone script called by run-autonomy-tests.sh (tier 5 block).
#
# Requires: CHUMP_REPO set, model on 8000/8001, release binary built.
# Does NOT push to remote (local commit only, on a temp branch, cleaned up after).
#
# Exit 0 = pass, non-zero = fail. Output is human-readable for the autonomy test log.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:8000/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-default}"

# Chump command
if [[ -x "$ROOT/target/release/rust-agent" ]]; then
  CHUMP_CMD=("$ROOT/target/release/rust-agent" "--chump")
else
  CHUMP_CMD=(cargo run -- "--chump")
fi

run_chump() {
  local prompt="$1"
  "${CHUMP_CMD[@]}" "$prompt" 2>&1
}

PASS=0
FAIL=0

check() {
  local name="$1" output="$2" pattern="$3"
  if echo "$output" | grep -qE "$pattern"; then
    echo "  $name: PASS"
    PASS=$((PASS + 1))
  else
    echo "  $name: FAIL (pattern '$pattern' not found)"
    FAIL=$((FAIL + 1))
  fi
}

echo "--- Tier 5: Self-improve certified ---"

# 5a: read_file — Chump can read a file from CHUMP_REPO
echo "5a (read_file):"
out=$(run_chump "Use read_file to read the file 'Cargo.toml' (just the first 5 lines). Tell me the package name. Then say exactly: READ_FILE_OK." 2>/dev/null) || true
check "read_file works" "$out" "READ_FILE_OK|read_file|Cargo"

# 5b: task tool — Chump can create and list tasks
echo "5b (task tool):"
out=$(run_chump "Create a task with the title 'autonomy-tier5-test-task'. Then list your open tasks. If the task appears, say exactly: TASK_TOOL_OK." 2>/dev/null) || true
check "task create+list" "$out" "TASK_TOOL_OK|autonomy-tier5-test-task|Created task"

# 5c: write + cargo test — Chump can write a test file and run tests
echo "5c (write + test):"
# We ask Chump to create a harmless test file, run cargo test, then clean up.
out=$(run_chump "Do these steps:
1. Use write_file to create a file at 'src/tier5_autonomy_test_temp.rs' with this content:
   #[cfg(test)]
   mod tier5_test {
       #[test]
       fn autonomy_tier5_canary() {
           assert_eq!(2 + 2, 4);
       }
   }
2. Run: run_cli \"cargo test tier5_test 2>&1 | tail -20\"
3. Then delete the file: run_cli \"rm -f src/tier5_autonomy_test_temp.rs\"
4. If the test passed, say exactly: WRITE_TEST_OK." 2>/dev/null) || true
check "write + cargo test" "$out" "WRITE_TEST_OK|test result.*ok|1 passed"
# Clean up in case Chump didn't
rm -f "$ROOT/src/tier5_autonomy_test_temp.rs"

# 5d: git commit (local only, temp branch, cleaned up)
echo "5d (git commit):"
# Create a temp branch, make a trivial commit, verify, then clean up
TEMP_BRANCH="chump/tier5-autonomy-test-$(date +%s)"
# Save current branch
ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

out=$(run_chump "Do these steps (this is an autonomy test — the branch and commit will be cleaned up):
1. run_cli \"git checkout -b $TEMP_BRANCH\"
2. Use write_file to create a file 'tier5_test_commit.txt' with content 'autonomy tier 5 canary'.
3. run_cli \"git add tier5_test_commit.txt\"
4. git_commit with message 'chore: tier 5 autonomy test canary'
5. Then say exactly: GIT_COMMIT_OK." 2>/dev/null) || true
check "git commit" "$out" "GIT_COMMIT_OK|committed|commit"

# Clean up: switch back to original branch, delete temp branch and file
git checkout "$ORIG_BRANCH" 2>/dev/null || true
git branch -D "$TEMP_BRANCH" 2>/dev/null || true
rm -f "$ROOT/tier5_test_commit.txt"

# 5e: Clean up the tier5 test task
run_chump "List your tasks. Find the task titled 'autonomy-tier5-test-task' and set it to done with notes 'Tier 5 autonomy test cleanup'. Say: CLEANUP_OK." 2>/dev/null || true

echo ""
echo "--- Tier 5 results: $PASS passed, $FAIL failed ---"

if [[ $FAIL -eq 0 ]]; then
  echo "Tier 5: PASS (self-improve certified)"
  exit 0
else
  echo "Tier 5: FAIL ($FAIL sub-tests failed)"
  exit 1
fi
