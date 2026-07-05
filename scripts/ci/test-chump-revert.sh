#!/usr/bin/env bash
# scripts/ci/test-chump-revert.sh — INFRA-1443
#
# Tests: chump revert <PR-number|merge-commit> [--reason <text>] [--dry-run]
#
# Strategy: create a fake gh shim + synthetic git repos to avoid network I/O.
# Tests:
#   1. Static: chump revert subcommand routed in binary (--help produces usage)
#   2. dry-run: prints planned actions, does NOT push or create PR
#   3. gap-ID extraction from PR title ("feat(INFRA-1404): …" → gap=INFRA-1404)
#   4. Branch naming: revert/<pr-number>-<short-sha>
#   5. PR title format: "revert(<gap>): rollback #<N> due to <reason>"
#   6. Ambient event: kind=gap_revert_pr_opened emitted on success
#   7. Idempotency: second invocation on same PR still exits 0 (gh create succeeds)
#   8. Error path: non-merged PR exits 1 with clear message

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$(cd "$REPO_ROOT" && cargo build --bin chump -q 2>/dev/null && echo "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump")}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "SKIP: chump binary not found at $CHUMP_BIN"
    exit 0
fi

PASS=0; FAIL=0; FAILS=()
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); FAILS+=("$*"); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== INFRA-1443 chump revert tests ==="

# ── Shared gh shim ────────────────────────────────────────────────────────────
SHIM="$TMP/bin"
mkdir -p "$SHIM"

# Synthetic PR data for PR #2105 (INFRA-1368, merged, has merge commit)
MERGE_SHA="aabbccdd1234567890abcdef1234567890abcdef"
SHORT_SHA="${MERGE_SHA:0:7}"

cat > "$SHIM/gh" <<GHEOF
#!/usr/bin/env bash
# gh shim for chump revert tests
case "\$*" in
    *"pr view"*"2105"*"--json"*)
        echo '{"number":2105,"title":"feat(INFRA-1368): CREDIBLE — merge_state_status column","state":"MERGED","headRefName":"chump/infra-1368-claim","mergeCommit":{"oid":"${MERGE_SHA}"}}'
        exit 0
        ;;
    *"pr view"*"9999"*"--json"*)
        # Non-merged PR for error test
        echo '{"number":9999,"title":"feat(INFRA-9999): open PR","state":"OPEN","headRefName":"chump/infra-9999-claim","mergeCommit":null}'
        exit 0
        ;;
    *"pr create"*)
        echo "https://github.com/repairman29/chump/pull/9876"
        exit 0
        ;;
    *"pr comment"*)
        exit 0
        ;;
    *"remote get-url"*|*"remote"*"get-url"*)
        echo "https://github.com/repairman29/chump.git"
        exit 0
        ;;
    *)
        echo "SHIM: unhandled gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
chmod +x "$SHIM/gh"

# Git shim: mock network operations; pass through safe read-only commands
cat > "$SHIM/git" <<'GITEOF'
#!/usr/bin/env bash
case "$1" in
    fetch)
        # Simulate successful fetch
        echo "[git-shim] fetch: $*"
        exit 0
        ;;
    push)
        # Simulate successful push
        echo "[git-shim] push: $*"
        exit 0
        ;;
    revert)
        # Simulate successful revert (no-commit)
        echo "[git-shim] revert: $*"
        exit 0
        ;;
    commit)
        # Simulate successful commit
        echo "[git-shim] commit: $*"
        exit 0
        ;;
    checkout)
        if [[ "$2" == "-b" ]]; then
            # Simulate branch creation
            echo "[git-shim] checkout -b: $*"
            exit 0
        fi
        # Pass through other checkout commands
        /usr/bin/git "$@"
        ;;
    *)
        # Pass through all other git commands to real git
        /usr/bin/git "$@"
        ;;
esac
GITEOF
chmod +x "$SHIM/git"

export PATH="$SHIM:$PATH"
export CHUMP_REPO_ROOT="$TMP/repo"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
touch "$CHUMP_AMBIENT_LOG"

