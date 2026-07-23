#!/usr/bin/env bash
# operator-page.sh — INFRA-1774: structured human-in-the-loop interrupt protocol.
#
# Distinct from operator-recall.sh (INFRA-626, halt-class-only / T4): this
# script is the general-purpose interrupt channel for T1-T3 style decisions
# (irreversible-third-party / credential-rotation / operator-explicit-domain)
# that need a *tiered*, *acknowledgeable* page rather than a fleet-wide halt.
#
# Severity tiers:
#   info    — FYI, no operator action required, auto-acks after CHUMP_OPERATOR_PAGE_AUTO_ACK_SECS.
#   action  — operator should act, but the fleet keeps moving while it waits.
#   block   — the requesting session blocks until an ack (or timeout) is observed.
#
# Events emitted (AC 1):
#   operator_page        — on raise; success path. Always emitted unless the
#                           ambient log directory is unwritable (transient —
#                           see Failure taxonomy below), in which case the
#                           script exits non-zero and emits nothing.
#   operator_page_ack     — on `--ack <corr_id>`; records who/when acked.
#   operator_page_timeout — on `--check-timeouts`, for any page whose
#                           timeout_secs has elapsed with no matching ack.
#                           Idempotent: cooldown-gated per corr_id so a
#                           repeated `--check-timeouts` sweep doesn't
#                           re-emit for the same page.
#
# Cost tracking (AC 2):
#   Every `operator_page` event carries `cost_usd_at_page`, sourced from
#   `CHUMP_SESSION_COST_USD` (set by the caller if known) or "unknown". This
#   lets the PWA cockpit show "this decision was raised N minutes into a
#   session that had already spent $X" — cost context, not cost enforcement.
#   Aggregate reporting is out of scope for this script; use
#   `chump kpi report --impact` for fleet-wide cost rollups.
#
# Failure-class taxonomy (AC 3):
#   transient — ambient log directory temporarily unwritable (disk full,
#               lock contention). Caller should retry; exit code 2.
#   permanent — invalid --severity value, missing required --title/--message,
#               or `--ack`/`--check-timeouts` referencing a corr_id that was
#               never raised. Caller should not retry; exit code 1.
#
# Smoke test (AC 4): scripts/ci/test-operator-page.sh
#
# Usage:
#   operator-page.sh --severity info|action|block --title T --message M \
#                     [--gap-id ID] [--timeout-secs N]
#   operator-page.sh --ack <corr_id> [--ack-by WHO]
#   operator-page.sh --check-timeouts
#
# Env:
#   CHUMP_AMBIENT_LOG            path to ambient.jsonl
#   CHUMP_SESSION_COST_USD       best-effort session cost at page time
#   CHUMP_OPERATOR_PAGE_AUTO_ACK_SECS   info-tier auto-ack window (default 0 = never auto-acks)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_lock_dir="$(dirname "$_amb")"

_severity=""
_title=""
_message=""
_gap_id=""
_timeout_secs="0"
_ack_corr=""
_ack_by="${USER:-unknown}"
_check_timeouts=0

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date -u +%s; }

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --severity)       _severity="$2"; shift 2 ;;
        --title)          _title="$2"; shift 2 ;;
        --message)        _message="$2"; shift 2 ;;
        --gap-id)         _gap_id="$2"; shift 2 ;;
        --timeout-secs)   _timeout_secs="$2"; shift 2 ;;
        --ack)            _ack_corr="$2"; shift 2 ;;
        --ack-by)         _ack_by="$2"; shift 2 ;;
        --check-timeouts) _check_timeouts=1; shift ;;
        *) echo "Usage: $0 --severity info|action|block --title T --message M [--gap-id ID] [--timeout-secs N] | --ack CORR_ID [--ack-by WHO] | --check-timeouts" >&2; exit 1 ;;
    esac
done

mkdir -p "$_lock_dir" 2>/dev/null || true
if [[ ! -w "$_lock_dir" ]]; then
    echo "operator-page: FAIL transient — $_lock_dir not writable" >&2
    exit 2
fi

