#!/usr/bin/env bash
# test-bot-merge-gap-auto-derive.sh — INFRA-237 unit tests.
#
# Verifies the new --gap auto-derive path added to scripts/coord/bot-merge.sh:
#
#   (1) Branch like 'chump/infra-127-reflection-e2e' auto-derives INFRA-127
#   (2) Branch like 'claude/research-026-impl' auto-derives RESEARCH-026
#   (3) Branch like 'chore/file-infra-243' auto-derives INFRA-243
#   (4) Multi-gap branch 'chump/infra-100-and-infra-200' auto-derives both
#   (5) Non-gap branch with no extractable ID errors out (exit 2)
#   (6) Explicit --gap none suppresses auto-derive AND leaves GAP_IDS empty
#       (no error, no spurious DERIVE message)
#   (7) Explicit --gap takes precedence over auto-derive
#
# We don't run bot-merge.sh end-to-end (it'd try to push, run cargo, etc.).
# Instead we extract the auto-derive block into a sourced subshell and verify
# the resulting GAP_IDS array.
#
# Run: ./scripts/ci/test-bot-merge-gap-auto-derive.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-237 bot-merge.sh --gap auto-derive unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

if [ ! -x "$BOT_MERGE" ]; then
    echo "FATAL: bot-merge.sh not executable: $BOT_MERGE"
    exit 2
fi

# Extract just the auto-derive block (between the case statement done and
# the SCRIPT_DIR= line). Run it in a subshell with a fake $1=branch_name
# and capture the resulting GAP_IDS.
derive_test() {
    local branch="$1"
    shift
    (
        # Mimic what bot-merge.sh sees after arg parsing.
        GAP_IDS=()
        # Apply any explicit --gap args from remaining positional args.
        local NEXT=0
        if [[ $# -gt 0 ]]; then
            for arg in "$@"; do
                if [[ $NEXT -eq 1 ]]; then
                    for gid in $arg; do GAP_IDS+=("$gid"); done
                    NEXT=0
                    continue
                fi
                case "$arg" in
                    --gap) NEXT=1 ;;
                esac
            done
        fi

        # Stub git symbolic-ref to return the test branch name.
        git() {
            if [[ "$1" == "symbolic-ref" ]]; then
                echo "$branch"
                return 0
            fi
            command git "$@"
        }
        export -f git

        # Source the auto-derive block from bot-merge.sh. Pull the lines
        # between "if [[ \${#GAP_IDS[@]} -eq 0 ]]; then" and the "SCRIPT_DIR="
        # marker.
        block=$(awk '/^if \[\[ \${#GAP_IDS\[@\]} -eq 0 \]\]; then/,/^SCRIPT_DIR=/' "$BOT_MERGE" | sed '$d')
        eval "$block" 2>/dev/null

        # Print final GAP_IDS, one per line, prefixed for parsing.
        if [[ ${#GAP_IDS[@]} -gt 0 ]]; then
            for gid in "${GAP_IDS[@]}"; do
                echo "GID:$gid"
            done
        fi
    )
}

assert_derived() {
    local label="$1" branch="$2" expected="$3"
    shift 3
    local out
    out=$(derive_test "$branch" "$@" 2>&1 | grep -E '^GID:' | sed 's/^GID://' | sort | tr '\n' ' ' | sed 's/ $//' || true)
    local exp_sorted
    exp_sorted=$(echo "$expected" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
    if [[ "$out" == "$exp_sorted" ]]; then
        ok "$label: derived [$out]"
    else
        fail "$label: expected [$exp_sorted], got [$out]"
    fi
}

# ── Test 1: chump/<lowercase-id> auto-derive ────────────────────────────────
assert_derived "Test 1 chump/infra-127" \
    "chump/infra-127-reflection-e2e" "INFRA-127"

# ── Test 2: claude/<lowercase-id> auto-derive ───────────────────────────────
assert_derived "Test 2 claude/research-026" \
    "claude/research-026-impl" "RESEARCH-026"

# ── Test 3: chore/file-<id> auto-derive ─────────────────────────────────────
assert_derived "Test 3 chore/file-infra-243" \
    "chore/file-infra-243" "INFRA-243"

# ── Test 4: multi-gap branch ────────────────────────────────────────────────
assert_derived "Test 4 multi-gap chump/infra-100-and-infra-200" \
    "chump/infra-100-and-infra-200" "INFRA-100 INFRA-200"

# ── Test 5: non-gap branch errors out ───────────────────────────────────────
echo "--- Test 5: non-gap branch errors out (exit 2) ---"
set +e
out=$(derive_test "chump/random-cleanup-no-id-here" 2>&1)
exit_code=$?
set -e
if [[ "$exit_code" == "2" ]] || echo "$out" | grep -q "could not auto-derive"; then
    ok "Test 5: non-gap branch produced expected error (exit=$exit_code)"
else
    fail "Test 5: expected error / exit 2, got exit=$exit_code out=[$out]"
fi

# ── Test 6: explicit --gap none suppresses ──────────────────────────────────
assert_derived "Test 6 explicit --gap none" \
    "chump/random-cleanup-no-id-here" "" --gap none

# ── Test 7: explicit --gap overrides any branch-derive ──────────────────────
assert_derived "Test 7 explicit --gap precedence" \
    "chump/infra-127-reflection-e2e" "INFRA-999" --gap INFRA-999

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
