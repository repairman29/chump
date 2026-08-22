#!/usr/bin/env bash
# board-cycle-escalate.sh — RESILIENT-373: severity-gated, deduped escalation
# for the board-cycle beat, so a routine board report NEVER pages the phone.
#
# WHY THIS EXISTS. On 2026-08-22 the board-cycle beat (board-cycle-beat.sh,
# INFRA-3590) paged the operator's phone on EVERY cycle — 38 operator_paged
# events in 24h, ~half of them `sla_breaches:0` clean-cycle firehose, and the
# rest re-paging the SAME unresolved breach (17 stuck PRs) every 15 minutes.
# Two failure shapes, one root: the beat used notify_operator (the
# escalation-to-PHONE channel) as its ROUTINE report channel. Because the LLM
# agent inconsistently set CHUMP_NOTIFY_KIND, pages split into 18
# `board_cycle_report` (registry default = page) + 20 `unclassified-caller`
# (no kind = novel = page). Either way: cry-wolf, every cycle. Jeff's standing
# order (RESILIENT-274, 2026-08-10): "don't hear from the fleet unless it's way
# out of line or we don't have a playbook for it." A 15-minute "all green" DM is
# exactly the firehose he killed.
#
# THE FIX (root, not mop). Take the paging decision OUT of the LLM and make it
# deterministic in the beat:
#   * The agent now only SCORES + CLASSIFIES and emits ONE structured
#     `board_cycle_report_posted` ambient line (sla_breaches, oldest_breach_age_min,
#     stalls, root_cause, summary). It no longer calls notify_operator.
#   * This organ reads that structured line and pages ONLY when there is
#     something to act on (sla_breaches > 0), never on a clean cycle, and
#     DEDUPES a persisting breach so the same condition pages ONCE per window,
#     not every cycle. A genuine breach still reaches the phone — the signal is
#     preserved, only the noise is removed (honest instrument, not a blind mute).
#
# CONTRACT:
#   board_cycle_escalate <since_epoch>
#     since_epoch  — unix seconds; the beat's start time. Only a
#                    board_cycle_report_posted line at/after this is considered
#                    (so an old line from a prior cycle is never re-paged).
#     → always returns 0 (an escalation organ must never break the beat it
#       reports on — same invariant as notify-operator.sh).
#
# ENV:
#   CHUMP_AMBIENT_LOG              ambient log to read + emit into
#   CHUMP_BOARD_ESCALATE_STATE_DIR dedup/state dir (default .chump-locks/board-escalate)
#   CHUMP_BOARD_ESCALATE_WINDOW_S  dedup window seconds (default 7200 = 2h)
#
# shellcheck shell=bash

_bce_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd
}

_bce_ambient_log() {
    local root; root="$(_bce_repo_root)"
    printf '%s\n' "${CHUMP_AMBIENT_LOG:-${root}/.chump-locks/ambient.jsonl}"
}

_bce_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_bce_now_epoch() { date -u +%s; }