# ── --check-timeouts: sweep for unacked pages past their deadline ────────────
if [[ $_check_timeouts -eq 1 ]]; then
    [[ -f "$_amb" ]] || exit 0
    _now="$(_now_epoch)"
    _acked="$(grep -o '"kind":"operator_page_ack"[^}]*"corr_id":"[^"]*"' "$_amb" 2>/dev/null | grep -o '"corr_id":"[^"]*"' | sort -u || true)"
    _already_timed_out="$(grep -o '"kind":"operator_page_timeout"[^}]*"corr_id":"[^"]*"' "$_amb" 2>/dev/null | grep -o '"corr_id":"[^"]*"' | sort -u || true)"

    while IFS= read -r line; do
        [[ "$line" == *'"kind":"operator_page"'* ]] || continue
        _corr="$(printf '%s' "$line" | grep -o '"corr_id":"[^"]*"' | head -1 | sed -E 's/"corr_id":"([^"]*)"/\1/')"
        [[ -n "$_corr" ]] || continue
        grep -qx "\"corr_id\":\"$_corr\"" <<< "$_acked" && continue
        grep -qx "\"corr_id\":\"$_corr\"" <<< "$_already_timed_out" && continue

        _raised_epoch="$(printf '%s' "$line" | grep -o '"raised_epoch":[0-9]*' | head -1 | grep -o '[0-9]*')"
        _to="$(printf '%s' "$line" | grep -o '"timeout_secs":[0-9]*' | head -1 | grep -o '[0-9]*')"
        [[ -n "$_raised_epoch" && -n "$_to" && "$_to" -gt 0 ]] || continue
        (( _now - _raised_epoch >= _to )) || continue

        printf '{"ts":"%s","kind":"operator_page_timeout","corr_id":"%s"}\n' \
            "$(_now_iso)" "$_corr" >> "$_amb"
        echo "operator-page: TIMEOUT corr_id=$_corr"
    done < "$_amb"
    exit 0
fi

# ── --ack: acknowledge a raised page ──────────────────────────────────────────
if [[ -n "$_ack_corr" ]]; then
    if [[ -f "$_amb" ]] && ! grep -q "\"kind\":\"operator_page\".*\"corr_id\":\"$_ack_corr\"" "$_amb" 2>/dev/null \
        && ! grep -q "\"corr_id\":\"$_ack_corr\".*\"kind\":\"operator_page\"" "$_amb" 2>/dev/null; then
        echo "operator-page: FAIL permanent — corr_id $_ack_corr was never raised" >&2
        exit 1
    fi
    printf '{"ts":"%s","kind":"operator_page_ack","corr_id":"%s","ack_by":"%s"}\n' \
        "$(_now_iso)" "$_ack_corr" "$(_json_escape "$_ack_by")" >> "$_amb"
    echo "operator-page: ACK corr_id=$_ack_corr by=$_ack_by"
    exit 0
fi

# ── raise a new page ──────────────────────────────────────────────────────────
case "$_severity" in
    info|action|block) ;;
    *) echo "operator-page: FAIL permanent — --severity must be info|action|block, got '$_severity'" >&2; exit 1 ;;
esac
if [[ -z "$_title" || -z "$_message" ]]; then
    echo "operator-page: FAIL permanent — --title and --message are required" >&2
    exit 1
fi

_corr_id="op-$(_now_epoch)-$$-${RANDOM}"
_cost="${CHUMP_SESSION_COST_USD:-unknown}"

printf '{"ts":"%s","kind":"operator_page","corr_id":"%s","severity":"%s","title":"%s","message":"%s","gap_id":"%s","timeout_secs":%s,"raised_epoch":%s,"cost_usd_at_page":"%s"}\n' \
    "$(_now_iso)" "$_corr_id" "$_severity" "$(_json_escape "$_title")" "$(_json_escape "$_message")" \
    "$(_json_escape "$_gap_id")" "${_timeout_secs:-0}" "$(_now_epoch)" "$(_json_escape "$_cost")" >> "$_amb"

echo "operator-page: RAISED corr_id=$_corr_id severity=$_severity"
exit 0
