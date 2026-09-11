#!/usr/bin/env bash
# test-pr-reaper-rescuer.sh — RESILIENT-1108 (Receipt Law).
#
# Proves pr-reaper-rescuer's decision core:
#   * a reaper-closed, green-underneath PR whose gap is still open is RESCUED;
#   * a human-closed PR is LEFT ALONE (never resurrected);
#   * a genuine hard-failure PR is LEFT ALONE;
#   * a real merge conflict / dead-label PR is LEFT ALONE;
#   * a superseded gap (done) is LEFT ALONE;
#   * a CI-cancelled red is treated as fixable (RESCUE);
#   * rescue is BOUNDED — at/over the cap it ESCALATES instead of resurrecting.
# Plus a live-classifier integration check that classify-blocked-pr.py (#4606)
# feeds the expected verdict from a synthetic statusCheckRollup.
#
# Pure + hermetic: no network, no gh, no state.db. Exercises the `--decide`
# surface of the organ script with fully-resolved synthetic inputs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESCUER="$REPO_ROOT/scripts/coord/pr-reaper-rescuer.sh"
CLASSIFY="$REPO_ROOT/scripts/ops/lib/classify-blocked-pr.py"

fail=0
pass=0

# decide EXPECTED  -- <flags for --decide>
decide() {
    local expected="$1"; shift
    [[ "$1" == "--" ]] && shift
    local got
    got="$(bash "$RESCUER" --decide "$@" 2>/dev/null)"
    if [[ "$got" == "$expected" ]]; then
        pass=$((pass+1))
        echo "  ok: [$*] → $got"
    else
        fail=$((fail+1))
        echo "  FAIL: [$*] expected '$expected' got '$got'"
    fi
}

echo "== decide_rescue verdicts =="

# 1. The core rescue: reaper-closed, green-underneath (blocked_no_failure / a
#    late parity gate), gap open, first attempt → RESCUE.
decide RESCUE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify blocked_no_failure --gap-status open --attempts 0 --max 2

# flake_exhausted and pending are equally recoverable.
decide RESCUE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify flake_exhausted --gap-status open --attempts 0 --max 2
decide RESCUE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify pending --gap-status in_progress --attempts 1 --max 2

# 2. HUMAN-closed PRs are sacrosanct — never resurrected even if green-underneath.
decide SKIP_HUMAN_CLOSED -- --state CLOSED --closed-by-reaper 0 --mergeable MERGEABLE \
    --classify blocked_no_failure --gap-status open --attempts 0 --max 2

# 3. Genuine hard failure (real red, not flake/cancel) → left alone.
decide SKIP_HARD_FAIL -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify hard_fail --cancelled-only 0 --gap-status open --attempts 0 --max 2

# 3b. …but a CI-CANCEL red is a fixable cause → RESCUE.
decide RESCUE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify hard_fail --cancelled-only 1 --gap-status open --attempts 0 --max 2

# 4. BOUND: at the cap it escalates rather than fighting the reaper again.
decide ESCALATE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify blocked_no_failure --gap-status open --attempts 2 --max 2
decide ESCALATE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify flake_exhausted --gap-status open --attempts 5 --max 2

# 5. Real conflict / dead-label → needs a human, never revived.
decide SKIP_DEAD_CONFLICT -- --state CLOSED --closed-by-reaper 1 --mergeable CONFLICTING \
    --classify conflict --gap-status open --attempts 0 --max 2
decide SKIP_DEAD_CONFLICT -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify blocked_no_failure --dead-label 1 --gap-status open --attempts 0 --max 2

# 6. Superseded gap (positively done/closed — e.g. #4601, landed via #4627) → left alone.
decide SKIP_GAP_NOT_WANTED -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify blocked_no_failure --gap-status done --attempts 0 --max 2
decide SKIP_GAP_NOT_WANTED -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify blocked_no_failure --gap-status closed --attempts 0 --max 2

# 6b. Gapless fix-PR (unknown/empty gap — e.g. #4615 "completes PR #4606") is NOT
#     blocked: reaper-closed + green-underneath is enough evidence it's wanted.
decide RESCUE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify blocked_no_failure --gap-status "" --attempts 0 --max 2
decide RESCUE -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify pending --gap-status unknown --attempts 0 --max 2

# 7. Already merged / already open → nothing to do.
decide SKIP_ALREADY_MERGED -- --state MERGED --closed-by-reaper 1 --gap-status open
decide SKIP_ALREADY_OPEN   -- --state OPEN   --closed-by-reaper 1 --gap-status open

# 8. Dead-label beats a still-open gap AND a green classify (deadlock guard).
decide SKIP_DEAD_CONFLICT -- --state CLOSED --closed-by-reaper 1 --mergeable MERGEABLE \
    --classify pending --dead-label 1 --gap-status open --attempts 0 --max 2

echo "== classify-blocked-pr.py integration (green-underneath detection) =="
if [[ -f "$CLASSIFY" ]]; then
    # A rollup with one still-running required check must classify 'pending'
    # (recoverable) — the exact green-underneath signal the rescuer keys on.
    v="$(printf '[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null}]' \
        | python3 "$CLASSIFY" --rollup-file - --mergeable MERGEABLE 2>/dev/null)"
    if [[ "$v" == "pending" ]]; then pass=$((pass+1)); echo "  ok: IN_PROGRESS rollup → pending"; else fail=$((fail+1)); echo "  FAIL: IN_PROGRESS rollup expected 'pending' got '$v'"; fi

    # A completed real FAILURE (no flake budget) must classify 'hard_fail' (dead).
    v="$(printf '[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"}]' \
        | python3 "$CLASSIFY" --rollup-file - --mergeable MERGEABLE --flake-exhausted 0 2>/dev/null)"
    if [[ "$v" == "hard_fail" ]]; then pass=$((pass+1)); echo "  ok: real FAILURE rollup → hard_fail"; else fail=$((fail+1)); echo "  FAIL: FAILURE rollup expected 'hard_fail' got '$v'"; fi
else
    echo "  skip: classify-blocked-pr.py not present"
fi

echo "----"
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || { echo "FAIL: pr-reaper-rescuer decision core is wrong"; exit 1; }
echo "PASS: pr-reaper-rescuer (RESILIENT-1108) — reaper-closed green-underneath rescued, human/hard-fail/conflict/superseded left alone, rescue bounded"
exit 0
