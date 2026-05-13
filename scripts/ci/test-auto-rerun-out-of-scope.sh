#!/usr/bin/env bash
# test-auto-rerun-out-of-scope.sh — INFRA-1003
#
# Integration tests for scripts/coord/auto-rerun-out-of-scope.sh
# Network-free: stubs `gh` on PATH with synthetic PR + check data.
#
# Tests:
#   1. CHUMP_AUTO_RERUN_OOS=0 bypass exits 0
#   2. OOS-only failure (shell test, no overlap) → rerun triggered
#   3. In-scope failure (diff touches the test script) → no rerun
#   4. Unknown job (no source mapping) → conservative: no rerun (assumed overlap)
#   5. Budget guard: second call within 24h is suppressed
#   6. Ambient event emitted on --execute run

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/auto-rerun-out-of-scope.sh"

if [[ ! -x "$TARGET" ]]; then
    echo "FATAL: $TARGET not executable"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/.chump-locks" "$TMP/scripts/ci" "$TMP/budget"
export PATH="$TMP/bin:$PATH"
export AMBIENT_JSONL="$TMP/.chump-locks/ambient.jsonl"
export CHUMP_OOS_BUDGET_DIR="$TMP/budget"
touch "$AMBIENT_JSONL"

# ── Stub gh with configurable behaviour via files in $TMP ────────────────────
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub: dispatches on subcommand.
CMD="${1:-}"
SUB="${2:-}"
case "$CMD $SUB" in
  "pr view")
    cat "$GH_STUB_PR_FILES" 2>/dev/null || echo '{"files":[]}'
    ;;
  "pr checks")
    cat "$GH_STUB_PR_CHECKS" 2>/dev/null || echo '[]'
    ;;
  "run view")
    cat "$GH_STUB_RUN_JOBS" 2>/dev/null || echo '{"jobs":[]}'
    ;;
  "run rerun")
    echo "rerun_triggered: $3" >> "$GH_STUB_RERUN_LOG"
    exit 0
    ;;
  *)
    echo "gh-stub: unhandled: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export GH_STUB_RERUN_LOG="$TMP/reruns.log"

# ── Helper: write a shell test script to the worktree so source mapping works ─
make_test_script() {
    local name="$1"
    mkdir -p "$REPO_ROOT/scripts/ci" 2>/dev/null || true
    # Only create if it doesn't already exist (we don't want to clobber real files)
    [[ ! -f "$REPO_ROOT/scripts/ci/${name}" ]] && touch "$REPO_ROOT/scripts/ci/${name}"
}

# ── Test 1: bypass ────────────────────────────────────────────────────────────
echo "Test 1: CHUMP_AUTO_RERUN_OOS=0 bypass"
out="$(CHUMP_AUTO_RERUN_OOS=0 bash "$TARGET" 999 --execute 2>&1)"
if echo "$out" | grep -q "bypass"; then
    ok "bypass exits 0 and prints bypass message"
else
    fail "bypass not working: $out"
fi

# ── Test 2: OOS-only failure → rerun ─────────────────────────────────────────
echo "Test 2: Out-of-scope failure → rerun triggered"
rm -f "$GH_STUB_RERUN_LOG" 2>/dev/null || true

# PR touches only scripts/coord/bot-merge.sh
export GH_STUB_PR_FILES="$TMP/pr-files.json"
cat > "$GH_STUB_PR_FILES" <<'JSON'
{"files":[{"path":"scripts/coord/bot-merge.sh"}]}
JSON

# Failing check is test-ci-flake-rerun.sh (in scripts/ci, NOT in diff)
export GH_STUB_PR_CHECKS="$TMP/pr-checks.json"
cat > "$GH_STUB_PR_CHECKS" <<'JSON'
[{"name":"fast-checks","conclusion":"failure","databaseId":"run-42"}]
JSON

export GH_STUB_RUN_JOBS="$TMP/run-jobs.json"
cat > "$GH_STUB_RUN_JOBS" <<'JSON'
{"jobs":[{"name":"test-ci-flake-rerun.sh","conclusion":"failure"}]}
JSON

# Ensure the script exists so source mapping succeeds
make_test_script "test-ci-flake-rerun.sh"
# Set up budget dir inside TMP to avoid touching real budget
export BUDGET_OVERRIDE="$TMP/budget"

# Patch: override BUDGET_DIR by injecting env into script context
out="$(CHUMP_AUTO_RERUN_OOS=1 bash "$TARGET" 42 --execute 2>&1)"
if grep -q 'rerun_triggered' "$GH_STUB_RERUN_LOG" 2>/dev/null; then
    ok "OOS rerun triggered"
