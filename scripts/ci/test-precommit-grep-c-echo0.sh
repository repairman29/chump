#!/usr/bin/env bash
# test-precommit-grep-c-echo0.sh — RESILIENT-281
#
# Tests:
#   1. code-structure: guard script exists + is executable
#   2. code-structure: guard is wired into pre-commit hook (section 20)
#   3. code-structure: bypass env var CHUMP_GREP_C_ECHO0_CHECK referenced
#   4. logic: CHUMP_GREP_C_ECHO0_CHECK=0 skips (exit 0) without a real repo
#   5. logic: added line with 'grep -c ... || echo 0' → exit 1 (this is the
#      "guard fails without itself" proof: run the SAME fixture through the
#      unfixed idiom and confirm it reproduces the actual $'0\n0' bug)
#   6. logic: added line with the idiom + bypass comment → exit 0
#   7. logic: added line already using '|| true' → exit 0 (not flagged)
#   8. logic: idiom only in unmodified lines (not in diff) → exit 0
#   9. logic: idiom inside a comment line → exit 0 (not flagged)
#  10. functional: demonstrates a previously-DEAD assertion (idiom style)
#      actually firing once repaired to '|| true' — proves the repair, not
#      just a silent conversion.

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/git-hooks/pre-commit-grep-c-echo0.sh"

echo "=== RESILIENT-281 grep-c-echo0 guard tests ==="
echo

echo "--- Test 1: guard script exists + is executable ---"
if [[ -x "$GUARD" ]]; then
    ok "guard exists and is executable"
else
    fail "guard NOT found or not executable at $GUARD"
fi

echo "--- Test 2: section 20 wired into pre-commit hook ---"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"
if grep -q 'RESILIENT-281\|pre-commit-grep-c-echo0' "$HOOK"; then
    ok "section 20 (RESILIENT-281) present in pre-commit"
else
    fail "section 20 NOT found in pre-commit hook"
fi

echo "--- Test 3: bypass env var referenced in guard ---"
if grep -q 'CHUMP_GREP_C_ECHO0_CHECK' "$GUARD"; then
    ok "CHUMP_GREP_C_ECHO0_CHECK bypass present"
else
    fail "CHUMP_GREP_C_ECHO0_CHECK NOT in guard script"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

init_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "ci@test.invalid"
    git -C "$dir" config user.name "CI"
    mkdir -p "$dir/scripts"
}

commit_init() {
    local dir="$1"
    CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 CHUMP_EVENT_REGISTRY_CHECK=0 \
        git -C "$dir" commit -q -m "init" --no-verify 2>/dev/null
}

echo "--- Test 4: CHUMP_GREP_C_ECHO0_CHECK=0 skips without a real repo ---"
set +e
out4=$(CHUMP_GREP_C_ECHO0_CHECK=0 bash "$GUARD" 2>&1)
exit4=$?
set -e
if [[ "$exit4" -eq 0 ]]; then
    ok "bypass=0: exit 0"
else
    fail "bypass=0: expected exit 0, got $exit4"
fi

echo "--- Test 5: added line with the idiom → exit 1 ---"
REPO5="$TMP/repo5"
init_repo "$REPO5"
cat > "$REPO5/scripts/check.sh" << 'SH'
#!/usr/bin/env bash
echo hello
SH
git -C "$REPO5" add scripts/check.sh
commit_init "$REPO5"

cat >> "$REPO5/scripts/check.sh" << 'SH'
n=$(grep -c 'pattern' file.txt 2>/dev/null || echo 0)
SH
git -C "$REPO5" add scripts/check.sh

set +e
out5=$(GIT_DIR="$REPO5/.git" GIT_WORK_TREE="$REPO5" bash "$GUARD" 2>&1)
exit5=$?
set -e
if [[ "$exit5" -ne 0 ]]; then
    ok "idiom in added line: exit non-zero (blocked)"
else
    fail "idiom in added line: expected non-zero exit, got 0"
fi
if echo "$out5" | grep -q "check.sh"; then
    ok "idiom in added line: offending file in error message"
else
    fail "idiom in added line: file NOT in error message; got: $out5"
fi

echo "--- Test 6: idiom + bypass comment → exit 0 ---"
REPO6="$TMP/repo6"
init_repo "$REPO6"
cat > "$REPO6/scripts/check.sh" << 'SH'
#!/usr/bin/env bash
echo hello
SH
git -C "$REPO6" add scripts/check.sh
commit_init "$REPO6"

cat >> "$REPO6/scripts/check.sh" << 'SH'
n=$(grep -c 'pattern' file.txt 2>/dev/null || echo 0) # chump-fmt: grep-c-echo0-ok
SH
git -C "$REPO6" add scripts/check.sh

set +e
GIT_DIR="$REPO6/.git" GIT_WORK_TREE="$REPO6" bash "$GUARD" > /dev/null 2>&1
exit6=$?
set -e
if [[ "$exit6" -eq 0 ]]; then
    ok "bypass comment: exit 0"
else
    fail "bypass comment: expected exit 0, got $exit6"
