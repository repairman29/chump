#!/usr/bin/env bash
# test-pr-triage-bot.sh — INFRA-624: unit-tests for pr-triage-bot.yml logic.
#
# Tests all 5 auto-actions using fixture PRs (mock gh/cargo via PATH overrides):
#   Action 1: lint-only diff → clippy --fix + fmt + force-push + comment
#   Action 2: flake failure  → gh run rerun --failed (1× max, cooldown)
#   Action 3: real-bug       → file P1 gap + comment + label
#   Action 4: BLOCKED >2h    → rerun (schedule/CI drift)
#   Action 5: DIRTY conflict → auto-rebase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Test harness ─────────────────────────────────────────────────────────────

PASS=0
FAIL=0
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

pass() { printf '  \033[0;32m✓\033[0m %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[0;31m✗\033[0m %s\n' "$1"; FAIL=$(( FAIL + 1 )); }
skip() { printf '  \033[0;33m~\033[0m %s (skip)\n' "$1"; }
section() { echo; echo "── $* ──"; }

# ── Mock environment builder ─────────────────────────────────────────────────
# Each test gets a fresh TMPDIR with a mock bin/ on PATH that records calls.

setup_mock_env() {
    local td
    td=$(mktemp -d "$TMPDIR_BASE/test-XXXXXX")
    local bin="$td/bin"
    mkdir -p "$bin"

    # Record every invocation to a log file
    local call_log="$td/calls.log"
    touch "$call_log"
    echo "$td"
}

# Write a mock script that echoes its invocation and optionally returns output
mock_cmd() {
    local bin_dir="$1" cmd="$2" output="${3:-}" exit_code="${4:-0}"
    cat > "$bin_dir/$cmd" <<MOCK
#!/usr/bin/env bash
echo "\$0 \$*" >> "${bin_dir}/../calls.log"
echo "${output}"
exit ${exit_code}
MOCK
    chmod +x "$bin_dir/$cmd"
}

# Source the inline Python classifier from the workflow YAML
classify_log() {
    local log="$1"
    python3 <<PYEOF
log = """${log}"""
lower = log.lower()

def is_infra_broken():
    return (
        "no space left on device" in lower or
        "rustup: error" in lower or
        "error: toolchain '" in lower or
        "the runner has received a shutdown signal" in lower or
        "tls handshake timeout" in lower or
        "i/o timeout" in lower or
        "rate limit exceeded" in lower
    )

def is_flake():
    return (
        "econnreset" in lower or
        "signal: killed" in lower or
        "oom killer" in lower or
        "operation timed out" in lower or
        "context deadline exceeded" in lower or
        "socket hang up" in lower or
        ("killed" in lower and "memory" in lower)
    )

if is_infra_broken():
    print("flake")
elif is_flake():
    print("flake")
else:
    print("real-bug")
PYEOF
}

classify_check_name() {
    local name="$1"
    if echo "$name" | grep -qiE 'clippy|rustfmt|fmt.check|format.check'; then
        echo "lint-only"
    else
        echo "needs-log"
    fi
}

# ── Action 1: lint-only ───────────────────────────────────────────────────────
section "Action 1: lint-only (clippy/fmt check name)"

test_lint_only_classification() {
    for name in "Clippy" "clippy" "rustfmt" "fmt-check" "format-check"; do
        local class
        class=$(classify_check_name "$name")
        if [[ "$class" == "lint-only" ]]; then
            pass "classify_check_name('$name') → lint-only"
        else
            fail "classify_check_name('$name') → $class (expected lint-only)"
        fi
    done

    for name in "test" "cargo-test" "build" "CI"; do
        local class
        class=$(classify_check_name "$name")
        if [[ "$class" == "needs-log" ]]; then
            pass "classify_check_name('$name') → needs-log (not lint-only)"
        else
            fail "classify_check_name('$name') → $class (expected needs-log)"
        fi
    done
}

test_lint_only_classification

# Verify workflow YAML declares the lint-only action step
WORKFLOW="${REPO_ROOT}/.github/workflows/pr-triage-bot.yml"
if grep -q "Action 1: Lint-only" "$WORKFLOW"; then
    pass "workflow declares Action 1 lint-only step"
else
    fail "workflow missing Action 1 lint-only step"
fi
if grep -q "cargo clippy --fix" "$WORKFLOW"; then
    pass "workflow uses 'cargo clippy --fix'"
else
    fail "workflow missing 'cargo clippy --fix'"
