#!/usr/bin/env bash
# scripts/ops/organ-success-verifier.sh — RESILIENT-1108 (Outcome-Verification,
# umbrella RESILIENT-1103).
#
# WHY THIS EXISTS (the all-night CHDIR incident). Every ChumpOS organ .service
# unit was deployed with `WorkingDirectory=/home/ubuntu/Projects/chump` — a
# directory that did not exist on the node. systemd refuses to start a service
# whose WorkingDirectory is missing: it kills the process at the chdir(2) step
# BEFORE ExecStart ever runs, and records `Result=exit-code` with
# `ExecMainStatus=200` (systemd's EXIT_CHDIR — see systemd's exit-status.h,
# surfaced in `systemctl status` as `status=200/CHDIR`). Every organ was
# therefore dead on arrival, every timer fire a no-op.
#
# Yet `systemctl is-active <timer>` stayed GREEN the entire time: a .timer's
# ActiveState reflects "the timer is armed and scheduled", NOT "the payload
# .service it triggers actually ran and succeeded". scripts/ops/organ-reconcile
# .sh and scripts/ops/organ-watchdog.sh both key their health check on
# `is-active` (or on ActiveState=failed / never-firing timers), so a timer that
# is dutifully firing a service that dies at CHDIR every single time is
# INVISIBLE to both. Nothing in the whole OS watched per-organ RUN SUCCESS
# (the systemctl `Result` / `ExecMainStatus` pair), so the outage hid
# indefinitely — the "green dashboard, dead engine" shape.
#
# This organ closes that specific blind spot. Each cycle it reads, for every
# organ declared `enabled` in scripts/ops/organ-manifest.txt, the LAST-RUN
# Result + ExecMainStatus of the .service that actually does the work, classes
# a run as FAILED (200/CHDIR, or any non-zero exit / core-dump / signal /
# oom-kill / watchdog / timeout), and PAGES the duty officer via notify-operator
# on any FAILED organ — not just inactive ones. A CHDIR-dead fleet that used to
# hide all night is now a page within one cycle (default 10 min).
#
# WHY IT PAGES INSTEAD OF RESTART-LOOPING. organ-watchdog.sh §1 already does
# `reset-failed`+`restart` on failed .service units. For a transient crash that
# heals; for a CHDIR / config bug (missing WorkingDirectory, bad env, absent
# binary) a restart re-fails instantly and, after StartLimitBurst, the unit
# just sits `failed` again — the blind restart is precisely what could not fix
# tonight's outage. The correct action for a persistently-failing organ is to
# TELL A HUMAN, loudly, once. So this verifier's job is detection + escalation;
# it deliberately does NOT restart (that is watchdog's lane and would loop on a
# config fault). Pages are deduped per (unit, exit-status) within a window so a
# still-broken organ pages once per window, not every cycle.
#
# Algorithm, every cycle (oneshot, run via a timer):
#   1. Parse scripts/ops/organ-manifest.txt for every `enabled` organ unit
#      (inline, bash-3.2-safe — no `local -n` namerefs, so the CI test can run
#      the same code on a macOS bash 3.2 box; see the bash-portability trap in
#      AGENTS.md / auto-memory).
#   2. For each enabled unit, resolve the SERVICE that does the work:
#        chump-foo.timer  -> chump-foo.service   (the payload the timer fires)
#        chump-foo.service -> itself
#      (This timer->service basename mapping is the universal convention across
#      scripts/dispatch/chump-*.{service,timer}.)
#   3. `systemctl show <svc> -p Result -p ExecMainStatus -p ActiveState \
#         -p SubState -p LoadState` — ONE call per service.
#   4. Classify:
#        - not-loaded (LoadState=not-found / masked)  -> SKIP (this is the
#          "declared but never installed" merged-not-running class, which
#          organ-reconcile / the Roll-Call test own; counting it as a run
#          failure here would double-page. Reported in the summary as skipped.)
#        - Result=success                              -> OK
#        - ExecMainStatus a non-zero integer, OR Result in the failed set
#          (exit-code, core-dump, signal, watchdog, start-limit-hit, oom-kill,
#           timeout, resources, protocol)              -> FAILED
#          (ExecMainStatus=200 is additionally tagged failure_class=chdir — the
#           exact tonight signature.)
#        - anything else (e.g. Result= empty on a unit that has never run)
#          -> OK-by-default (never-run is not a failed run; reconcile ensures
#          it gets started).
#   5. Page per FAILED organ via notify_operator (kind=organ_run_failed, which
#      is registered `page` in operator-escalation-registry.txt), deduped per
#      (unit, ExecMainStatus) within CHUMP_ORGAN_SUCCESS_DEDUP_WINDOW_S.
#   6. Emit a per-cycle summary: kind=organ_success_verify_tick with
#      verified_ok / enabled_total / failed count and the list of failed unit
#      names — the "N verified-ok / M enabled, and who failed" receipt.
#
# Usage:
#   scripts/ops/organ-success-verifier.sh            # scan + page, real systemctl
#   scripts/ops/organ-success-verifier.sh --dry-run  # classify + summarize, no page
#
# Env / test hooks:
#   CHUMP_ORGAN_SUCCESS_SYSTEMCTL_BIN   path to a stubbed `systemctl` (tests)
#   CHUMP_ORGAN_SUCCESS_MANIFEST        override organ-manifest.txt path (tests)
#   CHUMP_ORGAN_SUCCESS_STATE_DIR       override dedup state dir
#   CHUMP_ORGAN_SUCCESS_DEDUP_WINDOW_S  default 3600 (1h) — one page per broken
#                                       organ per window
#   CHUMP_AMBIENT_LOG                   override ambient.jsonl path
#   REPO_ROOT / CHUMP_REPO_ROOT         repo checkout root
#
# Exit codes:
#   0  normal (whether or not any organ was found failed — a FAILED organ is a
#      PAGE, not a non-zero exit; the organ itself succeeded at its job)
#   1  systemctl unavailable (non-Linux dev box / not installed) — quiet no-op,
#      expected on a macOS operator laptop
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
MANIFEST="${CHUMP_ORGAN_SUCCESS_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"
STATE_DIR="${CHUMP_ORGAN_SUCCESS_STATE_DIR:-$REPO_ROOT/.chump-locks/organ-success-verifier}"
DEDUP_WINDOW_S="${CHUMP_ORGAN_SUCCESS_DEDUP_WINDOW_S:-3600}"
SYSTEMCTL_BIN="${CHUMP_ORGAN_SUCCESS_SYSTEMCTL_BIN:-systemctl}"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# systemctl gate — on a macOS dev box / laptop there is no systemd. Quiet no-op
# so the CI test on a Mac runner and the operator laptop never see noise; the
# real Linux node has systemctl and does the work. Tests inject a stub via
# CHUMP_ORGAN_SUCCESS_SYSTEMCTL_BIN, which is always "present".
if ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
    echo "[organ-success-verifier] systemctl unavailable ($SYSTEMCTL_BIN) — no-op (expected off-Linux)" >&2
    exit 1
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$AMB")" 2>/dev/null || true
touch "$AMB" 2>/dev/null || true

