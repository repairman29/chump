#!/usr/bin/env bash
# test-verified-wait.sh — CREDIBLE-1554 (PHASE-R R3)
#
# Proves scripts/ci/verified-wait.sh — the in-job wait loop for the sole
# required `verified` check under a GitHub native merge queue — reaches the
# RIGHT FIRST verdict by stubbing the Checks API (`gh`) with canned JSON.
#
# Under a merge queue a merge_group is ejected the instant a required check
# concludes FAILURE, so the verdict must be correct on the first conclusion:
#   - a lane still running OR never-seen is PENDING (keep polling), NEVER FAIL;
#   - FAILURE only on a real red lane or on the timeout;
#   - SUCCESS only when every lane is green or legitimately skipped.
#
# Matrix (each run for BOTH pull_request and merge_group event types, since the
# wait behavior must be identical — the event only changes the SHA ci.yml feeds
# in via --sha):
#   1. in_progress then success        -> PASS   (exit 0)
#   2. in_progress then failure         -> FAIL   (exit 1, real red, not timeout)
#   3. never-seen  then success         -> PASS   (exit 0)   folds RESILIENT-1617
#   4. never-seen  until timeout        -> FAIL   (exit 1, TIMEOUT reason)
#   5. real red LOCAL lane              -> FAIL   (exit 1) short-circuits, no wait
#   6. cross lane cancelled             -> FAIL   (exit 1) short-circuits, no wait
#   7. cross lane timed_out             -> FAIL   (exit 1) short-circuits, no wait
#   8. cross lane action_required       -> FAIL   (exit 1) short-circuits, no wait
#   9. gh API error (non-zero exit)     -> PENDING then FAIL (exit 1, TIMEOUT) — a
#                                          transient gh error is fail-SAFE (lane
#                                          PENDING), never fail-OPEN (no silent PASS)
#  10. ACP green + audit never-seen     -> PENDING (keeps polling; not PASS, not FAIL)
#
# Non-matrix scenarios (CREDIBLE-1554 items 4 & 5):
#  11. ambient emit lands in a TEMP CHUMP_AMBIENT_LOG, not the real ambient.jsonl
#  12. --event-name workflow_dispatch STILL classifies the cross lanes on the SHA
#      (it does NOT skip them) under a SHORT bounded window — three cases:
#        12a. audit failure    -> FAIL (exit 1, real red)
#        12b. audit never-seen -> FAIL (exit 1, TIMEOUT) quickly, never a PASS
#        12c. audit success    -> PASS (exit 0) quickly
#  13. the REAL classification path binds ONE lane list to ALL FOUR events —
#      pull_request, merge_group, push and workflow_dispatch (item 5, Chief-binding):
#        13a. both cross lanes never-seen -> FAIL via TIMEOUT naming audit+ACP;
#        13b. audit red -> FAIL (real red). A mutant dropping the cross lanes on
#             any single event FAILs 13a on that event.
#  14. --print-budget: per-event wait budget resolves from --event-name alone (item
#      3) — workflow_dispatch -> 300s, every other event -> 5400s (ONE lane list,
#      only the budget differs by event)
#
# Run locally: bash scripts/ci/test-verified-wait.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WAIT="$REPO_ROOT/scripts/ci/verified-wait.sh"

[[ -x "$WAIT" ]] || { echo "FATAL: $WAIT not found or not executable"; exit 2; }

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== CREDIBLE-1554 verified-wait.sh in-job-wait guard ==="
echo

# Each scenario provides a gh() stub that is exported so the child `bash
# poll-cross-workflow-checks.sh` process inherits it. A shared counter file
# (CNT) lets a stub return different JSON on successive polls.
CNT="$(mktemp)"
export CNT
reset_cnt() { echo 0 > "$CNT"; }
bump_cnt()  { local n; n=$(($(cat "$CNT") + 1)); echo "$n" > "$CNT"; echo "$n"; }