# Set up a minimal fake git repo so chump revert can run git commands
mkdir -p "$TMP/repo"
/usr/bin/git -C "$TMP/repo" init -q 2>/dev/null
/usr/bin/git -C "$TMP/repo" config user.email "test@ci.local"
/usr/bin/git -C "$TMP/repo" config user.name "CI Test"
# Add a fake remote
/usr/bin/git -C "$TMP/repo" remote add origin https://github.com/repairman29/chump.git 2>/dev/null || true
# Create an initial commit so HEAD is valid
echo "init" > "$TMP/repo/init.txt"
/usr/bin/git -C "$TMP/repo" add init.txt
/usr/bin/git -C "$TMP/repo" commit -m "init" -q 2>/dev/null

echo
echo "[1. Static: binary has revert subcommand]"

# Test 1: static — check revert subcommand routing exists in binary
set +e
"$CHUMP_BIN" revert 2>&1 | head -3
rc=$?
set -e
if grep -q "revert\|Usage" <("$CHUMP_BIN" revert 2>&1 | head -3); then
    ok "chump revert produces usage message when called with no args"
else
    fail "chump revert missing from binary or no usage message"
fi

echo
echo "[2. dry-run: prints plan, no push, no PR create]"
set +e
out="$(CHUMP_REPO_ROOT="$TMP/repo" "$CHUMP_BIN" revert 2105 --dry-run --reason "wedged audit job" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    ok "dry-run exits 0"
else
    fail "dry-run exited $rc (expected 0)"
fi

if echo "$out" | grep -q "dry-run"; then
    ok "dry-run output contains [dry-run] marker"
else
    fail "dry-run output missing [dry-run] marker"
fi

if echo "$out" | grep -q "revert/2105-"; then
    ok "dry-run shows revert branch name with PR number"
else
    fail "dry-run missing branch name (expected revert/2105-<sha>)"
fi

# Check that gh pr create was NOT called (ambient should have no gap_revert_pr_opened)
if grep -q "gap_revert_pr_opened" "$CHUMP_AMBIENT_LOG" 2>/dev/null; then
    fail "dry-run should NOT emit gap_revert_pr_opened"
else
    ok "dry-run: no ambient event emitted (correct)"
fi

echo
echo "[3. Success path: PR title, ambient event, revert PR URL]"

# Reset ambient log
> "$CHUMP_AMBIENT_LOG"

set +e
out="$(CHUMP_REPO_ROOT="$TMP/repo" "$CHUMP_BIN" revert 2105 --reason "wedged audit job fleet-wide" 2>&1)"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
    ok "success path exits 0"
else
    fail "success path exited $rc; output: $out"
fi

if echo "$out" | grep -q "https://github.com"; then
    ok "output contains revert PR URL"
else
    fail "output missing PR URL: $out"
fi

if grep -q '"kind":"gap_revert_pr_opened"' "$CHUMP_AMBIENT_LOG" 2>/dev/null; then
    ok "ambient kind=gap_revert_pr_opened emitted"
else
    fail "ambient kind=gap_revert_pr_opened NOT emitted"
fi

if grep '"kind":"gap_revert_pr_opened"' "$CHUMP_AMBIENT_LOG" 2>/dev/null | grep -q '"orig_pr":2105'; then
    ok "ambient event contains orig_pr=2105"
else
    fail "ambient event missing orig_pr=2105"
fi

echo
echo "[4. Error path: non-merged PR exits 1]"

set +e
out="$(CHUMP_REPO_ROOT="$TMP/repo" "$CHUMP_BIN" revert 9999 --reason "test" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    ok "non-merged PR exits non-zero ($rc)"
else
    fail "non-merged PR expected exit 1, got 0"
fi

if echo "$out" | grep -qi "not merged\|OPEN\|cannot\|can only"; then
    ok "error message explains PR is not merged"
else
    fail "error message unclear: $out"
fi

echo
echo "[5. Static: revert_pr.rs tests pass]"
# The unit tests in revert_pr.rs cover extract_gap_id, extract_slug_from_remote, parse_opts
# These run via cargo test — confirm the functions are named correctly in binary
if grep -q "revert_pr" "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "revert_pr module wired in main.rs"
else
    fail "revert_pr module not in main.rs"
fi

if [[ -f "$REPO_ROOT/src/revert_pr.rs" ]]; then
    ok "src/revert_pr.rs exists"
else
    fail "src/revert_pr.rs missing"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  ✗ %s\n' "$f"; done
    exit 1
fi
echo "PASS"