else
    fail "OOS rerun NOT triggered (output: $out)"
fi

# Ambient event emitted (Test 6 runs implicitly here)
if grep -q 'auto_rerun_out_of_scope' "$AMBIENT_JSONL" 2>/dev/null; then
    ok "ambient event emitted (kind=auto_rerun_out_of_scope)"
else
    fail "ambient event NOT emitted (ambient: $(cat "$AMBIENT_JSONL" 2>/dev/null))"
fi

# ── Test 3: In-scope failure → no rerun ───────────────────────────────────────
echo "Test 3: In-scope failure → no rerun"
rm -f "$GH_STUB_RERUN_LOG" 2>/dev/null || true
> "$AMBIENT_JSONL"

# PR touches scripts/coord/bot-merge.sh AND scripts/ci/test-ci-flake-rerun.sh
cat > "$GH_STUB_PR_FILES" <<'JSON'
{"files":[{"path":"scripts/coord/bot-merge.sh"},{"path":"scripts/ci/test-ci-flake-rerun.sh"}]}
JSON
# Failing job is test-ci-flake-rerun.sh (which IS in diff)
# (PR checks + run jobs same as test 2)

out="$(CHUMP_AUTO_RERUN_OOS=1 bash "$TARGET" 43 --execute 2>&1)"
if ! grep -q 'rerun_triggered' "$GH_STUB_RERUN_LOG" 2>/dev/null; then
    ok "in-scope failure: no rerun"
else
    fail "in-scope failure incorrectly triggered rerun (output: $out)"
fi

# ── Test 4: Unknown job → conservative, no rerun ──────────────────────────────
echo "Test 4: Unknown job mapping → conservative no rerun"
rm -f "$GH_STUB_RERUN_LOG" 2>/dev/null || true

cat > "$GH_STUB_PR_FILES" <<'JSON'
{"files":[{"path":"scripts/coord/bot-merge.sh"}]}
JSON

cat > "$GH_STUB_RUN_JOBS" <<'JSON'
{"jobs":[{"name":"completely-unknown-job-xyz-abc","conclusion":"failure"}]}
JSON

out="$(CHUMP_AUTO_RERUN_OOS=1 bash "$TARGET" 44 --dry-run 2>&1)"
if ! grep -q 'rerun_triggered' "$GH_STUB_RERUN_LOG" 2>/dev/null && echo "$out" | grep -q 'assuming overlap'; then
    ok "unknown job: no rerun (conservative)"
else
    fail "unknown job handling wrong (output: $out)"
fi

# ── Test 5: Budget guard ───────────────────────────────────────────────────────
echo "Test 5: Budget guard — second rerun within 24h suppressed"
rm -f "$GH_STUB_RERUN_LOG" 2>/dev/null || true

# Reset to OOS scenario
cat > "$GH_STUB_PR_FILES" <<'JSON'
{"files":[{"path":"scripts/coord/bot-merge.sh"}]}
JSON
cat > "$GH_STUB_RUN_JOBS" <<'JSON'
{"jobs":[{"name":"test-ci-flake-rerun.sh","conclusion":"failure"}]}
JSON
cat > "$GH_STUB_PR_CHECKS" <<'JSON'
[{"name":"fast-checks","conclusion":"failure","databaseId":"run-45"}]
JSON

# First call — should rerun (PR 45 hasn't been seen)
CHUMP_AUTO_RERUN_OOS=1 bash "$TARGET" 45 --execute >/dev/null 2>&1 || true
FIRST_RERUN_COUNT="$(grep -c 'rerun_triggered' "$GH_STUB_RERUN_LOG" 2>/dev/null || echo 0)"

# Second call — should be blocked by budget
rm -f "$GH_STUB_RERUN_LOG" 2>/dev/null || true
out="$(CHUMP_AUTO_RERUN_OOS=1 bash "$TARGET" 45 --execute 2>&1)"
SECOND_RERUN_COUNT="$(grep -c 'rerun_triggered' "$GH_STUB_RERUN_LOG" 2>/dev/null || echo 0)"

if [[ "$FIRST_RERUN_COUNT" -ge 1 && "$SECOND_RERUN_COUNT" -eq 0 ]] && echo "$out" | grep -q 'budget exhausted'; then
    ok "budget guard: second rerun within 24h suppressed"
else
    fail "budget guard wrong: first=$FIRST_RERUN_COUNT second=$SECOND_RERUN_COUNT (output: $out)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