# notify-operator.sh's own _notify_emit reads CHUMP_AMBIENT_LOG — export it so
# the operator_paged / suppressed trail lands in the SAME log the test asserts
# on (load-bearing for --ambient-log-style tests and for any consumer of the
# standard ambient path).
export CHUMP_AMBIENT_LOG="$AMB"

# shellcheck source=../coord/lib/notify-operator.sh
if [[ -f "$SCRIPT_DIR/../coord/lib/notify-operator.sh" ]]; then
    source "$SCRIPT_DIR/../coord/lib/notify-operator.sh"
else
    notify_operator() { echo "[organ-success-verifier] notify-operator.sh MISSING" >&2; return 1; }
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date -u +%s; }

_emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMB" 2>/dev/null || true
}

# Parse `enabled` unit names out of the manifest, inline + bash-3.2-safe.
# Format per manifest header: "<state>  <unit>  [role=..] [requires=..]".
_enabled_units() {
    [[ -f "$MANIFEST" ]] || return 0
    local state unit _rest
    while read -r state unit _rest; do
        [[ -z "${state:-}" ]] && continue
        case "$state" in
            \#*) continue ;;
            enabled) [[ -n "${unit:-}" ]] && printf '%s\n' "$unit" ;;
        esac
    done < "$MANIFEST"
}