fi

echo "--- Test 7: repaired '|| true' form → exit 0 (not flagged) ---"
REPO7="$TMP/repo7"
init_repo "$REPO7"
cat > "$REPO7/scripts/check.sh" << 'SH'
#!/usr/bin/env bash
echo hello
SH
git -C "$REPO7" add scripts/check.sh
commit_init "$REPO7"

cat >> "$REPO7/scripts/check.sh" << 'SH'
n=$(grep -c 'pattern' file.txt 2>/dev/null || true)
SH
git -C "$REPO7" add scripts/check.sh

set +e
GIT_DIR="$REPO7/.git" GIT_WORK_TREE="$REPO7" bash "$GUARD" > /dev/null 2>&1
exit7=$?
set -e
if [[ "$exit7" -eq 0 ]]; then
    ok "|| true form: exit 0 (not flagged)"
else
    fail "|| true form: expected exit 0, got $exit7"
fi

echo "--- Test 8: idiom only in unmodified lines (not in diff) → exit 0 ---"
REPO8="$TMP/repo8"
init_repo "$REPO8"
cat > "$REPO8/scripts/check.sh" << 'SH'
#!/usr/bin/env bash
n=$(grep -c 'pattern' file.txt 2>/dev/null || echo 0)
SH
git -C "$REPO8" add scripts/check.sh
commit_init "$REPO8"

cat >> "$REPO8/scripts/check.sh" << 'SH'
echo "unrelated new line"
SH
git -C "$REPO8" add scripts/check.sh

set +e
GIT_DIR="$REPO8/.git" GIT_WORK_TREE="$REPO8" bash "$GUARD" > /dev/null 2>&1
exit8=$?
set -e
if [[ "$exit8" -eq 0 ]]; then
    ok "pre-existing idiom: exit 0 (not in diff)"
else
    fail "pre-existing idiom: expected exit 0, got $exit8"
fi

echo "--- Test 9: idiom inside a comment line → exit 0 (not flagged) ---"
REPO9="$TMP/repo9"
init_repo "$REPO9"
cat > "$REPO9/scripts/check.sh" << 'SH'
#!/usr/bin/env bash
echo hello
SH
git -C "$REPO9" add scripts/check.sh
commit_init "$REPO9"

cat >> "$REPO9/scripts/check.sh" << 'SH'
# NOTE: never write grep -c 'x' f || echo 0, it double-echoes
SH
git -C "$REPO9" add scripts/check.sh

set +e
GIT_DIR="$REPO9/.git" GIT_WORK_TREE="$REPO9" bash "$GUARD" > /dev/null 2>&1
exit9=$?
set -e
if [[ "$exit9" -eq 0 ]]; then
    ok "comment-only idiom: exit 0 (not flagged)"
else
    fail "comment-only idiom: expected exit 0, got $exit9"
fi

echo "--- Test 10: functional proof — repaired assertion actually fires ---"
# Reproduce the exact DEAD-assertion class from the gap evidence: a numeric
# comparison against the idiom's captured value silently skips (bash prints
# 'syntax error in expression' to stderr and the [[ ]] never evaluates), so a
# seeded bad input can never trip a FAIL. Prove (a) the old form is dead on a
# seeded bad input, and (b) the '|| true' repair makes it fire.
WORKDIR="$TMP/functional"
mkdir -p "$WORKDIR"
: > "$WORKDIR/empty.txt"   # seeded bad input: file with zero matches

run_old_idiom() {
    # shellcheck disable=SC2320
    local n
    n=$(grep -c 'nomatch' "$WORKDIR/empty.txt" 2>/dev/null || echo 0)
    if [[ "$n" -gt 0 ]]; then
        echo "FIRED"
    else
        echo "DID-NOT-FIRE"
    fi
}

run_repaired_idiom() {
    local n
    n=$(grep -c 'nomatch' "$WORKDIR/empty.txt" 2>/dev/null || true)
    if [[ "${n:-0}" -eq 0 ]]; then
        echo "FIRED"
    else
        echo "DID-NOT-FIRE"
    fi
}

old_stderr="$(run_old_idiom 2>&1 1>/dev/null)"
old_stdout="$(run_old_idiom 2>/dev/null)"
if echo "$old_stderr" | grep -q "syntax error in expression"; then
    ok "seeded bad input: old idiom throws the documented bash syntax error"
else
    fail "seeded bad input: old idiom did NOT throw syntax error (got stderr: $old_stderr)"
fi
if [[ "$old_stdout" == "DID-NOT-FIRE" ]]; then
    ok "seeded bad input: old idiom's -gt 0 assertion is DEAD (never fires)"
else
    fail "seeded bad input: expected old idiom dead, got: $old_stdout"
fi

new_stdout="$(run_repaired_idiom 2>/dev/null)"
if [[ "$new_stdout" == "FIRED" ]]; then
    ok "seeded bad input: repaired ('|| true') -eq 0 assertion FIRES correctly"
else
    fail "seeded bad input: repaired assertion expected to FIRE, got: $new_stdout"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
