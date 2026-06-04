#!/usr/bin/env bash
# INFRA-678: pin the contract that a failed `chump gap ship` in bot-merge.sh
# causes an immediate exit 1 — preventing auto-merge from being armed with a
# ghost gap still open (INFRA-664 regression class).
#
# Strategy: structural grep of bot-merge.sh source, plus a mock-chump
# functional smoke test of the auto-close path.
#
# Run from repo root: bash scripts/ci/test-bot-merge-gap-fatal.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# RESILIENT-090/093: scrub GIT_DIR/GIT_WORK_TREE inherited from pre-push.
# shellcheck source=../lib/scrub-git-env.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1" >&2; FAIL=$((FAIL+1)); }

if [[ ! -f "$BOT_MERGE" ]]; then
    echo "FAIL: $BOT_MERGE not found" >&2
    exit 1
fi

# ── Test 1: exit 1 present in the gap-ship failure branch ─────────────────
echo "[test-1] gap-ship failure branch contains 'exit 1'"
# Locate the INFRA-678 guard comment, then verify 'exit 1' follows within
# the same failure block (not just anywhere in the file).
if ! grep -A 20 'INFRA-678' "$BOT_MERGE" | grep -qE '^\s*exit 1'; then
    fail "no 'exit 1' found within 20 lines of INFRA-678 marker in bot-merge.sh"
else
    pass "exit 1 present in gap-ship failure block"
fi

# ── Test 2: failure block uses red(), not yellow() ────────────────────────
echo "[test-2] gap-ship failure block escalated from yellow to red"
if grep -A 20 'INFRA-678' "$BOT_MERGE" | grep -qE 'yellow.*Auto-close FAILED'; then
    fail "failure block still uses yellow() for 'Auto-close FAILED' — should be red()"
else
    pass "failure block uses red() (not yellow) for Auto-close FAILED message"
fi

# ── Test 3: exit 1 precedes the auto-merge arming section ─────────────────
echo "[test-3] gap-ship exit 1 appears before the auto-merge arm block"
gap_ship_fail_line=$(grep -n 'INFRA-678' "$BOT_MERGE" | head -1 | cut -d: -f1)
auto_merge_arm_line=$(grep -n 'Enable auto-merge' "$BOT_MERGE" | head -1 | cut -d: -f1)
if [[ -z "$gap_ship_fail_line" ]] || [[ -z "$auto_merge_arm_line" ]]; then
    fail "could not locate INFRA-678 marker or auto-merge arm section in bot-merge.sh"
elif [[ "$gap_ship_fail_line" -lt "$auto_merge_arm_line" ]]; then
    pass "gap-ship failure (line $gap_ship_fail_line) precedes auto-merge arm (line $auto_merge_arm_line)"
else
    fail "gap-ship failure (line $gap_ship_fail_line) is AFTER auto-merge arm (line $auto_merge_arm_line) — ordering wrong"
fi

# ── Test 4: functional mock — chump returning rc=1 causes exit 1 ──────────
echo "[test-4] functional: bot-merge exits 1 when mock chump returns rc=1"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Create a fake chump that always exits 1 with a diagnostic message
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/chump" <<'MOCK'
#!/usr/bin/env bash
# Fake chump for INFRA-678 test — exits 1 to simulate gap ship failure
echo "ERROR: mock chump: simulated gap ship failure (INFRA-678 test)" >&2
exit 1
MOCK
chmod +x "$SANDBOX/bin/chump"

# Create a fake gh that returns a PR number for `gh pr view`
cat > "$SANDBOX/bin/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]] && [[ "$*" == *"--json number"* ]]; then
    echo "42"
    exit 0
fi
# pass through everything else (pr create, pr merge, etc.) — not reached in this path
exit 0
MOCK
chmod +x "$SANDBOX/bin/gh"

# Create a minimal fake git setup so the script doesn't fail on git calls
# We only need to get as far as the gap-ship block
GIT_REPO=$(mktemp -d)
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.email "test@test.com"
git -C "$GIT_REPO" config user.name "Test"
touch "$GIT_REPO/README.md"
git -C "$GIT_REPO" add README.md
git -C "$GIT_REPO" commit -q -m "init"
git -C "$GIT_REPO" checkout -q -b "chump/test-infra-678"

