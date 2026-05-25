#!/usr/bin/env bash
# test-rebase-coordination.sh — INFRA-1974 (H5) regression test.
#
# Verifies the per-branch advisory lock in scripts/coord/pr-auto-rebase.sh:
#   - flock-based mutex on .chump-locks/rebase-<branch>.lock
#   - emits pr_auto_rebase_deferred_for_operator when lock held
#   - CHUMP_PR_AUTO_REBASE_NO_LOCK=1 escape hatch present
#   - BRANCH_SAFE sanitization (slashes → underscores)
#
# Two-part validation:
#   (A) STRUCTURAL — script contains the right pieces
#   (B) BEHAVIORAL — running the script with a held lock emits the
#       defer event and skips the rebase (mock-gh + mock-flock)
#
# Behavioral test uses real flock so it depends on the host having
# util-linux (Linux) or macOS flock built-in (>= Catalina).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

fail() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[PASS] $1"; }

SCRIPT="scripts/coord/pr-auto-rebase.sh"

# ---- A. STRUCTURAL ----

# 1. flock is invoked
grep -q 'flock -n' "$SCRIPT" || fail "missing flock -n command"
pass "flock invoked"

# 2. Lock path is per-branch
grep -q 'rebase-.*\.lock\|rebase-${BRANCH' "$SCRIPT" \
    || fail "missing per-branch lock file path"
pass "per-branch lock file path present"

# 3. Defer event kind emitted
grep -q 'pr_auto_rebase_deferred_for_operator' "$SCRIPT" \
    || fail "missing pr_auto_rebase_deferred_for_operator emit"
pass "pr_auto_rebase_deferred_for_operator event emit"

# 4. CHUMP_PR_AUTO_REBASE_NO_LOCK escape hatch
grep -q 'CHUMP_PR_AUTO_REBASE_NO_LOCK' "$SCRIPT" \
    || fail "missing CHUMP_PR_AUTO_REBASE_NO_LOCK escape hatch"
pass "CHUMP_PR_AUTO_REBASE_NO_LOCK escape hatch present"

# 5. BRANCH_SAFE sanitization (slashes → underscores)
grep -q 'BRANCH_SAFE.*//\\?/\\?_\|BRANCH//\\?/\\?_' "$SCRIPT" \
    || grep -qE 'BRANCH_SAFE="\$\{BRANCH//' "$SCRIPT" \
    || fail "missing BRANCH_SAFE sanitization for filename use"
pass "BRANCH_SAFE sanitization present"

# 6. DEFERRED counter in summary line
grep -q 'deferred=' "$SCRIPT" \
    || fail "missing deferred= in summary output"
pass "deferred counter in summary"

# 7. bash -n syntax check on the script
bash -n "$SCRIPT" || fail "script has bash syntax errors"
pass "bash -n syntax check passes"

# ---- B. BEHAVIORAL ----

# Stand up a tiny mock environment that can run pr-auto-rebase.sh
# without actually touching gh or git remotes.

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Set up fake repo with .chump-locks dir
mkdir -p "$TMP/.chump-locks" "$TMP/scripts/coord"
cp "$SCRIPT" "$TMP/scripts/coord/pr-auto-rebase.sh"
chmod +x "$TMP/scripts/coord/pr-auto-rebase.sh"

# Mock gh as a shell function exported to subprocesses via wrapper.
# Easier: write a fake gh into a tmp PATH dir.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        echo '[{"number":99999,"mergeStateStatus":"DIRTY","autoMergeRequest":{"id":"x"}}]'
        ;;
    "pr view")
        # Return a fake branch name
        echo 'chump/fake-branch-for-test'
        ;;
    *)
        echo "(fake gh ignoring: $*)" >&2
        ;;
esac
exit 0
GH_EOF
chmod +x "$TMP/bin/gh"

# Test: hold lock on the target branch and assert defer fires.
LOCK="$TMP/.chump-locks/rebase-chump_fake-branch-for-test.lock"
touch "$LOCK"

# Acquire the lock in a held subshell, then run the script — expect defer.
echo "Behavioral test: hold lock + run script, expect defer event"
(
    exec 8>"$LOCK"
    flock -n 8 || { echo "[skip-behavioral] test host doesn't have functional flock"; exit 99; }
    # Background subshell sleeps with lock held; meanwhile we run the script.
    (sleep 5; exec 8>&-) &
    LOCK_HOLDER_PID=$!
    # Run script in TMP with our fake gh on PATH
    cd "$TMP"
    PATH="$TMP/bin:$PATH" REPO_ROOT="$TMP" bash scripts/coord/pr-auto-rebase.sh 2>&1 | tee "$TMP/script-out.log"
    wait $LOCK_HOLDER_PID 2>/dev/null || true
) || behavioral_rc=$?

if [[ "${behavioral_rc:-0}" -eq 99 ]]; then
    echo "[SKIP] behavioral test: no functional flock on this host"
else
    if grep -q 'pr_auto_rebase_deferred_for_operator\|DEFER #99999' "$TMP/script-out.log" 2>/dev/null \
        || grep -q 'pr_auto_rebase_deferred_for_operator' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
        pass "behavioral: lock held → defer fired"
    else
        echo "[FAIL] behavioral: expected pr_auto_rebase_deferred_for_operator OR 'DEFER' in output"
        echo "--- script-out.log ---"
        cat "$TMP/script-out.log" 2>/dev/null || true
        echo "--- ambient.jsonl ---"
        cat "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null || true
        exit 1
    fi
fi

echo
echo "[OK] all INFRA-1974 rebase-coordination cases passed"