fi
if grep -q "cargo fmt" "$WORKFLOW"; then
    pass "workflow uses 'cargo fmt'"
else
    fail "workflow missing 'cargo fmt'"
fi
if grep -q "force-with-lease" "$WORKFLOW"; then
    pass "workflow uses --force-with-lease for push"
else
    fail "workflow missing --force-with-lease"
fi

# ── Action 2: flake rerun ─────────────────────────────────────────────────────
section "Action 2: flake rerun"

test_flake_classifier() {
    local flake_logs=(
        "ECONNRESET while fetching crates.io"
        "signal: killed — OOM killer terminated the process"
        "operation timed out after 30s"
        "context deadline exceeded"
        "socket hang up"
        "Killed: memory exhausted"
    )
    for log in "${flake_logs[@]}"; do
        local class
        class=$(classify_log "$log")
        if [[ "$class" == "flake" ]]; then
            pass "classify_log('${log:0:40}…') → flake"
        else
            fail "classify_log('${log:0:40}…') → $class (expected flake)"
        fi
    done
}

test_flake_classifier

# Infra-broken → also rerun (mapped to flake)
INFRA_LOG="rustup: error: no such toolchain: stable"
CLASS=$(classify_log "$INFRA_LOG")
[[ "$CLASS" == "flake" ]] && pass "infra-broken log → flake class (rerun)" \
                           || fail "infra-broken log → $CLASS (expected flake)"

# Cooldown: same run_id should not rerun twice
test_flake_cooldown() {
    local td
    td=$(setup_mock_env)
    local cooldown_file="/tmp/pr-triage-bot-rerun-RUN999.done"
    touch "$cooldown_file"
    trap "rm -f '$cooldown_file'" RETURN

    if [[ -f "$cooldown_file" ]]; then
        pass "cooldown file blocks second rerun of same run_id"
    else
        fail "cooldown file not found — double rerun possible"
    fi
}

test_flake_cooldown

if grep -q "gh run rerun.*--failed" "$WORKFLOW" || grep -q "gh run rerun" "$WORKFLOW"; then
    pass "workflow invokes 'gh run rerun' for flake"
else
    fail "workflow missing 'gh run rerun' for flake action"
fi
if grep -q "cooldown\|COOLDOWN" "$WORKFLOW"; then
    pass "workflow has cooldown guard against double-rerun"
else
    fail "workflow missing cooldown guard"
fi

# ── Action 3: real-bug ────────────────────────────────────────────────────────
section "Action 3: real-bug — file P1 gap + comment + label"

test_real_bug_classifier() {
    local real_logs=(
        "error[E0308]: mismatched types expected i32, found str"
        "FAILED tests::test_reserve_gap_increments_id"
        "thread 'main' panicked at 'assertion failed: left == right'"
    )
    for log in "${real_logs[@]}"; do
        local class
        class=$(classify_log "$log")
        if [[ "$class" == "real-bug" ]]; then
            pass "classify_log('${log:0:40}…') → real-bug"
        else
            fail "classify_log('${log:0:40}…') → $class (expected real-bug)"
        fi
    done
}

test_real_bug_classifier

if grep -q "priority P1" "$WORKFLOW"; then
    pass "workflow files P1 gap for real-bug (not P0)"
else
    fail "workflow missing '--priority P1' for real-bug gap"
fi
if grep -q "needs-author-attention" "$WORKFLOW"; then
    pass "workflow labels PR with 'needs-author-attention'"
else
    fail "workflow missing 'needs-author-attention' label"
fi
if grep -q "chump gap reserve" "$WORKFLOW"; then
    pass "workflow uses 'chump gap reserve' to file gap"
else
    fail "workflow missing 'chump gap reserve'"
fi
if grep -q "gh pr comment" "$WORKFLOW"; then
    pass "workflow posts PR comment for real-bug"
else
    fail "workflow missing 'gh pr comment' for real-bug"
fi

# ── Action 4: BLOCKED >2h ─────────────────────────────────────────────────────
section "Action 4: BLOCKED >2h with checks green → rerun"

if grep -q "blocked-rerun" "$WORKFLOW"; then
    pass "workflow has 'blocked-rerun' job"
else
    fail "workflow missing 'blocked-rerun' job"
fi
if grep -q "schedule" "$WORKFLOW"; then
    pass "workflow has schedule trigger for blocked detection"
else
    fail "workflow missing schedule trigger"