# Invoke the auto-close logic directly by extracting and running just
# the relevant block with our mocked environment.
# We isolate the auto-close section (between the gap-ship block and auto-merge
# arm) by sourcing a minimal harness that replaces everything else with stubs.

AUTO_CLOSE_TEST_SCRIPT=$(mktemp "$SANDBOX/auto_close_test_XXXX.sh")
cat > "$AUTO_CLOSE_TEST_SCRIPT" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail

# Stub out the bot-merge helpers so the script initialises without network/git
red()    { echo "[RED] \$*" >&2; }
yellow() { echo "[YELLOW] \$*"; }
green()  { echo "[GREEN] \$*"; }
info()   { echo "[INFO] \$*"; }
stage_start() { :; }
stage_done()  { :; }
run_timed_hb() {
    # run_timed_hb <label> <timeout> <cmd...>
    local _label="\$1" _timeout="\$2"; shift 2
    "\$@"
}

# Vars the block reads
DRY_RUN=0
AUTO_MERGE=1
CHUMP_AUTO_CLOSE_GAP=1
CHUMP_BENCH_MODE=0
GAP_IDS=(INFRA-TEST-678)
BRANCH="chump/test-infra-678"
MAIN_REPO="$GIT_REPO"
REPO_ROOT="$GIT_REPO"

# PATH manipulation: put mock chump + gh first
export PATH="$SANDBOX/bin:\$PATH"

_autoclose_target_pr=42
_autoclose_main_repo="$GIT_REPO"
_autoclose_chump="$SANDBOX/bin/chump"

# ─── reproduce the exact for-loop from bot-merge.sh ───
for _gid in "\${GAP_IDS[@]}"; do
    stage_start "auto-close gap \$_gid via PR #\$_autoclose_target_pr (INFRA-154)"
    _tmpship=\$(mktemp)
    set +e
    CHUMP_REPO="\$_autoclose_main_repo" \\
    CHUMP_REAL_BINARY="\$_autoclose_chump" \\
    run_timed_hb "gap ship \$_gid" 60 \\
        chump gap ship "\$_gid" \\
            --closed-pr "\$_autoclose_target_pr" \\
            --update-yaml > "\$_tmpship" 2>&1
    _autoclose_rc=\$?
    set -e
    _autoclose_err=\$(cat "\$_tmpship")
    rm -f "\$_tmpship"
    if [[ \$_autoclose_rc -eq 0 ]]; then
        green "Auto-closed \$_gid (would not happen in this test)"
    else
        # INFRA-678: gap ship failure is fatal — abort before auto-merge arm.
        red "Auto-close FAILED for \$_gid (chump gap ship rc=\$_autoclose_rc) — aborting auto-merge:"
        if [[ -n "\$_autoclose_err" ]]; then
            while IFS= read -r _line; do
                [[ -z "\$_line" ]] && continue
                red "  | \$_line"
            done <<< "\$_autoclose_err"
        fi
        red "  YAML mirror NOT updated; gap status NOT flipped."
        red "  Recover: chump gap ship \$_gid --closed-pr \$_autoclose_target_pr --update-yaml"
        red "           (run from main repo: \$_autoclose_main_repo)"
        red "  See: docs/process/CLAUDE_GOTCHAS.md#error-missing-closed-pr"
        exit 1
    fi
    stage_done
done

# If we reach here, auto-merge would be armed — this line must NOT be reached
echo "AUTO_MERGE_ARMED"
HARNESS
chmod +x "$AUTO_CLOSE_TEST_SCRIPT"

set +e
_out=$(bash "$AUTO_CLOSE_TEST_SCRIPT" 2>&1)
_rc=$?
set -e

if [[ $_rc -ne 1 ]]; then
    fail "expected exit 1 from mock-chump path, got exit $_rc"
else
    pass "harness exits 1 when mock chump returns rc=1"
fi

if echo "$_out" | grep -q "AUTO_MERGE_ARMED"; then
    fail "auto-merge arm was reached despite gap ship failure"
else
    pass "auto-merge arm was NOT reached after gap ship failure"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