# CREDIBLE-1554 item 4: the aggregator emits kind=verified_aggregator_decision on
# the terminal verdict. Point CHUMP_AMBIENT_LOG at a TEMP file so this test never
# writes synthetic events into the real .chump-locks/ambient.jsonl. run_wait
# exports it into the verified-wait child (which re-runs the aggregator for the
# one-shot terminal emit without forcing /dev/null).
AMB="$(mktemp)"
: > "$AMB"

# Representative SHAs for each event type (merge_group feeds github.sha; a PR
# feeds pull_request.head.sha — verified-wait takes whichever as --sha).
declare -A SHAS=( [pull_request]=prsha0000 [merge_group]=mergesha000 [push]=pushsha0000 [workflow_dispatch]=dispatchsha0 )

# Run verified-wait with a cross `audit` lane + all-green local lanes (unless a
# scenario overrides LOCAL_OVERRIDE). Captures combined stdout+stderr + exit.
run_wait() {
    local event="$1" timeout="$2" interval="$3"; shift 3
    local extra_local=("$@")
    local sha="${SHAS[$event]}"
    local lanes=(--lane "fast-checks=success" --lane "test=success")
    lanes+=("${extra_local[@]}")
    OUT="$(GH_REPO="owner/repo" CHUMP_AMBIENT_LOG="$AMB" bash "$WAIT" \
        --sha "$sha" --pr 999 --event-name "$event" \
        "${lanes[@]}" \
        --cross "audit" \
        --timeout-s "$timeout" --interval-s "$interval" 2>&1)"
    RC=$?
}

# Variant of run_wait that lets a scenario override the cross lanes (name list)
# and keeps all-green locals. Used by the ACP-green + audit-never-seen case.
run_wait_cross() {
    local event="$1" timeout="$2" interval="$3"; shift 3
    local crosses=("$@")
    local sha="${SHAS[$event]}"
    local args=(--sha "$sha" --pr 999 --event-name "$event"
                --lane "fast-checks=success" --lane "test=success")
    local c; for c in "${crosses[@]}"; do args+=(--cross "$c"); done
    args+=(--timeout-s "$timeout" --interval-s "$interval")
    OUT="$(GH_REPO="owner/repo" CHUMP_AMBIENT_LOG="$AMB" bash "$WAIT" "${args[@]}" 2>&1)"
    RC=$?
}

