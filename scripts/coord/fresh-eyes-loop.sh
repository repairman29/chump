#!/usr/bin/env bash
# scripts/coord/fresh-eyes-loop.sh — Chump curator-opus-fresh-eyes role CLI (harness-neutral)
#
# Productizes the curator-opus-fresh-eyes ("mirror") role per META-132.
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way. The .claude/agents/fresh-eyes.md + .claude/skills/fresh-eyes/
# wrappers delegate here; they are convenience, not capability.
#
# Role: a periodic self-consistency audit that compares the fleet's
# SELF-REPORTS (fleet-brief banner, SLO check, curator heartbeats, detector
# coverage, roadmap intent) to GROUND TRUTH (the ambient stream, git history,
# the event registry). It catches the failure class no other curator owns:
# "the system self-reports healthy while the actual stream shows fire."
# Demonstrated 2026-05-30 — a trunk-red signal 4 alive curators missed for
# 32 min while fleet-brief said "No urgent actions".
#
# ANTI-NOISE DISCIPLINE (META-132 AC10): emits exactly ONE finding per cycle
# (rank-1 by severity). Over-cap findings spill to .chump/fresh-eyes/backlog.jsonl
# for the next cycle. fresh-eyes NEVER picks gaps, never rescues PRs, never
# dispatches sub-agents — it files advisory observable signals only. Lane
# refusal is in .claude/agents/fresh-eyes.md.
#
# Rust-First-Bypass: glue between grep + git + chump CLI + ambient.jsonl;
# read-only (no state mutation beyond append-idempotent ambient emit lines);
# exploratory comparator surface still settling. Port to Rust as a follow-up
# if the comparator set grows past the shell-OK criteria (META-064).
#
# Usage:
#   scripts/coord/fresh-eyes-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick                 One cycle: run all 5 comparators, emit the rank-1
#                        finding (anti-noise), spill the rest to backlog.
#                        Exit 0 if a disagreement found, 1 if all-clear,
#                        2 bad input, 3 state unreadable.
#   audit                Alias of tick that ALSO prints every comparator's
#                        result line to stdout (not just the rank-1).
#   heartbeat            Emit kind=fresh_eyes_heartbeat. Exit 0 always.
#   help                 Print this help.
#
# Exit codes:
#   0 — actionable: at least one comparator disagreed (finding emitted)
#   1 — all-clear: self-reports matched ground truth (the GOOD outcome)
#   2 — bad subcommand or missing required arg
#   3 — required state (ambient.jsonl) not found
#
# Env:
#   CHUMP_SESSION_ID            session id for ambient emits (default fresh-eyes-<pid>)
#   CHUMP_AMBIENT_LOG           ambient.jsonl path override
#   CHUMP_FRESH_EYES_WINDOW_MIN comparator window in minutes (default 30)
#   CHUMP_FRESH_EYES_BRIEF_CMD  command whose stdout is the fleet-brief banner
#                               (default: scripts/dispatch/fleet-brief.sh)
#   CHUMP_FRESH_EYES_SLO_CMD    command whose EXIT CODE is the SLO verdict
#                               (default: chump health --slo-check; non-zero=breach)
#   CHUMP_FRESH_EYES_ROADMAP    docs/ROADMAP.md path override
#   CHUMP_FRESH_EYES_REGISTRY   EVENT_REGISTRY.yaml path override
#   CHUMP_FRESH_EYES_LOOPS_DIR  curator-loop dir for coverage scan (default scripts/coord)
#   CHUMP_FRESH_EYES_SHIPS_CMD  command whose stdout is recent shipped PR titles
#                               (default: git log --since=7.days --pretty=%s)
#   CHUMP_FRESH_EYES_BACKLOG    backlog.jsonl path override

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-fresh-eyes-$$}"
WINDOW_MIN="${CHUMP_FRESH_EYES_WINDOW_MIN:-30}"
BRIEF_CMD="${CHUMP_FRESH_EYES_BRIEF_CMD:-$REPO_ROOT/scripts/dispatch/fleet-brief.sh}"
SLO_CMD="${CHUMP_FRESH_EYES_SLO_CMD:-chump health --slo-check}"
ROADMAP="${CHUMP_FRESH_EYES_ROADMAP:-$REPO_ROOT/docs/ROADMAP.md}"
REGISTRY="${CHUMP_FRESH_EYES_REGISTRY:-$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml}"
LOOPS_DIR="${CHUMP_FRESH_EYES_LOOPS_DIR:-$REPO_ROOT/scripts/coord}"
SHIPS_CMD="${CHUMP_FRESH_EYES_SHIPS_CMD:-}"
BACKLOG="${CHUMP_FRESH_EYES_BACKLOG:-$MAIN_REPO/.chump/fresh-eyes/backlog.jsonl}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Helpers ───────────────────────────────────────────────────────────────────

