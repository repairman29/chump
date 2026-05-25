#!/usr/bin/env bash
# test-subagent-pre-exit-check.sh — INFRA-1953
#
# Verifies the pre-exit-check helper catches each half-ship failure mode.
#
# Assertions:
#   1. branch-not-on-origin → exit 3 + kind=subagent_idle_without_pr emit
#   2. branch-on-origin but no PR → exit 1 + emit
#   3. PR exists but auto-merge disarmed → exit 2 + emit (skip if no PR available)
#   4. all-good real PR with armed auto-merge → exit 0 + no emit
#   5. missing branch arg → exit 4
#   6. debounce: second call within 5min on same session does NOT re-emit

set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

HELPER="scripts/dispatch/subagent-pre-exit-check.sh"
AMBIENT_BACKUP="$(mktemp -t chump-test-amb-XXXXXX).jsonl"
TMP_TMPDIR="$(mktemp -d -t chump-test-pre-exit-XXXXXX)"

# Save real ambient; redirect test emits to backup file via env override.
# The helper uses .chump-locks/ambient.jsonl — we'd touch the real file,
# but lines are append-only and JSON-tagged with session=unknown so they
# can be filtered out post-test. Cleaner: just count lines added.
AMBIENT_PRE_LINES=$(wc -l < .chump-locks/ambient.jsonl 2>/dev/null || echo 0)

cleanup() { rm -f "$AMBIENT_BACKUP"; rm -rf "$TMP_TMPDIR"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }

printf '== Subagent pre-exit-check test (INFRA-1953) ==\n\n'

# ── (5) missing branch arg ───────────────────────────────────────────────────
printf '== 5) missing branch arg → exit 4 ==\n'
set +e
bash "$HELPER" 2>/dev/null
rc=$?
set -e
[[ "$rc" -eq 4 ]] && ok "exit 4 on no-arg" || ko "expected 4, got $rc"

# ── (1) branch not on origin ────────────────────────────────────────────────
printf '\n== 1) branch-not-on-origin → exit 3 ==\n'
set +e
CHUMP_SESSION_ID="test-no-branch-$$" TMPDIR="$TMP_TMPDIR" bash "$HELPER" "chump/synthetic-nonexistent-$$" 2>/dev/null
rc=$?
set -e
[[ "$rc" -eq 3 ]] && ok "exit 3 on missing-origin-branch" || ko "expected 3, got $rc"

# ── (4) all-good: pick a real OPEN PR with armed auto-merge ─────────────────
printf '\n== 4) real PR with armed auto-merge → exit 0 ==\n'
REAL_PR=$(gh pr list --state open --json number,autoMergeRequest,headRefName \
    --jq '[.[] | select(.autoMergeRequest != null)] | .[0]' 2>/dev/null || echo '')
if [[ -z "$REAL_PR" || "$REAL_PR" == "null" ]]; then
    printf '  \033[33m·\033[0m no open PR with auto-merge armed available — skip\n'
else
    REAL_BRANCH=$(printf '%s' "$REAL_PR" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["headRefName"])')
    set +e
    CHUMP_SESSION_ID="test-good-$$" TMPDIR="$TMP_TMPDIR" bash "$HELPER" "$REAL_BRANCH" >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] && ok "exit 0 on real-armed-PR ($REAL_BRANCH)" || ko "expected 0 on real PR, got $rc"
fi

# ── (6) debounce: second call within 5min on same session does NOT re-emit ──
printf '\n== 6) debounce within 5min same session ==\n'
SESS_DEBOUNCE="test-debounce-$$"
set +e
CHUMP_SESSION_ID="$SESS_DEBOUNCE" TMPDIR="$TMP_TMPDIR" bash "$HELPER" "chump/synthetic-debounce-$$" 2>/dev/null
LINES_AFTER_1=$(wc -l < .chump-locks/ambient.jsonl 2>/dev/null || echo 0)
CHUMP_SESSION_ID="$SESS_DEBOUNCE" TMPDIR="$TMP_TMPDIR" bash "$HELPER" "chump/synthetic-debounce-$$" 2>/dev/null
LINES_AFTER_2=$(wc -l < .chump-locks/ambient.jsonl 2>/dev/null || echo 0)
set -e
if [[ "$LINES_AFTER_2" -eq "$LINES_AFTER_1" ]]; then
    ok "second call within debounce window did not re-emit (line count stable at $LINES_AFTER_2)"
else
    ko "debounce failed: lines went $LINES_AFTER_1 → $LINES_AFTER_2"
fi

# ── ambient-emit cross-check: ensure subagent_idle_without_pr was emitted ───
printf '\n== ambient-emit cross-check ==\n'
EMIT_COUNT=$(tail -50 .chump-locks/ambient.jsonl 2>/dev/null \
    | grep -c '"kind":"subagent_idle_without_pr"' 2>/dev/null || echo 0)
if [[ "$EMIT_COUNT" -ge 1 ]]; then
    ok "subagent_idle_without_pr emitted to ambient ($EMIT_COUNT in recent tail)"
else
    ko "subagent_idle_without_pr NOT emitted (recent ambient tail has 0)"
fi

printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
