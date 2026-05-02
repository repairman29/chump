#!/usr/bin/env bash
# test-bot-merge-requires-gap.sh — INFRA-237 contract test.
#
# Asserts the bot-merge.sh --gap contract: when invoked WITHOUT --gap and the
# current branch name does NOT encode a gap ID, the script must exit non-zero
# with a clear diagnostic that points at the three valid remediation paths
# (pass --gap, rename branch, or pass --gap none for genuine non-gap PRs).
#
# Why this exists: prior to INFRA-237, --gap was optional and many PRs shipped
# without it. Missing --gap silently bypassed the INFRA-154 auto-close path,
# leaving gaps in `status:open` even after their implementing PR landed.
# INFRA-237 made --gap effectively-required: either passed explicitly,
# auto-derived from a canonical branch name, or explicitly suppressed via
# `--gap none`. This test pins that contract.
#
# Run: ./scripts/ci/test-bot-merge-requires-gap.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-237 bot-merge.sh requires --gap contract test ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

if [ ! -x "$BOT_MERGE" ]; then
    echo "FATAL: bot-merge.sh not executable: $BOT_MERGE"
    exit 2
fi

# Helper: run the auto-derive block with a stubbed branch name and capture
# exit code + stderr. We isolate the block so we don't have to mock cargo,
# git push, gh, etc.
run_derive_block() {
    local branch="$1"
    shift
    (
        set +e
        GAP_IDS=()
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

        # Stub git symbolic-ref to return our test branch name.
        git() {
            if [[ "$1" == "symbolic-ref" ]]; then
                echo "$branch"
                return 0
            fi
            command git "$@"
        }
        export -f git

        # Source just the auto-derive block (between the GAP_IDS-empty guard
        # and the SCRIPT_DIR= line).
        block=$(awk '/^if \[\[ \${#GAP_IDS\[@\]} -eq 0 \]\]; then/,/^SCRIPT_DIR=/' "$BOT_MERGE" | sed '$d')
        eval "$block"
    )
}

# ── Test 1: branch with no gap ID and no --gap → exit non-zero ─────────────
echo "--- Test 1: --gap-less invocation on non-gap branch must fail ---"
set +e
out=$(run_derive_block "chump/random-cleanup-no-id-here" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    ok "Test 1: exited non-zero (rc=$rc) as expected"
else
    fail "Test 1: expected non-zero exit; got rc=$rc out=[$out]"
fi

# ── Test 2: error message is clear and actionable ──────────────────────────
echo "--- Test 2: error message names the remediation paths ---"
if echo "$out" | grep -q "could not auto-derive"; then
    ok "Test 2a: error mentions 'could not auto-derive'"
else
    fail "Test 2a: error missing 'could not auto-derive' phrase: [$out]"
fi
if echo "$out" | grep -q -- "--gap"; then
    ok "Test 2b: error mentions --gap remediation"
else
    fail "Test 2b: error missing --gap remediation hint"
fi
if echo "$out" | grep -qE "(rename|branch.*name)"; then
    ok "Test 2c: error mentions branch-rename remediation"
else
    fail "Test 2c: error missing branch-rename remediation hint"
fi
if echo "$out" | grep -q -- "--gap none"; then
    ok "Test 2d: error mentions --gap none escape hatch"
else
    fail "Test 2d: error missing --gap none escape hatch"
fi

# ── Test 3: explicit --gap none on non-gap branch is accepted ──────────────
echo "--- Test 3: --gap none suppresses requirement on non-gap branch ---"
set +e
out_none=$(run_derive_block "chump/random-cleanup-no-id-here" --gap none 2>&1)
rc_none=$?
set -e
if [[ $rc_none -eq 0 ]]; then
    ok "Test 3: --gap none accepted (rc=$rc_none)"
else
    fail "Test 3: --gap none should succeed; got rc=$rc_none out=[$out_none]"
fi

# ── Test 4: canonical chump/<id> branch auto-derives without --gap ─────────
echo "--- Test 4: canonical branch name satisfies --gap requirement ---"
set +e
out_derived=$(run_derive_block "chump/infra-237-some-thing" 2>&1)
rc_derived=$?
set -e
if [[ $rc_derived -eq 0 ]] && echo "$out_derived" | grep -q "INFRA-237"; then
    ok "Test 4: canonical branch auto-derived (rc=$rc_derived)"
else
    fail "Test 4: canonical branch should succeed and mention INFRA-237; rc=$rc_derived out=[$out_derived]"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
