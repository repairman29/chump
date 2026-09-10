#!/usr/bin/env bash
# test-reaper-spare-recoverable-blocked.sh — REAPER-SPARE (PR #4589 fix)
#
# The stale-pr-reaper's INFRA-1410 auto-respawn loop used to CLOSE any PR that
# sat mergeStateStatus=BLOCKED past its SLO. That destroyed correct work: PR
# #4589 was a green, all-tests-pass PR whose per-PR CI flake exhausted the
# INFRA-304 rerun budget (3/3), leaving it BLOCKED — and the reaper reaped it.
#
# This test proves the reaper now SPARES recoverable BLOCKED PRs and only
# bounces genuinely dead ones. It exercises the real decision function
# (scripts/ops/lib/classify-blocked-pr.py) with synthetic statusCheckRollup
# fixtures + real INFRA-304 budget markers, and asserts the reaper source is
# wired to spare on the recoverable verdicts.
#
# Depth tier: EDGE (pure decision-function fixtures across the BLOCKED-reason
# matrix — pending / flake-exhausted / no-failure / hard-fail / conflict — plus
# marker-driven flake detection and source-wiring asserts). Gaps: does not spin
# up a live gh/GitHub PR or drive the full reaper loop end-to-end against a real
# BLOCKED PR (that path needs network + a real branch); the reaper→classifier
# glue is covered by source-wiring asserts, not live execution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-pr-reaper.sh"
CLASSIFIER="$REPO_ROOT/scripts/ops/lib/classify-blocked-pr.py"
REGISTRY="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

pass=0; fail=0
ok()   { echo "PASS $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1"; fail=$((fail+1)); }

for f in "$REAPER" "$CLASSIFIER" "$REGISTRY"; do
    [[ -f "$f" ]] || { echo "FAIL: required file missing: $f"; exit 1; }
done

_tmp=$(mktemp -d /tmp/test-reaper-spare.XXXXXX)
trap 'rm -rf "$_tmp"' EXIT
CD="$_tmp/ci-flake-cooldown"
mkdir -p "$CD"

# classify VERDICT_EXPECTED  ROLLUP_JSON  MERGEABLE  [PR] [FLAKE_EXHAUSTED|marker]
# Calls the REAL classifier and asserts the verdict.
_run() {
    local rollup="$1" mergeable="$2"; shift 2
    printf '%s' "$rollup" > "$_tmp/rollup.json"
    python3 "$CLASSIFIER" --rollup-file "$_tmp/rollup.json" --mergeable "$mergeable" "$@" 2>/dev/null
}

CR_RUNNING='[{"__typename":"CheckRun","name":"required","status":"IN_PROGRESS","conclusion":null}]'
CR_QUEUED='[{"__typename":"CheckRun","name":"required","status":"QUEUED","conclusion":null}]'
CR_FAIL='[{"__typename":"CheckRun","name":"required","status":"COMPLETED","conclusion":"FAILURE"}]'
CR_GREEN='[{"__typename":"CheckRun","name":"required","status":"COMPLETED","conclusion":"SUCCESS"}]'
CR_MIXED='[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"b","status":"QUEUED","conclusion":null}]'

# ── 1. pending required checks (CI still running) → SPARE ─────────────────────
v=$(_run "$CR_RUNNING" MERGEABLE --flake-exhausted 0)
[[ "$v" == "pending" ]] && ok "1: IN_PROGRESS required check → pending (spared)" \
                         || bad "1: expected pending, got '$v'"

v=$(_run "$CR_QUEUED" MERGEABLE --flake-exhausted 0)
[[ "$v" == "pending" ]] && ok "2: QUEUED required check → pending (spared)" \
                         || bad "2: expected pending, got '$v'"

# ── 3. green-but-flake-BLOCKED (budget exhausted) → SPARE (re-arm) ────────────
# This is the PR #4589 class: the only failing check is a known flake whose
# rerun budget is spent. Must NOT be closed.
v=$(_run "$CR_FAIL" MERGEABLE --flake-exhausted 1)
[[ "$v" == "flake_exhausted" ]] && ok "3: failed check + budget exhausted → flake_exhausted (spared, re-armed)" \
                                 || bad "3: expected flake_exhausted, got '$v'  <-- PR #4589 regression!"

# ── 3b. same, but driven by the REAL INFRA-304 markers, not an override ───────
touch "$CD/pr-4589.commented"
v=$(_run "$CR_FAIL" MERGEABLE --pr 4589 --cooldown-dir "$CD" --flake-budget 3)
[[ "$v" == "flake_exhausted" ]] && ok "3b: pr-4589.commented marker → flake_exhausted (spared)" \
                                 || bad "3b: expected flake_exhausted from marker, got '$v'"