_emit() {
    # _emit kind [extra_json_fields...]
    local kind="$1"; shift
    local extras=""
    local kv
    for kv in "$@"; do extras="$extras, $kv"; done
    printf '{"ts":"%s","kind":"%s","session":"%s"%s}\n' \
        "$(_now_iso)" "$kind" "$SESSION_ID" "$extras" \
        >> "$AMBIENT" 2>/dev/null || true
}
# scanner-anchor: "kind":"fresh_eyes_heartbeat"
# scanner-anchor: "kind":"fresh_eyes_tick"
# scanner-anchor: "kind":"fresh_eyes_disagreement"
# scanner-anchor: "kind":"fresh_eyes_coverage_gap"
# scanner-anchor: "kind":"fresh_eyes_silent_curator"

_json_escape() {
    # Minimal JSON string escaper for the detail field (quotes + backslashes).
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

_iso_minutes_ago() {
    # Portable "N minutes ago" in ISO-8601 UTC. BSD date first, GNU fallback.
    local n="$1"
    date -u -v-"${n}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "${n} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || _now_iso
}

_count_ambient_since() {
    # _count_ambient_since <iso_cutoff> <kind_regex> → count of matching lines
    # whose "ts" is >= cutoff. Lexicographic compare works for ISO-8601 UTC.
    local cutoff="$1" kind_re="$2"
    [[ -f "$AMBIENT" ]] || { printf '0'; return 0; }
    awk -v cut="$cutoff" -v kre="$kind_re" '
        {
            ts=""
            if (match($0, /"ts":"[^"]+"/)) ts=substr($0, RSTART+6, RLENGTH-7)
            if (ts >= cut && $0 ~ kre) c++
        }
        END { printf "%d", c+0 }
    ' "$AMBIENT" 2>/dev/null || printf '0'
}

# Findings accumulate as severity<TAB>comparator_id<TAB>kind<TAB>detail lines.
FINDINGS_FILE=""
_add_finding() {
    # _add_finding <severity hi|med|lo> <comparator_id> <emit_kind> <detail>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$FINDINGS_FILE"
}

# ── Comparators ─────────────────────────────────────────────────────────────────

_brief_says_healthy() {
    # Returns 0 if the fleet-brief banner claims health ("No urgent" / "healthy").
    local txt
    txt="$(timeout 20 bash -c "$BRIEF_CMD" 2>/dev/null || true)"
    [[ -z "$txt" ]] && return 1
    printf '%s' "$txt" | grep -qiE 'no urgent action|looks healthy|fleet looks healthy'
}

comparator_1() {
    # fleet-brief banner "healthy" vs fire in the ambient stream (last window).
    local cutoff fire
    cutoff="$(_iso_minutes_ago "$WINDOW_MIN")"
    fire="$(_count_ambient_since "$cutoff" '"kind":"(regression_attributed|pr_stuck|pr_stuck_cluster|silent_agent|trunk_red_dispatch|slo_breach)"')"
    if _brief_says_healthy && [[ "$fire" -gt 0 ]]; then
        _add_finding hi 1 fresh_eyes_disagreement \
            "fleet-brief says healthy but ${fire} fire-events (regression/pr_stuck/silent_agent/slo_breach) in last ${WINDOW_MIN}min"
    fi
}

comparator_4() {
    # fleet-brief "healthy" vs chump health --slo-check exit (non-zero = breach).
    local slo_rc=0
    _brief_says_healthy || return 0   # only a disagreement if brief claims health
    timeout 30 bash -c "$SLO_CMD" >/dev/null 2>&1 || slo_rc=$?
    if [[ "$slo_rc" -ne 0 ]]; then
        _add_finding hi 4 fresh_eyes_disagreement \
            "fleet-brief says healthy but '${SLO_CMD}' exits ${slo_rc} (SLO breach)"
    fi
}

comparator_3() {
    # Per-curator heartbeat-without-action over the window (silent_agent root).
    [[ -f "$AMBIENT" ]] || return 0
    local cutoff
    cutoff="$(_iso_minutes_ago "$WINDOW_MIN")"
    # Sessions that emitted a heartbeat in-window but no action (sub_agent_dispatched / DONE).
    local silent
    silent="$(awk -v cut="$cutoff" '
        {
            ts=""; sess=""
            if (match($0, /"ts":"[^"]+"/))      ts=substr($0, RSTART+6, RLENGTH-7)
            if (ts < cut) next
            if (match($0, /"session":"[^"]+"/)) sess=substr($0, RSTART+11, RLENGTH-12)
            if (sess == "") next
            if ($0 ~ /heartbeat/)                                  hb[sess]++
            if ($0 ~ /"(sub_agent_dispatched)"/ || $0 ~ /"event":"DONE"/ || $0 ~ /ship_landed/) act[sess]++
        }
        END { for (s in hb) if (act[s]+0 == 0) print s }
    ' "$AMBIENT" 2>/dev/null | head -1 || true)"
    if [[ -n "$silent" ]]; then
        _add_finding med 3 fresh_eyes_silent_curator \
            "curator ${silent} emitted heartbeats but 0 actions (dispatch/DONE/ship) in last ${WINDOW_MIN}min — silent_agent candidate"
    fi
}

comparator_5() {
    # ROADMAP bottleneck pillar vs last-7d shipped PR pillar distribution.
    [[ -f "$ROADMAP" ]] || return 0
    # Bottleneck pillar = first pillar tag the roadmap marks current/bottleneck.
    local bottleneck
    bottleneck="$(grep -ioE '(EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE)' "$ROADMAP" 2>/dev/null | head -1 || true)"
    [[ -z "$bottleneck" ]] && return 0
    # Count last-7d shipped PR titles carrying the bottleneck pillar tag.
    local total hit titles
    if [[ -n "$SHIPS_CMD" ]]; then
        titles="$(timeout 15 bash -c "$SHIPS_CMD" 2>/dev/null || true)"
    else
        titles="$(git -C "$REPO_ROOT" log --since='7 days ago' --pretty=%s 2>/dev/null || true)"
    fi
    total="$(printf '%s\n' "$titles" | grep -cE '\(#[0-9]+\)' || true)"
    total="${total:-0}"
    [[ "$total" -eq 0 ]] && return 0
    hit="$(printf '%s\n' "$titles" | grep -ciE "$bottleneck" || true)"
    hit="${hit:-0}"
    # Starved if the bottleneck pillar is < 10% of shipped titles.
    local pct=$(( hit * 100 / total ))
    if [[ "$pct" -lt 10 ]]; then
        _add_finding med 5 fresh_eyes_disagreement \
            "ROADMAP bottleneck pillar ${bottleneck} got only ${hit}/${total} (${pct}%) of last-7d ships — starved"
    fi
}

comparator_2() {
    # Registered event kinds with zero curator-loop coverage (grep union).
    [[ -f "$REGISTRY" ]] || return 0
    [[ -d "$LOOPS_DIR" ]] || return 0
    # Kinds the loops actually grep for / emit (scanner-anchors + grep patterns).
    local covered_tmp
    covered_tmp="$(mktemp)"
    grep -rhoE '"kind":"[a-z0-9_]+"' "$LOOPS_DIR"/*-loop.sh 2>/dev/null \
        | sed -E 's/.*"kind":"([a-z0-9_]+)".*/\1/' | sort -u > "$covered_tmp" || true
    # Registered kinds (top-level keys under the registry's kinds: map).
    local first_uncovered count
    count=0; first_uncovered=""
    while IFS= read -r kind; do
        [[ -z "$kind" ]] && continue
        if ! grep -qxF "$kind" "$covered_tmp" 2>/dev/null; then
            count=$((count + 1))
            [[ -z "$first_uncovered" ]] && first_uncovered="$kind"
        fi
    done < <(grep -oE '^  - kind: [a-z0-9_]+' "$REGISTRY" 2>/dev/null | sed -E 's/^  - kind: //' | sort -u || true)
    rm -f "$covered_tmp"
    if [[ "$count" -gt 0 ]]; then
        _add_finding lo 2 fresh_eyes_coverage_gap \
            "${count} registered ambient kinds have zero curator-loop coverage (e.g. ${first_uncovered}) — emit-without-watch drift"
    fi
}

# ── Cycle ───────────────────────────────────────────────────────────────────────

_run_cycle() {
    # Runs all comparators, emits the rank-1 finding, spills rest to backlog.
    # $1 = "verbose" to also print every comparator result line.
    local verbose="${1:-}"
    if [[ ! -f "$AMBIENT" ]]; then
        printf 'ERROR: ambient stream not found: %s\n' "$AMBIENT" >&2
        exit 3
    fi
    FINDINGS_FILE="$(mktemp)"

    comparator_1 || true
    comparator_4 || true
    comparator_3 || true
    comparator_5 || true
    comparator_2 || true

    _emit "fresh_eyes_tick" '"window_min":'"$WINDOW_MIN"

    if [[ ! -s "$FINDINGS_FILE" ]]; then
        rm -f "$FINDINGS_FILE"
        printf 'fresh-eyes: all-clear — self-reports match ground truth (window=%smin).\n' "$WINDOW_MIN"
        return 1
    fi

    # Rank: hi > med > lo, then by comparator id ascending. Stable sort.
    local ranked
    ranked="$(awk -F'\t' '
        { sev=$1; w=(sev=="hi"?0:(sev=="med"?1:2)); printf "%d\t%s\t%s\n", w, $2, $0 }
    ' "$FINDINGS_FILE" | sort -t$'\t' -k1,1n -k2,2n)"

    if [[ "$verbose" == "verbose" ]]; then
        printf 'fresh-eyes: %d disagreement(s) this cycle (anti-noise: emitting rank-1 only):\n' \
            "$(printf '%s\n' "$ranked" | grep -c . || true)"
        printf '%s\n' "$ranked" | awk -F'\t' '{printf "  [%s] C%s %s — %s\n", $3, $4, $5, $6}'
    fi

    # Rank-1 line fields: w<TAB>cid<TAB>severity<TAB>cid<TAB>kind<TAB>detail
    local top sev cid kind detail
    top="$(printf '%s\n' "$ranked" | head -1)"
    sev="$(printf '%s' "$top" | cut -f3)"
    cid="$(printf '%s' "$top" | cut -f4)"
    kind="$(printf '%s' "$top" | cut -f5)"
    detail="$(printf '%s' "$top" | cut -f6)"

    _emit "$kind" \
        '"comparator_id":'"$cid" \
        '"severity":"'"$sev"'"' \
        '"detail":"'"$(_json_escape "$detail")"'"'

    printf 'fresh-eyes FINDING [%s] comparator %s → %s\n  %s\n' "$sev" "$cid" "$kind" "$detail"

    # Spill the rest to the backlog for next cycle (anti-noise).
    local rest
    rest="$(printf '%s\n' "$ranked" | tail -n +2)"
    if [[ -n "$rest" ]]; then
        mkdir -p "$(dirname "$BACKLOG")" 2>/dev/null || true
        printf '%s\n' "$rest" | while IFS=$'\t' read -r _w _bcid bsev bcid2 bkind bdetail; do
            printf '{"ts":"%s","kind":"%s","comparator_id":%s,"severity":"%s","detail":"%s","deferred_by":"anti-noise"}\n' \
                "$(_now_iso)" "$bkind" "$bcid2" "$bsev" "$(_json_escape "$bdetail")" \
                >> "$BACKLOG" 2>/dev/null || true
        done
        printf '  (%d more finding(s) spilled to backlog: %s)\n' \
            "$(printf '%s\n' "$rest" | grep -c . || true)" "$BACKLOG"
    fi

    rm -f "$FINDINGS_FILE"
    return 0
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_tick()      { _run_cycle ""; }
cmd_audit()     { _run_cycle verbose; }
cmd_heartbeat() {
    _emit "fresh_eyes_heartbeat"
    printf 'fresh-eyes heartbeat: %s session=%s\n' "$(_now_iso)" "$SESSION_ID"
    return 0
}
cmd_help() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//' | head -60
    return 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

SUBCMD="${1:-help}"
shift || true

case "$SUBCMD" in
    tick)
        # INFRA-2262: read the fleet wire before doing tick work.
        "$(dirname "$0")/ambient-context-inject.sh" --tick-preamble fresh-eyes 2>/dev/null || true
        _TICK_RC=0
        cmd_tick "$@" || _TICK_RC=$?
        # CREDIBLE-084: emit tick_outcome for no-idle audit + observability.
        "$(dirname "$0")/ambient-context-inject.sh" --tick-outcome fresh-eyes "$_TICK_RC" 2>/dev/null || true
        exit "$_TICK_RC"
        ;;
    audit)       cmd_audit "$@" ;;
    heartbeat)   cmd_heartbeat "$@" ;;
    help|--help) cmd_help "$@" ;;
    *)
        printf 'Unknown subcommand: %s\nRun: %s help\n' "$SUBCMD" "$0" >&2
        exit 2
        ;;
esac