for EVENT in pull_request merge_group; do
    echo "--- event: $EVENT ---"

    # 1. in_progress then success -> PASS
    reset_cnt
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        local n; n="$(bump_cnt)"
        if [[ "$n" -lt 2 ]]; then
            echo '[{"name":"audit","status":"in_progress","started_at":"2026-10-19T00:00:00Z"}]'
        else
            echo '[{"name":"audit","status":"completed","conclusion":"success","started_at":"2026-10-19T00:00:00Z"}]'
        fi
    }
    export -f gh bump_cnt
    run_wait "$EVENT" 15 1
    if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] in_progress->success => PASS (exit 0)"
    else
        bad "[$EVENT] in_progress->success: rc=$RC out=<<$OUT>>"
    fi

    # 2. in_progress then failure -> FAIL (real red, not a timeout)
    reset_cnt
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        local n; n="$(bump_cnt)"
        if [[ "$n" -lt 2 ]]; then
            echo '[{"name":"audit","status":"in_progress","started_at":"2026-10-19T00:00:00Z"}]'
        else
            echo '[{"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-10-19T00:00:00Z"}]'
        fi
    }
    export -f gh bump_cnt
    run_wait "$EVENT" 15 1
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "real red lane" && ! echo "$OUT" | grep -q "TIMEOUT"; then
        ok "[$EVENT] in_progress->failure => FAIL real-red (exit 1, not timeout)"
    else
        bad "[$EVENT] in_progress->failure: rc=$RC out=<<$OUT>>"
    fi

    # 3. never-seen then success -> PASS (no check-run + no audit.yml run on
    #    the first poll => in_progress/PENDING, NEVER fail-closed; RESILIENT-1617)
    reset_cnt
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        local n; n="$(bump_cnt)"
        if [[ "$n" -lt 2 ]]; then
            echo '[]'
        else
            echo '[{"name":"audit","status":"completed","conclusion":"success","started_at":"2026-10-19T00:00:00Z"}]'
        fi
    }
    export -f gh bump_cnt
    run_wait "$EVENT" 15 1
    if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] never-seen->success => PASS (exit 0, never fail-closed early)"
    else
        bad "[$EVENT] never-seen->success: rc=$RC out=<<$OUT>>"
    fi

    # 4. never-seen until timeout -> FAIL with a timeout reason
    gh() { if [[ "${1:-}" == "run" ]]; then echo '[]'; else echo '[]'; fi; }
    export -f gh
    run_wait "$EVENT" 2 1
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "TIMEOUT"; then
        ok "[$EVENT] never-seen->timeout => FAIL with TIMEOUT reason (exit 1)"
    else
        bad "[$EVENT] never-seen->timeout: rc=$RC out=<<$OUT>>"
    fi

    # 5. real red LOCAL lane short-circuits immediately (exit 1, no 90-min wait),
    #    even while the cross lane is still in_progress.
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        echo '[{"name":"audit","status":"in_progress","started_at":"2026-10-19T00:00:00Z"}]'
    }
    export -f gh
    start=$(date +%s)
    run_wait "$EVENT" 60 5 --lane "clippy=failure"
    elapsed=$(( $(date +%s) - start ))
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "real red lane" && [[ "$elapsed" -lt 10 ]]; then
        ok "[$EVENT] red local lane short-circuits FAIL (exit 1, ${elapsed}s, no wait)"
    else
        bad "[$EVENT] red local short-circuit: rc=$RC elapsed=${elapsed}s out=<<$OUT>>"
    fi

    # 6-8. A cross lane that CONCLUDES non-green on the first snapshot is a real
    #      red lane -> FAIL immediately (exit 1), never a wait. cancelled stays
    #      its own conclusion; timed_out/action_required normalize to failure in
    #      poll-cross-workflow-checks.sh snapshot mode. All must short-circuit.
    for concl in cancelled timed_out action_required; do
        gh() {
            if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
            printf '[{"name":"audit","status":"completed","conclusion":"%s","started_at":"2026-10-19T00:00:00Z"}]' "$GH_CONCL"
        }
        export GH_CONCL="$concl"
        export -f gh
        start=$(date +%s)
        run_wait "$EVENT" 60 5
        elapsed=$(( $(date +%s) - start ))
        if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "real red lane" \
           && ! echo "$OUT" | grep -q "TIMEOUT" && [[ "$elapsed" -lt 10 ]]; then
            ok "[$EVENT] cross lane ${concl} => FAIL real-red (exit 1, ${elapsed}s, no wait)"
        else
            bad "[$EVENT] cross ${concl}: rc=$RC elapsed=${elapsed}s out=<<$OUT>>"
        fi
        unset GH_CONCL
    done

    # 9. gh API error (non-zero exit, no output) must be fail-SAFE: the cross
    #    snapshot is empty, verified-wait treats the declared lane as PENDING
    #    (NOT a silent PASS), keeps polling, and FAILs only at the timeout.
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        return 1   # simulate a transient gh api failure
    }
    export -f gh
    run_wait "$EVENT" 2 1
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "TIMEOUT" \
       && ! echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] gh error => PENDING then TIMEOUT FAIL (exit 1, never fail-open)"
    else
        bad "[$EVENT] gh error fail-safe: rc=$RC out=<<$OUT>>"
    fi

    # 10. ACP green + audit never-seen => PENDING (keep polling), never PASS and
    #     never FAIL, until the timeout. Proves one green cross lane cannot carry
    #     a still-unseen sibling to PASS (RESILIENT-1617 lane-seen rule).
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        # ACP has concluded green; audit has posted nothing (never-seen).
        echo '[{"name":"ACP protocol smoke test (Zed / JetBrains compatible)","status":"completed","conclusion":"success","started_at":"2026-10-19T00:00:00Z"}]'
    }
    export -f gh
    run_wait_cross "$EVENT" 2 1 "audit" "ACP protocol smoke test (Zed / JetBrains compatible)"
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "TIMEOUT" \
       && echo "$OUT" | grep -q "audit" && ! echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] ACP green + audit never-seen => PENDING then TIMEOUT (not PASS, not early FAIL)"
    else
        bad "[$EVENT] ACP green + audit never-seen: rc=$RC out=<<$OUT>>"
    fi