echo 3 > "$CD/pr-500.count"
v=$(_run "$CR_FAIL" MERGEABLE --pr 500 --cooldown-dir "$CD" --flake-budget 3)
[[ "$v" == "flake_exhausted" ]] && ok "3c: pr-500.count>=budget → flake_exhausted (spared)" \
                                 || bad "3c: expected flake_exhausted from count, got '$v'"

# ── 4. HARD (non-flake) CI failure → NOT spared (close-eligible) ─────────────
# A real failure with the budget NOT exhausted must fall through to the bounce
# path so the reaper keeps its real job of respawning genuinely-broken attempts.
v=$(_run "$CR_FAIL" MERGEABLE --flake-exhausted 0)
[[ "$v" == "hard_fail" ]] && ok "4: failed check, budget NOT exhausted → hard_fail (close-eligible)" \
                           || bad "4: expected hard_fail, got '$v'"

echo 1 > "$CD/pr-501.count"
v=$(_run "$CR_FAIL" MERGEABLE --pr 501 --cooldown-dir "$CD" --flake-budget 3)
[[ "$v" == "hard_fail" ]] && ok "4b: failed check, count(1)<budget(3) → hard_fail (close-eligible)" \
                           || bad "4b: expected hard_fail, got '$v'"

# ── 5. DIRTY / merge conflict → NOT spared (close-eligible) ──────────────────
v=$(_run "$CR_GREEN" CONFLICTING --flake-exhausted 0)
[[ "$v" == "conflict" ]] && ok "5: mergeable=CONFLICTING → conflict (close-eligible)" \
                          || bad "5: expected conflict, got '$v'"

# ── 6. all green but still BLOCKED (e.g. missing review) → SPARE ─────────────
v=$(_run "$CR_GREEN" MERGEABLE --flake-exhausted 0)
[[ "$v" == "blocked_no_failure" ]] && ok "6: no pending/no failing but BLOCKED → blocked_no_failure (spared)" \
                                    || bad "6: expected blocked_no_failure, got '$v'"

# ── 7. pending WINS over a concurrent failure (mixed state) → SPARE ──────────
# If anything is still running we never reap, even with a failed check present
# and the budget exhausted — the run may yet turn green.
v=$(_run "$CR_MIXED" MERGEABLE --flake-exhausted 1)
[[ "$v" == "pending" ]] && ok "7: mixed (one FAILURE + one QUEUED) → pending (spared)" \
                         || bad "7: expected pending, got '$v'"

# ── 8. reaper source wires the spare verdicts to non-closing actions ─────────
if grep -q 'CHUMP_REAPER_SPARE_RECOVERABLE' "$REAPER"; then
    ok "8: CHUMP_REAPER_SPARE_RECOVERABLE guard present in reaper"
else
    bad "8: CHUMP_REAPER_SPARE_RECOVERABLE guard missing from reaper"
fi

if grep -q 'classify_blocked_pr' "$REAPER"; then
    ok "9: reaper calls classify_blocked_pr before the bounce path"
else
    bad "9: reaper does not call classify_blocked_pr"
fi

# The recoverable verdicts must each `continue` (skip the close), and the flake
# case must re-arm rather than close. Assert the spare branch precedes the
# ATTEMPTED_AT/close logic in source order.
_spare_line=$(grep -n 'classify_blocked_pr "\$PR_NUM"' "$REAPER" | head -1 | cut -d: -f1)
_close_line=$(grep -n 'auto-closed by stale-pr-reaper' "$REAPER" | head -1 | cut -d: -f1)
if [[ -n "$_spare_line" && -n "$_close_line" && "$_spare_line" -lt "$_close_line" ]]; then
    ok "10: spare classification (L$_spare_line) precedes the respawn-close (L$_close_line)"
else
    bad "10: spare classification does not precede the respawn-close (spare=$_spare_line close=$_close_line)"
fi

if grep -q 'rearm_flake_budget' "$REAPER"; then
    ok "11: reaper re-arms the flake budget instead of closing (rearm_flake_budget present)"
else
    bad "11: reaper missing rearm_flake_budget — flake case would have no recovery path"
fi

# The reaper must NOT close on flake_exhausted — assert the flake branch emits
# rearmed/escalated and never falls into the close path.
if grep -q 'pr_stuck_flake_escalated' "$REAPER"; then
    ok "12: flake re-exhaustion ESCALATES to operator (never closes)"
else
    bad "12: no pr_stuck_flake_escalated escalation — a persistent flake could still be closed"
fi

# ── 13. new event kinds registered ───────────────────────────────────────────
for k in pr_stuck_spared pr_stuck_flake_rearmed pr_stuck_flake_escalated; do
    if grep -q "^$k" "$REGISTRY"; then
        ok "13/$k: registered in event-registry-reserved.txt"
    else
        bad "13/$k: NOT registered in event-registry-reserved.txt"
    fi
done

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-reaper-spare-recoverable-blocked: ALL $pass passed"
    exit 0
else
    echo "test-reaper-spare-recoverable-blocked: $pass passed, $fail failed"
    exit 1
fi