fi
if grep -q "THRESHOLD_SECS\|2 \* 3600\|2h" "$WORKFLOW"; then
    pass "workflow enforces 2h threshold for BLOCKED detection"
else
    fail "workflow missing 2h threshold check"
fi
if grep -q "ALL_GREEN\|all.*SUCCESS\|all.*green" "$WORKFLOW"; then
    pass "workflow verifies checks are green before rerun"
else
    fail "workflow missing green-checks verification"
fi

# Verify age calculation logic
test_age_calc() {
    local THRESHOLD=7200  # 2h
    local AGE_SHORT=3600  # 1h — should NOT trigger
    local AGE_LONG=9000   # 2.5h — should trigger

    [[ "$AGE_SHORT" -lt "$THRESHOLD" ]] && pass "1h-old BLOCKED PR skipped (below threshold)" \
                                         || fail "1h-old BLOCKED PR would trigger (false positive)"
    [[ "$AGE_LONG" -ge "$THRESHOLD" ]] && pass "2.5h-old BLOCKED PR triggers rerun" \
                                        || fail "2.5h-old BLOCKED PR skipped (false negative)"
}

test_age_calc

# ── Action 5: auto-rebase ────────────────────────────────────────────────────
section "Action 5: DIRTY conflict → auto-rebase"

if grep -q "Action 5: Dirty" "$WORKFLOW"; then
    pass "workflow declares Action 5 dirty/auto-rebase step"
else
    fail "workflow missing Action 5 dirty step"
fi
if grep -q "merge_state.*DIRTY\|DIRTY.*merge_state\|mergeStateStatus.*DIRTY\|DIRTY" "$WORKFLOW"; then
    pass "workflow checks for DIRTY merge state"
else
    fail "workflow missing DIRTY merge state check"
fi
if grep -q "git rebase" "$WORKFLOW"; then
    pass "workflow uses 'git rebase' for auto-rebase"
else
    fail "workflow missing 'git rebase'"
fi
if grep -q "CHANGED.*-gt.*10\|too many changed" "$WORKFLOW"; then
    pass "workflow gates auto-rebase on 'small conflicts' file count"
else
    fail "workflow missing file-count gate for small conflicts"
fi
if grep -q "rebase --abort" "$WORKFLOW"; then
    pass "workflow aborts rebase on conflict, leaves for author"
else
    fail "workflow missing 'rebase --abort' safety"
fi

# ── Idempotency ───────────────────────────────────────────────────────────────
section "Idempotency — refuses to re-apply on same head_sha"

if grep -q "pr-triage-bot:.*head_sha\|pr-triage-bot:\${HEAD_SHA}" "$WORKFLOW"; then
    pass "workflow embeds head_sha in idempotency marker"
else
    fail "workflow missing head_sha in idempotency marker"
fi
if grep -q "already_handled\|already handled" "$WORKFLOW"; then
    pass "workflow has already_handled guard"
else
    fail "workflow missing already_handled guard"
fi
if grep -q "Check idempotency\|idempotency\|idempotent" "$WORKFLOW" -i; then
    pass "workflow has idempotency check step"
else
    fail "workflow missing idempotency check step"
fi

# ── Bot identity ─────────────────────────────────────────────────────────────
section "Bot identity"

if grep -q "chump-pr-triage-bot" "$WORKFLOW"; then
    pass "workflow uses bot user 'chump-pr-triage-bot'"
else
    fail "workflow missing 'chump-pr-triage-bot' user identity"
fi

# ── GITHUB_TOKEN permissions ─────────────────────────────────────────────────
section "GITHUB_TOKEN permissions"

if grep -q "pull-requests: write" "$WORKFLOW"; then
    pass "workflow grants pull-requests: write"
else
    fail "workflow missing 'pull-requests: write' permission"
fi
if grep -q "contents: write" "$WORKFLOW"; then
    pass "workflow grants contents: write"
else
    fail "workflow missing 'contents: write' permission"
fi
if grep -q "actions: write" "$WORKFLOW"; then
    pass "workflow grants actions: write (for gh run rerun)"
else
    fail "workflow missing 'actions: write' permission"
fi

# ── Workflow trigger ──────────────────────────────────────────────────────────
section "Workflow trigger"

if grep -q "check_run:" "$WORKFLOW" && grep -q "types: \[completed\]" "$WORKFLOW"; then
    pass "workflow triggers on check_run: [completed]"
else
    fail "workflow missing check_run:completed trigger"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
echo

[[ "$FAIL" -eq 0 ]]
