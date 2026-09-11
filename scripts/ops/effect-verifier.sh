#!/usr/bin/env bash
# scripts/ops/effect-verifier.sh — RESILIENT-1109 (Outcome-Verification,
# umbrella RESILIENT-1103, Track B sub-gap 2 of docs/design/DESIGN_GAPS_SELF_RUNNING.md).
#
# WHY THIS EXISTS. organ-success-verifier.sh (RESILIENT-1108) closes the
# "exit-fail hidden behind a green timer" blind spot (systemd's `Result` /
# `ExecMainStatus`). It does NOT close the sibling blind spot named explicitly
# in the design doc: an organ that exits 0 and reports success on every run,
# yet produces NO EFFECT — the farmer ticking against a non-empty pickable
# queue and claiming nothing, tick after tick, while its own heartbeat says
# "fine". `systemctl show` sees `Result=success` for every one of those ticks;
# organ-success-verifier is structurally blind to it. This organ watches for
# that shape directly: heartbeats are landing (the organ IS running), but the
# effect the organ exists to produce (a claim) is not.
#
# ALGORITHM, every cycle (oneshot, run via a timer):
#   1. Count `farmer_heartbeat` ambient events in the trailing window — this is
#      the organ's own "I ran and exited 0" signal (scripts/coord/farmer.sh
#      emits one at the end of every tick, success or not).
#   2. Count `gap_claimed` ambient events in the SAME window — the effect a
#      non-empty pickable queue should be producing.
#   3. Read the current pickable-gap count from state.db (status='open',
#      mirrors queue-stagnation-monitor.sh's query — INFRA-2353).
#   4. Classify NO-OP iff: heartbeats >= MIN_TICKS (the organ genuinely ran
#      enough times to trust the sample) AND pickable > MIN_PICKABLE (there
#      was real work) AND claimed == 0 (nothing came of it). A queue that is
#      legitimately empty (pickable <= MIN_PICKABLE) is NOT a no-op — an idle
#      farmer doing nothing about nothing is correct, not broken.
#   5. Page via notify_operator (kind=organ_effect_noop, page in the
#      escalation registry), deduped per organ within
#      CHUMP_EFFECT_VERIFIER_DEDUP_WINDOW_S so a still-stuck organ pages once
#      per window, not every cycle (same discipline as organ-success-verifier).
#   6. Emit a per-cycle summary: kind=effect_verify_tick.
#
# Deliberately narrow scope for v1: one organ (chump-farmer.timer / the
# pickable-queue effect). The detection shape (heartbeat-count vs.
# effect-count vs. a "was there real work" gate) generalizes to any future
# key organ with a declared heartbeat kind + effect kind — add a case to
# `_check_organ` below rather than a bespoke sibling script.
#
# Usage:
#   scripts/ops/effect-verifier.sh            # scan + page
#   scripts/ops/effect-verifier.sh --dry-run  # classify + summarize, no page
#
# Env / test hooks:
#   CHUMP_EFFECT_VERIFIER_STATE_DB       override state.db path (tests)
#   CHUMP_EFFECT_VERIFIER_STATE_DIR      override dedup state dir
#   CHUMP_EFFECT_VERIFIER_WINDOW_S       trailing window, default 1800 (30min)
#   CHUMP_EFFECT_VERIFIER_MIN_TICKS      min heartbeats to trust the sample, default 3
#   CHUMP_EFFECT_VERIFIER_MIN_PICKABLE   pickable-count floor to call it "real work", default 1
#   CHUMP_EFFECT_VERIFIER_DEDUP_WINDOW_S default 3600 (1h) — one page per stuck organ per window
#   CHUMP_AMBIENT_LOG                    override ambient.jsonl path
#   REPO_ROOT / CHUMP_REPO_ROOT          repo checkout root
#
# Exit codes:
#   0  always (a NO-OP organ is a PAGE, not a non-zero exit — the verifier
#      itself succeeded at its job of noticing)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_DB="${CHUMP_EFFECT_VERIFIER_STATE_DB:-$REPO_ROOT/.chump/state.db}"
STATE_DIR="${CHUMP_EFFECT_VERIFIER_STATE_DIR:-$REPO_ROOT/.chump-locks/effect-verifier}"
WINDOW_S="${CHUMP_EFFECT_VERIFIER_WINDOW_S:-1800}"
MIN_TICKS="${CHUMP_EFFECT_VERIFIER_MIN_TICKS:-3}"
MIN_PICKABLE="${CHUMP_EFFECT_VERIFIER_MIN_PICKABLE:-1}"
DEDUP_WINDOW_S="${CHUMP_EFFECT_VERIFIER_DEDUP_WINDOW_S:-3600}"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$AMB")" 2>/dev/null || true
touch "$AMB" 2>/dev/null || true

export CHUMP_AMBIENT_LOG="$AMB"

# shellcheck source=../coord/lib/notify-operator.sh
if [[ -f "$SCRIPT_DIR/../coord/lib/notify-operator.sh" ]]; then
    source "$SCRIPT_DIR/../coord/lib/notify-operator.sh"