_bce_emit() {  # kind, extra-json (no leading/trailing comma)
    local log; log="$(_bce_ambient_log)"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    local ts; ts="$(_bce_ts)"
    if [[ -n "${2:-}" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$1" "$2" >> "$log" 2>/dev/null || true
    else
        printf '{"ts":"%s","kind":"%s"}\n' "$ts" "$1" >> "$log" 2>/dev/null || true
    fi
}

# Parse the NEWEST board_cycle_report_posted line whose ts-epoch >= since_epoch.
# Prints one JSON object to stdout (the raw line's payload) or nothing.
_bce_latest_report() {  # since_epoch
    local log since
    log="$(_bce_ambient_log)"; since="$1"
    [[ -f "$log" ]] || return 0
    SINCE="$since" python3 - "$log" <<'PY' 2>/dev/null || true
import sys, json, os
from datetime import datetime, timezone
since = int(os.environ.get("SINCE", "0"))
best = None
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line or '"board_cycle_report_posted"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("kind") != "board_cycle_report_posted":
                continue
            ts = o.get("ts", "")
            try:
                ep = int(datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                         .replace(tzinfo=timezone.utc).timestamp())
            except Exception:
                ep = 0
            if ep >= since:
                best = o  # last one wins == newest, log is append-ordered
except Exception:
    pass
if best is not None:
    print(json.dumps(best))
PY
}

# Was a board_cycle_report_failed with an escalation emitted since since_epoch?
# (harness/permission failure the agent itself flagged operator_decision_required)
_bce_failed_since() {  # since_epoch
    local log since
    log="$(_bce_ambient_log)"; since="$1"
    [[ -f "$log" ]] || return 1
    SINCE="$since" python3 - "$log" <<'PY' 2>/dev/null
import sys, json, os
from datetime import datetime, timezone
since = int(os.environ.get("SINCE", "0"))
found = ""
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if '"board_cycle_report_failed"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("kind") != "board_cycle_report_failed":
                continue
            try:
                ep = int(datetime.strptime(o.get("ts",""), "%Y-%m-%dT%H:%M:%SZ")
                         .replace(tzinfo=timezone.utc).timestamp())
            except Exception:
                ep = 0
            if ep >= since and o.get("escalation"):
                found = o.get("summary") or o.get("reason") or "board cycle could not run"
except Exception:
    pass
print(found)
PY
}

_bce_field() {  # json, key  -> value or ""
    KEY="$2" python3 - <<PY 2>/dev/null
import sys, json, os
try:
    o = json.loads('''$1''')
except Exception:
    o = {}
v = o.get(os.environ["KEY"], "")
print("" if v is None else v)
PY
}

# Main entry. Deterministic paging decision from the structured report.
board_cycle_escalate() {
    local since_epoch="${1:-0}"
    local state_dir window
    state_dir="${CHUMP_BOARD_ESCALATE_STATE_DIR:-$(_bce_repo_root)/.chump-locks/board-escalate}"
    window="${CHUMP_BOARD_ESCALATE_WINDOW_S:-7200}"
    mkdir -p "$state_dir" 2>/dev/null || true

    # Resolve notify_operator (source the sibling lib; no-op stub if absent so
    # the organ is still testable without the notifier present).
    if ! declare -F notify_operator >/dev/null 2>&1; then
        local sib; sib="$(dirname "${BASH_SOURCE[0]}")/notify-operator.sh"
        if [[ -f "$sib" ]]; then
            # shellcheck source=notify-operator.sh
            source "$sib"
        else
            notify_operator() { echo "[board-cycle-escalate] notify-operator.sh MISSING" >&2; return 0; }
        fi
    fi

    local report; report="$(_bce_latest_report "$since_epoch")"

    if [[ -z "$report" ]]; then
        # No structured report this cycle. If the agent flagged an explicit
        # run failure, that IS page-worthy (novel/no-playbook) — but dedupe it
        # so a wedged harness doesn't page every 15 min.
        local failsum; failsum="$(_bce_failed_since "$since_epoch")"
        if [[ -n "$failsum" ]]; then
            _bce_maybe_page "board_cycle_run_failed" "$state_dir" "$window" \
                "🛑 **Board cycle could not run.** ${failsum}"
        else
            _bce_emit "board_cycle_escalate_noop" "\"reason\":\"no_report_no_failure\""
        fi
        return 0
    fi

    local breaches oldest stalls root_cause summary detail
    breaches="$(_bce_field "$report" sla_breaches)"
    oldest="$(_bce_field "$report" oldest_breach_age_min)"
    stalls="$(_bce_field "$report" stalls_classified)"
    root_cause="$(_bce_field "$report" root_cause)"
    summary="$(_bce_field "$report" summary)"
    detail="$(_bce_field "$report" detail)"
    [[ "$breaches" =~ ^[0-9]+$ ]] || breaches=0

    if (( breaches == 0 )); then
        # Clean cycle — the whole point: this NEVER pages the phone.
        _bce_emit "board_cycle_page_suppressed_clean" \
            "\"sla_breaches\":0,\"stalls_classified\":\"${stalls}\""
        return 0
    fi

    # Breach present. Signature = root_cause if given, else a coarse breach
    # bucket, so a *persisting* breach pages ONCE per window and a *changed*
    # breach re-pages.
    local sig
    if [[ -n "$root_cause" ]]; then
        sig="rc:${root_cause}"
    else
        local bucket
        if   (( breaches >= 10 )); then bucket="10+"
        elif (( breaches >= 3 ));  then bucket="3-9"
        else bucket="1-2"; fi
        sig="breaches:${bucket}"
    fi

    local msg="🚨 **Board cycle — SLA breach.** ${breaches} PR(s) past the 30m merge SLA"
    [[ "$oldest" =~ ^[0-9]+$ ]] && (( oldest > 0 )) && msg+=", oldest ${oldest}m"
    msg+="."
    [[ -n "$root_cause" ]] && msg+=$'\n'"root_cause: ${root_cause}"
    [[ -n "$summary" ]]    && msg+=$'\n'"${summary}"
    [[ -n "$detail" ]]     && msg+=$'\n'"${detail}"
    msg+=$'\n'"(pages once per $((window/60))m per breach signature — board-cycle-escalate.sh)"

    _bce_maybe_page "$sig" "$state_dir" "$window" "$msg" "$breaches" "$oldest" "$root_cause"
    return 0
}

# _bce_maybe_page <signature> <state_dir> <window_s> <message> [breaches oldest root_cause]
# Pages via notify_operator (kind=board_cycle_alert → registry PAGE) unless the
# same signature paged inside the window. Emits an ambient trail either way.
_bce_maybe_page() {
    local sig="$1" state_dir="$2" window="$3" msg="$4"
    local breaches="${5:-}" oldest="${6:-}" root_cause="${7:-}"
    local sigfile; sigfile="$state_dir/$(printf '%s' "$sig" | tr '/ :.' '____').json"

    if [[ -f "$sigfile" ]]; then
        local last; last="$(python3 -c "import json;print(json.load(open('$sigfile')).get('last_epoch',0))" 2>/dev/null || echo 0)"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        local now; now="$(_bce_now_epoch)"
        if (( now - last < window )); then
            _bce_emit "board_cycle_page_deduped" \
                "\"signature\":\"${sig}\",\"sla_breaches\":\"${breaches}\""
            return 0
        fi
    fi

    CHUMP_NOTIFY_KIND="board_cycle_alert" notify_operator "$msg" >/dev/null 2>&1
    local page_rc=$?

    python3 -c "import json;json.dump({'signature':'$sig','last_epoch':$(_bce_now_epoch)}, open('$sigfile','w'))" 2>/dev/null || true

    _bce_emit "board_cycle_page_sent" \
        "\"signature\":\"${sig}\",\"sla_breaches\":\"${breaches}\",\"notify_rc\":${page_rc}"
    return 0
}

# Direct-execution entry point (mirrors notify-operator.sh's INFRA-3602 rule):
#   board-cycle-escalate.sh <since_epoch>
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    board_cycle_escalate "${1:-0}"
fi