done

# 11. (item 4) The terminal-verdict ambient emits must have landed in the TEMP
#     CHUMP_AMBIENT_LOG, and the REAL .chump-locks/ambient.jsonl must be
#     untouched by this test's synthetic SHAs.
echo "--- ambient isolation (item 4) ---"
if [[ -s "$AMB" ]] && grep -q 'verified_aggregator_decision' "$AMB"; then
    ok "terminal verdict emitted kind=verified_aggregator_decision to temp CHUMP_AMBIENT_LOG"
else
    bad "temp CHUMP_AMBIENT_LOG has no verified_aggregator_decision: <<$(cat "$AMB")>>"
fi
REAL_AMB="$REPO_ROOT/.chump-locks/ambient.jsonl"
if [[ ! -f "$REAL_AMB" ]] || ! grep -qE 'prsha0000|mergesha000|pushsha0000|dispatchsha0' "$REAL_AMB"; then
    ok "real .chump-locks/ambient.jsonl was NOT polluted by the test's synthetic SHAs"
else
    bad "real ambient.jsonl contains the test's synthetic SHAs — ambient isolation failed"
fi

# 12. (items 1 & 5) --event-name workflow_dispatch does NOT skip the cross lanes:
#     it classifies audit on the SHA under a SHORT bounded window. Three cases
#     prove red/never-seen at the end of the window FAIL (never a silent PASS),
#     and a concluded-green cross lane PASSes — all quickly.
echo "--- workflow_dispatch classifies cross lanes under a short window (items 1 & 5) ---"

# 12a. audit failure -> FAIL (real red), short-circuits immediately.
gh() {
    if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
    echo '[{"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-10-19T00:00:00Z"}]'
}
export -f gh
start=$(date +%s)
run_wait "workflow_dispatch" 60 1
elapsed=$(( $(date +%s) - start ))
if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "real red lane" \
   && ! echo "$OUT" | grep -q "TIMEOUT" && [[ "$elapsed" -lt 10 ]]; then
    ok "workflow_dispatch + audit failure => FAIL real-red (exit 1, ${elapsed}s, cross NOT skipped)"
else
    bad "workflow_dispatch audit-failure: rc=$RC elapsed=${elapsed}s out=<<$OUT>>"
fi

# 12b. audit never-seen -> FAIL quickly via TIMEOUT (never a PASS past an unseen
#      cross lane). The short --timeout-s makes "quickly" literal.
gh() { if [[ "${1:-}" == "run" ]]; then echo '[]'; else echo '[]'; fi; }
export -f gh
start=$(date +%s)
run_wait "workflow_dispatch" 2 1
elapsed=$(( $(date +%s) - start ))
if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "TIMEOUT" \
   && echo "$OUT" | grep -q "audit" && ! echo "$OUT" | grep -q "VERDICT=PASS" \
   && [[ "$elapsed" -lt 10 ]]; then
    ok "workflow_dispatch + audit never-seen => FAIL TIMEOUT quickly (exit 1, ${elapsed}s, never PASS)"
else
    bad "workflow_dispatch audit-never-seen: rc=$RC elapsed=${elapsed}s out=<<$OUT>>"
fi

