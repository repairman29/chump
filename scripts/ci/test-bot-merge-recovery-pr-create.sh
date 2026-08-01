#!/usr/bin/env bash
# test-bot-merge-recovery-pr-create.sh — RESILIENT-217
#
# bot-merge.sh's recovery-mode "pr create/update" stage used to swallow
# `gh pr create` failures with a bare `|| true`, leaving _recover_pr_num
# empty while still logging "pr create/update done" and falling through to
# exit 0 — reporting success when no PR was ever created.
#
# This test extracts the REAL production block verbatim from
# scripts/coord/bot-merge.sh (not a hand-reimplementation, so it can't drift
# from the shipped logic) and drives it against a stubbed `gh`/`jq`/`git`
# in two scenarios:
#   1. gh pr create fails -> must exit 1 + emit botmerge_recovery_pr_create_failed
#   2. gh pr create succeeds -> must exit 0, no failure event, PR number captured

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== RESILIENT-217 recovery-mode PR-create failure handling ==="
echo

START_LINE="$(grep -n 'stage_start "recovery: pr create/update"' "$SCRIPT" | head -1 | cut -d: -f1)"
END_MARKER_LINE="$(grep -n 'if \[\[ -n "\$_recover_pr_num" && "\${AUTO_MERGE' "$SCRIPT" | head -1 | cut -d: -f1)"

if [[ -z "$START_LINE" || -z "$END_MARKER_LINE" ]]; then
    fail "could not locate recovery pr-create block markers in $SCRIPT"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
END_LINE=$((END_MARKER_LINE - 1))

BLOCK="$(sed -n "${START_LINE},${END_LINE}p" "$SCRIPT")"

if ! printf '%s\n' "$BLOCK" | grep -q 'botmerge_recovery_pr_create_failed'; then
    fail "extracted block missing botmerge_recovery_pr_create_failed emit -- fix not present"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "extracted real production block contains the RESILIENT-217 failure path"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Harness: sources the extracted block with stubbed collaborators ─────────
build_harness() {
    local gh_mode="$1"   # "fail" | "succeed" | "existing"
    local harness="$TMP/harness_${gh_mode}.sh"
    cat > "$harness" <<HARNESS_HEAD
#!/usr/bin/env bash
set -uo pipefail
stage_start() { :; }
stage_done()  { :; }
red() { printf '%s\n' "\$*" >&2; }
git() {
    if [[ "\$1" == "log" ]]; then echo "fake commit subject"; return 0; fi
    command git "\$@"
}
gh() {
    if [[ "\$1 \$2" == "pr list" ]]; then
HARNESS_HEAD

    case "$gh_mode" in
        existing)
            cat >> "$harness" <<'HARNESS_LIST'
        echo "4242"
        return 0
HARNESS_LIST
            ;;
        *)
            cat >> "$harness" <<'HARNESS_LIST'
        return 0
HARNESS_LIST
            ;;
    esac

    cat >> "$harness" <<'HARNESS_MID'
    fi
    if [[ "$1 $2" == "pr create" ]]; then
HARNESS_MID

    case "$gh_mode" in
        fail)
            cat >> "$harness" <<'HARNESS_CREATE'
        echo "HttpError: rate limit exceeded" >&2
        return 1
HARNESS_CREATE
            ;;
        succeed)
            cat >> "$harness" <<'HARNESS_CREATE'
        echo '{"number": 9001}'
        return 0
HARNESS_CREATE
            ;;
        existing)
            cat >> "$harness" <<'HARNESS_CREATE'
        echo "should not be called in existing-PR mode" >&2
        return 1
HARNESS_CREATE
            ;;
    esac

    cat >> "$harness" <<HARNESS_TAIL
    fi
    return 0
}

BRANCH="chump/resilient-217-test-claim"
_gap_lbl="RESILIENT-217"
_bm_recover_amb="$TMP/ambient_${gh_mode}.jsonl"

$BLOCK

echo "REACHED_END rc=\$?"
HARNESS_TAIL

    chmod +x "$harness"
    printf '%s' "$harness"
}

echo "--- Test 1: gh pr create fails -> exit 1, no false success ---"
H1="$(build_harness fail)"
set +e
OUT1="$(bash "$H1" 2>&1)"
RC1=$?
set -e
if [[ "$RC1" -eq 1 ]]; then
    ok "Test 1: exit code 1 on gh pr create failure"
else
    fail "Test 1: expected exit 1, got $RC1 (output: $OUT1)"
fi
if ! printf '%s\n' "$OUT1" | grep -q "REACHED_END"; then
    ok "Test 1: script exited before falling through to success path"
else
    fail "Test 1: script fell through past the failure branch (REACHED_END seen)"
fi
if [[ -f "$TMP/ambient_fail.jsonl" ]] && grep -q "botmerge_recovery_pr_create_failed" "$TMP/ambient_fail.jsonl"; then
    ok "Test 1: botmerge_recovery_pr_create_failed emitted to ambient"
else
    fail "Test 1: botmerge_recovery_pr_create_failed NOT emitted"
fi
if [[ -f "$TMP/ambient_fail.jsonl" ]] && grep -q "rate limit exceeded" "$TMP/ambient_fail.jsonl"; then
    ok "Test 1: gh's actual error text captured in the reason field"
else
    fail "Test 1: gh error text not propagated into the ambient event"
fi

echo
echo "--- Test 2: gh pr create succeeds -> exit 0, PR number captured ---"
H2="$(build_harness succeed)"
set +e
OUT2="$(bash "$H2" 2>&1)"
RC2=$?
set -e
if [[ "$RC2" -eq 0 ]]; then
    ok "Test 2: exit code 0 on gh pr create success"
else
    fail "Test 2: expected exit 0, got $RC2 (output: $OUT2)"
fi
if printf '%s\n' "$OUT2" | grep -q "REACHED_END"; then
    ok "Test 2: script reached the end of the block (no premature exit)"
else
    fail "Test 2: script did not reach end of block; output: $OUT2"
fi
if [[ ! -f "$TMP/ambient_succeed.jsonl" ]] || ! grep -q "botmerge_recovery_pr_create_failed" "$TMP/ambient_succeed.jsonl" 2>/dev/null; then
    ok "Test 2: no failure event emitted on success"
else
    fail "Test 2: failure event wrongly emitted on success"
fi

echo
echo "--- Test 3: PR already exists -> gh pr create not invoked, exit 0 ---"
H3="$(build_harness existing)"
set +e
OUT3="$(bash "$H3" 2>&1)"
RC3=$?
set -e
if [[ "$RC3" -eq 0 ]]; then
    ok "Test 3: exit code 0 when PR already exists"
else
    fail "Test 3: expected exit 0, got $RC3 (output: $OUT3)"
fi
if ! printf '%s\n' "$OUT3" | grep -q "should not be called"; then
    ok "Test 3: gh pr create skipped when an existing PR is found"
else
    fail "Test 3: gh pr create was invoked despite an existing PR"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