else
    notify_operator() { echo "[effect-verifier] notify-operator.sh MISSING" >&2; return 1; }
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date -u +%s; }

_emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local dry_run_json="false"
    [[ "$DRY_RUN" -eq 1 ]] && dry_run_json="true"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry_run_json,$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry_run_json}"; fi
    printf '%s\n' "$line" >> "$AMB" 2>/dev/null || true
}

# Count ambient events of a given `kind` whose ts falls within the trailing
# WINDOW_S seconds. Pure awk/date, no python dependency — this organ must run
# on the same minimal-toolchain nodes as farmer.sh itself.
_count_recent_kind() {  # kind, window_s
    local kind="$1" window="$2"
    [[ -f "$AMB" ]] || { echo 0; return; }
    local now; now="$(_now_epoch)"
    local since=$(( now - window ))
    local n=0
    local line ts_field epoch
    while IFS= read -r line; do
        case "$line" in
            *"\"kind\":\"$kind\""*) ;;
            *) continue ;;
        esac
        ts_field="${line#*\"ts\":\"}"
        ts_field="${ts_field%%\"*}"
        epoch="$(date -u -d "$ts_field" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts_field" +%s 2>/dev/null || echo 0)"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        if (( epoch >= since )); then
            n=$(( n + 1 ))
        fi
    done < "$AMB"
    echo "$n"
}

_pickable_count() {
    local n=0
    if [[ -f "$STATE_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
        n="$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps WHERE status='open';" 2>/dev/null || echo 0)"
    fi
    n="${n//[[:space:]]/}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    echo "$n"
}

# Per-(organ) dedup: has a NO-OP for this organ already paged inside the
# dedup window? Mirrors organ-success-verifier.sh's marker-file approach.
_dedup_marker() { printf '%s/%s.noop' "$STATE_DIR" "$1"; }

_recently_paged() {  # organ
    local marker; marker="$(_dedup_marker "$1")"
    [[ -f "$marker" ]] || return 1
    local last; last="$(cat "$marker" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    local now; now="$(_now_epoch)"
    (( now - last < DEDUP_WINDOW_S ))
}

_mark_paged() { printf '%s\n' "$(_now_epoch)" > "$(_dedup_marker "$1")" 2>/dev/null || true; }

checked_total=0
noop_total=0
ok_total=0
noop_names=""

# _check_organ ORGAN HEARTBEAT_KIND EFFECT_KIND — the generalizable shape:
# "did this organ run enough to trust the sample, was there real work for it
# to do, and did the expected effect land?"
_check_organ() {
    local organ="$1" heartbeat_kind="$2" effect_kind="$3"
    checked_total=$(( checked_total + 1 ))

    local heartbeats claimed pickable
    heartbeats="$(_count_recent_kind "$heartbeat_kind" "$WINDOW_S")"
    claimed="$(_count_recent_kind "$effect_kind" "$WINDOW_S")"
    pickable="$(_pickable_count)"

    if (( heartbeats < MIN_TICKS )); then
        # Not enough ticks yet to trust the sample — organ-success-verifier
        # owns "is it ticking at all"; avoid a false-positive on a fresh boot.
        ok_total=$(( ok_total + 1 ))
        return
    fi

    if (( pickable > MIN_PICKABLE && claimed == 0 )); then
        noop_total=$(( noop_total + 1 ))
        noop_names="${noop_names:+$noop_names,}$organ"
        local detail="\"organ\":\"$organ\",\"heartbeat_kind\":\"$heartbeat_kind\",\"effect_kind\":\"$effect_kind\",\"heartbeats\":$heartbeats,\"claimed\":$claimed,\"pickable\":$pickable,\"window_s\":$WINDOW_S"
        if _recently_paged "$organ"; then
            # scanner-anchor: "kind":"organ_effect_noop_dedup_skip"
            _emit "organ_effect_noop_dedup_skip" "$detail"
        else
            # scanner-anchor: "kind":"organ_effect_noop"
            _emit "organ_effect_noop" "$detail"
            if [[ "$DRY_RUN" -eq 0 ]]; then
                CHUMP_NOTIFY_KIND="organ_effect_noop" \
                notify_operator "🛑 **Organ ${organ} is exit-0-but-no-op.** It heartbeat ${heartbeats}x and claimed 0 of ${pickable} pickable gaps in the last $((WINDOW_S/60))min." || true
                _mark_paged "$organ"
            fi
        fi
    else
        ok_total=$(( ok_total + 1 ))
    fi
}

# ── v1: the one key organ named in the design doc ──────────────────────────
_check_organ "chump-farmer.timer" "farmer_heartbeat" "gap_claimed"

# scanner-anchor: "kind":"effect_verify_tick"
_emit "effect_verify_tick" "\"checked_total\":$checked_total,\"ok_total\":$ok_total,\"noop_total\":$noop_total,\"noop_organs\":\"$noop_names\""

exit 0