# 12c. audit success -> PASS quickly.
gh() {
    if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
    echo '[{"name":"audit","status":"completed","conclusion":"success","started_at":"2026-10-19T00:00:00Z"}]'
}
export -f gh
start=$(date +%s)
run_wait "workflow_dispatch" 60 1
elapsed=$(( $(date +%s) - start ))
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "VERDICT=PASS" && [[ "$elapsed" -lt 10 ]]; then
    ok "workflow_dispatch + audit success => PASS quickly (exit 0, ${elapsed}s)"
else
    bad "workflow_dispatch audit-success: rc=$RC elapsed=${elapsed}s out=<<$OUT>>"
fi

# 13. (item 5, Chief-binding) The REAL classification path binds ONE lane list
#     to ALL FOUR events. Rather than --print-lanes (which exits before any event
#     logic and so cannot catch a per-event lane mutation), this runs the actual
#     wait/aggregate loop for pull_request, merge_group, push AND
#     workflow_dispatch and asserts the cross lanes are classified for every one:
#        13a. both cross lanes (audit + ACP) NEVER-SEEN, short --timeout-s
#             => FAIL with a TIMEOUT that names BOTH cross lanes (never a PASS).
#        13b. audit RED => FAIL (real red lane), for every event.
#     A mutant that drops the cross lanes on any single event (e.g.
#     `[[ "$EVENT_NAME" == "push" ]] && CROSS_CHECKS=()`) would PASS on that event
#     with the cross lanes unseen — so 13a FAILs the suite on that event. The two
#     cross lanes are the SAME list for every event; only the budget differs (13/14).
echo "--- real classification binds one lane list to all four events (item 5) ---"
BOTH_CROSS=("audit" "ACP protocol smoke test (Zed / JetBrains compatible)")
for EVENT in pull_request merge_group push workflow_dispatch; do
    # 13a. both cross lanes never-seen -> FAIL via TIMEOUT naming BOTH cross lanes.
    gh() { if [[ "${1:-}" == "run" ]]; then echo '[]'; else echo '[]'; fi; }
    export -f gh
    run_wait_cross "$EVENT" 2 1 "${BOTH_CROSS[@]}"
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "TIMEOUT" \
       && echo "$OUT" | grep -q "audit" \
       && echo "$OUT" | grep -q "ACP protocol smoke test (Zed / JetBrains compatible)" \
       && ! echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] both cross lanes never-seen => FAIL TIMEOUT naming audit+ACP (never PASS)"
    else
        bad "[$EVENT] both cross never-seen: rc=$RC out=<<$OUT>>"
    fi

    # 13b. audit red -> FAIL (real red lane) for every event.
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        echo '[{"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-10-19T00:00:00Z"}]'
    }
    export -f gh
    run_wait_cross "$EVENT" 60 1 "${BOTH_CROSS[@]}"
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "real red lane" \
       && ! echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] audit red => FAIL real-red (exit 1), cross lane classified"
    else
        bad "[$EVENT] audit red: rc=$RC out=<<$OUT>>"
    fi
done

# 14. (item 3) The per-event wait BUDGET resolves from --event-name alone (no
#     --timeout-s): workflow_dispatch -> the short bounded window (300s); every
#     other event -> the full ruleset timeout (5400s). --print-budget renders the
#     resolved budget and exits before any poll. This pins that the event changes
#     only the BUDGET, never the lane set (13).
echo "--- per-event wait budget resolves without --timeout-s (item 3) ---"
declare -A EXPECT_BUDGET=( [pull_request]=5400 [merge_group]=5400 [push]=5400 [workflow_dispatch]=300 )
for EV in pull_request merge_group push workflow_dispatch; do
    got="$(bash "$WAIT" --print-budget --event-name "$EV" \
            --lane "test=success" --cross "audit" 2>&1)"
    exp="${EXPECT_BUDGET[$EV]}"
    if [[ "$got" == "BUDGET_S=$exp" ]]; then
        ok "budget for $EV resolves to ${exp}s (no --timeout-s)"
    else
        bad "budget for $EV: expected BUDGET_S=$exp, got <<$got>>"
    fi
done

rm -f "$CNT" "$AMB"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
