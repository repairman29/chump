#!/usr/bin/env bash
# INFRA-587 — verify bot-merge.sh hang detection: timeout wrappers + ambient ALERT.
#
# Tests:
#   1. bash -n syntax check
#   2. _emit_hang_alert function exists in bot-merge.sh
#   3. bot_merge_hang kind is present in bot-merge.sh
#   4. gap-ship phase is wrapped with run_timed_hb
#   5. all 5 key phases have run_timed_hb wrappers (rebase, push, pr-create,
#      gap-ship, auto-merge-arm)
#   6. _emit_hang_alert emits a well-formed JSON event to ambient.jsonl
#   7. emitted event contains required fields: kind=bot_merge_hang, phase, gap_id
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PASS=0
FAIL=0

check() {
    local desc="$1" result="$2"
    if [[ "$result" == "ok" ]]; then
        echo "[test-587] PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "[test-587] FAIL: $desc — $result" >&2
        FAIL=$((FAIL + 1))
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── 1. Syntax check ───────────────────────────────────────────────────────────
if bash -n scripts/coord/bot-merge.sh 2>/dev/null; then
    check "bot-merge.sh passes bash -n" "ok"
else
    check "bot-merge.sh passes bash -n" "syntax error in bot-merge.sh"
fi

# ── 2. _emit_hang_alert function present ─────────────────────────────────────
if grep -q "_emit_hang_alert" scripts/coord/bot-merge.sh; then
    check "bot-merge.sh contains _emit_hang_alert" "ok"
else
    check "bot-merge.sh contains _emit_hang_alert" "missing _emit_hang_alert function"
fi

# ── 3. bot_merge_hang ALERT kind present ─────────────────────────────────────
if grep -q "bot_merge_hang" scripts/coord/bot-merge.sh; then
    check "bot-merge.sh emits bot_merge_hang kind" "ok"
else
    check "bot-merge.sh emits bot_merge_hang kind" "missing bot_merge_hang in bot-merge.sh"
fi

# ── 4. gap-ship phase has run_timed_hb wrapper ────────────────────────────────
if grep -A3 "gap ship" scripts/coord/bot-merge.sh | grep -q "run_timed_hb"; then
    check "gap-ship phase wrapped with run_timed_hb" "ok"
else
    check "gap-ship phase wrapped with run_timed_hb" "gap ship call not wrapped — check INFRA-587 changes"
fi

# ── 5. All 5 key phases have run_timed_hb wrappers ───────────────────────────
_check_phase() {
    local phase_desc="$1" pattern="$2"
    if grep -q "$pattern" scripts/coord/bot-merge.sh; then
        check "phase '$phase_desc' has run_timed_hb wrapper" "ok"
    else
        check "phase '$phase_desc' has run_timed_hb wrapper" "missing: grep for '$pattern'"
    fi
}
_check_phase "rebase"         'run_timed_hb.*git rebase'
_check_phase "push"           'run_timed_hb.*git push'
_check_phase "pr-create"      'run_timed_hb.*gh pr create\|gh_with_backoff.*gh pr create'
_check_phase "gap-ship"       'run_timed_hb.*gap ship'
_check_phase "auto-merge-arm" 'run_timed_hb.*gh pr merge\|gh_with_backoff.*gh pr merge'

# ── 6 & 7. Functional: _emit_hang_alert writes bot_merge_hang to ambient.jsonl ─
FAKE_LOCKS="$TMPDIR_BASE/locks"
mkdir -p "$FAKE_LOCKS"
FAKE_AMBIENT="$FAKE_LOCKS/ambient.jsonl"

# Run _emit_hang_alert in isolation by extracting just the function definition
# and globals it needs, then executing it in a minimal env.
bash -c "
set -euo pipefail
_BM_PID=$$
LOCK_DIR='$FAKE_LOCKS'
REPO_ROOT='$FAKE_LOCKS'
GAP_IDS=(INFRA-587)
DRY_RUN=0

source '$ROOT/scripts/coord/lib/ambient-write.sh'

$(grep -A 12 '^_emit_hang_alert()' scripts/coord/bot-merge.sh)

# Also need red() for the stderr line (non-fatal)
red() { printf '[bot-merge] %s\n' \"\$*\" >&2; }

_emit_hang_alert 'git rebase' 60
" 2>/dev/null || true

if [[ -f "$FAKE_AMBIENT" ]]; then
    check "_emit_hang_alert creates ambient.jsonl entry" "ok"
else
    check "_emit_hang_alert creates ambient.jsonl entry" "ambient.jsonl not created at $FAKE_AMBIENT"
fi

if [[ -f "$FAKE_AMBIENT" ]] && grep -q '"kind":"bot_merge_hang"' "$FAKE_AMBIENT"; then
    check "emitted event has kind=bot_merge_hang" "ok"
else
    check "emitted event has kind=bot_merge_hang" "missing or wrong kind field"
fi

if [[ -f "$FAKE_AMBIENT" ]] && grep -q '"phase":"git rebase"' "$FAKE_AMBIENT"; then
    check "emitted event contains phase field" "ok"
else
    check "emitted event contains phase field" "missing phase field in event"
fi

if [[ -f "$FAKE_AMBIENT" ]] && grep -q '"gap_id":"INFRA-587"' "$FAKE_AMBIENT"; then
    check "emitted event contains gap_id field" "ok"
else
    check "emitted event contains gap_id field" "missing gap_id field in event"
fi

if [[ -f "$FAKE_AMBIENT" ]] && python3 -c "
import json, sys
with open('$FAKE_AMBIENT') as f:
    obj = json.loads(f.readline())
required = {'ts','session','event','kind','phase','timeout_secs','gap_id','note'}
missing = required - set(obj.keys())
sys.exit(0 if not missing else 1)
" 2>/dev/null; then
    check "emitted event is valid JSON with all required fields" "ok"
else
    check "emitted event is valid JSON with all required fields" "JSON parse failed or missing fields"
fi

# ── 8. run_timed_hb calls _emit_hang_alert on exit code 124 ──────────────────
if awk '/^run_timed_hb\(\)/{f=1} f{print} f && /^}/{exit}' scripts/coord/bot-merge.sh | grep -q '_emit_hang_alert'; then
    check "run_timed_hb calls _emit_hang_alert on timeout (exit 124)" "ok"
else
    check "run_timed_hb calls _emit_hang_alert on timeout (exit 124)" "run_timed_hb body does not call _emit_hang_alert"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "[test-587] Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "[test-587] OK"