# Map an enabled unit to the SERVICE that actually runs the work.
_payload_service() {
    local unit="$1"
    case "$unit" in
        *.timer)   printf '%s\n' "${unit%.timer}.service" ;;
        *.service) printf '%s\n' "$unit" ;;
        *)         printf '%s\n' "${unit}.service" ;;  # bare name -> .service
    esac
}

# The systemd Result values that mean "the last run did not succeed". `success`
# is the only OK value; an empty Result means the unit has never run (not a
# failed run). start-limit-hit is included because a oneshot that CHDIR-fails a
# few times trips it and then sits latched — still a real, human-visible failure.
_is_failed_result() {
    case "$1" in
        exit-code|core-dump|signal|watchdog|start-limit-hit|oom-kill|timeout|resources|protocol)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Pull a `Key=Value` property out of one `systemctl show` block on stdin.
_show_prop() {  # key, block-text
    printf '%s\n' "$2" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'
}

enabled_total=0
verified_ok=0
failed_total=0
skipped_total=0
paged=0
dedup_skipped=0
failed_names=""

while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    enabled_total=$((enabled_total + 1))
    svc="$(_payload_service "$unit")"

    block="$("$SYSTEMCTL_BIN" show "$svc" \
        -p Result -p ExecMainStatus -p ActiveState -p SubState -p LoadState 2>/dev/null || true)"

    load_state="$(_show_prop LoadState "$block")"
    result="$(_show_prop Result "$block")"
    exec_status="$(_show_prop ExecMainStatus "$block")"
    active_state="$(_show_prop ActiveState "$block")"

    # not-loaded = declared-but-not-installed. Not this organ's lane (reconcile
    # + Roll-Call own it); count as skipped so we never double-page.
    if [[ "$load_state" == "not-found" || "$load_state" == "masked" || "$load_state" == "error" ]]; then
        skipped_total=$((skipped_total + 1))
        continue
    fi

    # Classify the last run.
    is_failed=0
    failure_class=""
    if [[ "$exec_status" =~ ^[0-9]+$ ]] && [[ "$exec_status" != "0" ]]; then
        is_failed=1
        [[ "$exec_status" == "200" ]] && failure_class="chdir"
    elif _is_failed_result "$result"; then
        is_failed=1
    fi

    if [[ "$is_failed" != "1" ]]; then
        verified_ok=$((verified_ok + 1))
        continue
    fi

    # ---- FAILED organ ----
    failed_total=$((failed_total + 1))
    [[ -z "$failure_class" ]] && failure_class="exit"
    failed_names="${failed_names:+$failed_names,}${unit}(${exec_status:-?}/${result:-?})"

    if [[ "$DRY_RUN" == "1" ]]; then
        # scanner-anchor: "kind":"organ_run_failed"
        _emit "organ_run_failed" \
            "\"unit\":\"$unit\",\"service\":\"$svc\",\"exec_status\":\"${exec_status:-}\",\"result\":\"${result:-}\",\"active_state\":\"${active_state:-}\",\"failure_class\":\"$failure_class\",\"dry_run\":true"
        continue
    fi

    # Dedup per (unit, exec_status) so a still-broken organ pages once per
    # window, not every 10-minute cycle.
    dedup_key="$(printf '%s__%s' "$unit" "${exec_status:-x}" | tr '/ .@' '____')"
    dedup_file="$STATE_DIR/${dedup_key}.json"
    skip=0
    if [[ -f "$dedup_file" ]]; then
        last_ts="$(python3 -c "import json;print(json.load(open('$dedup_file')).get('last_epoch',0))" 2>/dev/null || echo 0)"
        [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
        if (( $(_now_epoch) - last_ts < DEDUP_WINDOW_S )); then
            skip=1
        fi
    fi

    if [[ "$skip" == "1" ]]; then
        dedup_skipped=$((dedup_skipped + 1))
        # scanner-anchor: "kind":"organ_run_verify_dedup_skip"
        _emit "organ_run_verify_dedup_skip" \
            "\"unit\":\"$unit\",\"exec_status\":\"${exec_status:-}\",\"failure_class\":\"$failure_class\""
        continue
    fi

    # scanner-anchor: "kind":"organ_run_failed"
    _emit "organ_run_failed" \
        "\"unit\":\"$unit\",\"service\":\"$svc\",\"exec_status\":\"${exec_status:-}\",\"result\":\"${result:-}\",\"active_state\":\"${active_state:-}\",\"failure_class\":\"$failure_class\""

    # Page the duty officer. organ_run_failed is registered `page` in
    # operator-escalation-registry.txt — a persistently-failing organ that
    # restart-looping cannot fix has no auto-heal, so the operator must see it.
    chdir_hint=""
    [[ "$failure_class" == "chdir" ]] && chdir_hint="
status=200/CHDIR means systemd killed it at chdir(2) BEFORE ExecStart ran —
almost always a WorkingDirectory (or missing checkout) that does not exist on
this node. A restart will NOT fix this; the unit's directory/config must be."
    CHUMP_NOTIFY_KIND="organ_run_failed" \
    notify_operator "🛑 **Organ ${unit} last run FAILED.**

service=${svc}
Result=${result:-?}  ExecMainStatus=${exec_status:-?}  ActiveState=${active_state:-?}
failure_class=${failure_class}${chdir_hint}

The timer may still read is-active=active — this is the green-timer/dead-service
blind spot organ-success-verifier.sh (RESILIENT-1108) exists to catch. Pages
once per organ per $((DEDUP_WINDOW_S / 60))m (dedup window)." \
        >/dev/null 2>&1
    page_rc=$?

    python3 -c "
import json
json.dump({'unit':'$unit','exec_status':'${exec_status:-}','last_epoch':$(_now_epoch)}, open('$dedup_file','w'))
" 2>/dev/null || true

    paged=$((paged + 1))
    [[ "$page_rc" -ne 0 ]] && echo "[organ-success-verifier] notify_operator rc=$page_rc for $unit" >&2
done < <(_enabled_units)

# Per-cycle summary receipt (Receipt Law): N verified-ok / M enabled + who failed.
# scanner-anchor: "kind":"organ_success_verify_tick"
_emit "organ_success_verify_tick" \
    "\"enabled_total\":$enabled_total,\"verified_ok\":$verified_ok,\"failed\":$failed_total,\"skipped_not_loaded\":$skipped_total,\"paged\":$paged,\"dedup_skipped\":$dedup_skipped,\"failed_units\":\"${failed_names}\""

echo "[organ-success-verifier] cycle complete: verified_ok=$verified_ok/$enabled_total failed=$failed_total (${failed_names:-none}) skipped_not_loaded=$skipped_total paged=$paged dedup_skipped=$dedup_skipped"

# Self-registration: standard reaper heartbeat, mirrors outcome-verify-heal-
# consumer.sh / process-organ-heal.sh so a dead verifier is itself caught by
# reaper-heartbeat-watchdog.sh's cadence grading — the verifier is not exempt
# from being verified.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$SCRIPT_DIR/../lib/reaper-instrumentation.sh" 2>/dev/null && {
    reaper_setup organ-success-verifier
    reaper_emit_run organ-success-verifier ok "{\"verified_ok\":$verified_ok,\"failed\":$failed_total}"
}

exit 0
