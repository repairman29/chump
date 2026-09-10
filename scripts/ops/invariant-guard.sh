#!/usr/bin/env bash
# scripts/ops/invariant-guard.sh — RESILIENT-1104 (core) / RESILIENT-1105
#
# THE RATCHET GUARD-ORGAN. "Solved stays solved."
#
# WHY THIS EXISTS. The fleet re-solves the same failures for thousands of PRs
# because fixes decay: a metric floor is hit once, celebrated, and then quietly
# regresses because nobody is continuously watching THAT specific number. The
# anti-Memento cure is enforcement + self-watching: turn every earned invariant
# into a guard-rail that pages on regression. fleet-doctor-strict.sh already does
# this for 7+ hardcoded health checks; this organ generalizes it into a UNIFORM,
# DATA-DRIVEN registry (scripts/ops/invariant-registry.txt) so a new floor is one
# row, not a new function — and it runs on a timer so the watching never stops.
#
# WHAT IT DOES each cycle:
#   1. Read every row of the invariant registry: {id, check, comparator,
#      threshold, owner, severity}.
#   2. Run each row's `check` (a probe printing the MEASURED VALUE, or "NA" to
#      skip), compare value <comparator> threshold, and classify ok|violation|skip.
#   3. Emit a per-invariant ambient READING every cycle (kind=invariant_reading)
#      — the durable gauge, healthy or not.
#   4. On a violation: emit kind=invariant_violation AND, for severity=page,
#      route it through the existing operator escalation path
#      (scripts/coord/lib/notify-operator.sh, kind=invariant_violation → PAGE in
#      the escalation registry) so it is an INCIDENT, not unclassified noise.
#   5. Emit a heartbeat (kind=invariant_guard_tick) so the guard is itself
#      watchable (a dead ratchet stops ticking).
#   6. Exit non-zero iff any PAGE-severity invariant is violated — so this organ
#      doubles as a strict CI/pre-ship gate, exactly like fleet-doctor-strict.
#
# MINE-BEFORE-BUILD. This reuses, not reinvents: the metric source
# (scripts/dispatch/autonomous-ship-rate.sh, CREDIBLE-047) via the ship-rate
# probe; the escalation discipline + page path (notify-operator.sh, RESILIENT-274
# / RESILIENT-1052); the ambient-emit + scanner-anchor idiom; and fleet-doctor's
# register/exit-non-zero contract (fleet-doctor folds this registry in via
# check_invariant_registry).
#
# MODES / FLAGS:
#   (default)      run once: read registry, evaluate, emit readings, page, exit.
#   --json         also print a machine snapshot (one JSON object) to stdout.
#   --dry-run      evaluate + emit readings, but NEVER page (still exits non-zero
#                  on a page-severity violation, so a gate can use it read-only).
#   --loop [--cadence-min N]  run forever, one pass every N min (default 15).
#   -h|--help      this header.
#
# ENV:
#   CHUMP_INVARIANT_REGISTRY   registry path (default scripts/ops/invariant-registry.txt)
#   CHUMP_AMBIENT_LOG          ambient jsonl (default <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_INVARIANT_PAGE_SINK  TEST/audit hook: also append page payloads here (TSV)
#   CHUMP_INVARIANT_CADENCE_MIN  cadence for --loop (default 15)
#   CHUMP_INVARIANT_GUARD       set 0 to no-op exit 0 (scripted raw-signal contexts)
#
# Portable: POSIX-ish bash, no associative arrays, no mapfile — runs on the
# board (bash 3.2) and the Oracle nodes (bash 5.1). Fail-soft: a broken probe or
# notifier never aborts the pass.
set -uo pipefail

if [[ "${CHUMP_INVARIANT_GUARD:-1}" == "0" ]]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# worktree-safe: resolve back to the main checkout so .chump-locks + .env are found.
_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common" && "$_common" != ".git" ]]; then
    [[ "$_common" != /* ]] && _common="$REPO_ROOT/$_common"
    REPO_ROOT="$(cd "$(dirname "$_common")" && pwd)"
fi

REGISTRY="${CHUMP_INVARIANT_REGISTRY:-$REPO_ROOT/scripts/ops/invariant-registry.txt}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
NOTIFIER="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
NODE_ID="$(hostname 2>/dev/null || echo unknown)"
CADENCE_MIN="${CHUMP_INVARIANT_CADENCE_MIN:-15}"

JSON=0
DRY=0
LOOP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)        JSON=1 ;;
        --dry-run)     DRY=1 ;;
        --loop)        LOOP=1 ;;
        --cadence-min) CADENCE_MIN="$2"; shift ;;
        -h|--help)     sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[invariant-guard] unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

ts_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()    { echo "[invariant-guard] $*" >&2; }

# ── ambient emit (fail-soft) ─────────────────────────────────────────────────
# Kinds are written via printf %s (dynamic), so the event-registry coverage
# scanner cannot see the literals at the call. These anchors carry the literal
# "kind":"X" strings it greps for, so emitted-set == registered-set
# (docs/observability/EVENT_REGISTRY.yaml).
# scanner-anchor: "kind":"invariant_reading"
# scanner-anchor: "kind":"invariant_violation"
# scanner-anchor: "kind":"invariant_guard_tick"
emit() {
    # emit <kind> [k=v ...]
    local kind="$1"; shift || true
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    local extra="" kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
        extra="$extra,\"$k\":\"$v\""
    done
    printf '{"ts":"%s","kind":"%s","node":"%s","emitter":"invariant-guard"%s}\n' \
        "$(ts_iso)" "$kind" "$NODE_ID" "$extra" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── page the operator (never JUST ambient) ───────────────────────────────────
# Mirrors fleet-health-sentinel.sh's page(): always emit a halt-class ambient
# violation, log a PAGE line, drop to the test sink if configured, then route
# through notify-operator (kind=invariant_violation → PAGE per the escalation
# registry). notify_operator no-ops silently when unconfigured, so the ambient
# event + sink are the durable receipts on a credential-less node. --dry-run and
# severity=warn suppress the DM (handled by the caller).
page() {
    local id="$1" msg="$2"
    log "PAGE (invariant_violation): $msg"
    if [[ -n "${CHUMP_INVARIANT_PAGE_SINK:-}" ]]; then
        printf '%s\tPAGE\tinvariant_violation\t%s\t%s\t%s\n' \
            "$(ts_iso)" "$NODE_ID" "$id" "$msg" >> "$CHUMP_INVARIANT_PAGE_SINK" 2>/dev/null || true
    fi
    if [[ "$DRY" -eq 1 ]]; then
        log "DRY-RUN: would page but did not"
        return 0
    fi
    if [[ -f "$NOTIFIER" ]]; then
        # Fail-soft: a broken notifier must never break the guard.
        ( CHUMP_NOTIFY_KIND="invariant_violation" CHUMP_NOTIFY_SEVERITY=halt \
          bash -c 'source "$1"; notify_operator "$2"' _ "$NOTIFIER" \
          "[ratchet/$NODE_ID] invariant '$id' violated — $msg" ) >/dev/null 2>&1 || true
    fi
}

# ── float compare: is "value <comparator> threshold" TRUE? ───────────────────
# Returns 0 (true = invariant OK) / 1 (false = violation). Uses awk for a
# portable float compare (no bc dependency).
compare_ok() {
    local value="$1" cmp="$2" threshold="$3"
    awk -v v="$value" -v t="$threshold" -v c="$cmp" 'BEGIN{
        if (c=="ge") ok=(v>=t);
        else if (c=="gt") ok=(v>t);
        else if (c=="le") ok=(v<=t);
        else if (c=="lt") ok=(v<t);
        else ok=0;                 # unknown comparator → treat as violation (fail loud)
        exit ok?0:1
    }'
}

is_number() { awk -v x="$1" 'BEGIN{ if (x+0==x && x!="") exit 0; else exit 1 }'; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# ── one evaluation pass ──────────────────────────────────────────────────────
N_TOTAL=0; N_OK=0; N_SKIP=0; N_WARN_VIOL=0; N_PAGE_VIOL=0
SNAP_ROWS=""   # JSON fragments for --json snapshot

run_pass() {
    N_TOTAL=0; N_OK=0; N_SKIP=0; N_WARN_VIOL=0; N_PAGE_VIOL=0; SNAP_ROWS=""
    if [[ ! -f "$REGISTRY" ]]; then
        log "registry not found: $REGISTRY"
        return 0
    fi

    local raw id check cmp threshold owner severity
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        # strip comments / blanks
        case "$(trim "$raw")" in ''|\#*) continue ;; esac

        # split on '|' into six fields
        IFS='|' read -r id check cmp threshold owner severity <<EOF
$raw
EOF
        id="$(trim "$id")"; check="$(trim "$check")"; cmp="$(trim "$cmp")"
        threshold="$(trim "$threshold")"; owner="$(trim "$owner")"; severity="$(trim "$severity")"
        [[ -z "$id" || -z "$check" ]] && continue
        [[ -z "$severity" ]] && severity="page"
        N_TOTAL=$((N_TOTAL+1))

        # resolve check path relative to repo root when it names a script
        local check_cmd="$check"
        case "$check" in
            scripts/*) check_cmd="$REPO_ROOT/$check" ;;
        esac

        # run the probe (fail-soft) → measured value or NA
        local value=""
        if [[ -f "$check_cmd" ]]; then
            value="$(bash "$check_cmd" 2>/dev/null | head -1 || true)"
        else
            value="$(eval "$check_cmd" 2>/dev/null | head -1 || true)"
        fi
        value="$(trim "${value:-}")"

        local status detail
        if [[ -z "$value" || "$value" == "NA" || "$value" == "na" ]]; then
            status="skip"
            detail="probe returned NA (not measurable this cycle)"
            N_SKIP=$((N_SKIP+1))
        elif ! is_number "$value"; then
            # a non-numeric, non-NA value is a broken probe → skip, never page.
            status="skip"
            detail="probe returned non-numeric '$value' — treating as NA"
            N_SKIP=$((N_SKIP+1))
        elif compare_ok "$value" "$cmp" "$threshold"; then
            status="ok"
            detail="$value $cmp $threshold"
            N_OK=$((N_OK+1))
        else
            status="violation"
            detail="measured $value, floor requires value $cmp $threshold (owner=$owner)"
            if [[ "$severity" == "page" ]]; then
                N_PAGE_VIOL=$((N_PAGE_VIOL+1))
            else
                N_WARN_VIOL=$((N_WARN_VIOL+1))
            fi
        fi

        # per-invariant ambient reading — EVERY cycle, healthy or not.
        emit "invariant_reading" id="$id" value="${value:-NA}" comparator="$cmp" \
            threshold="$threshold" owner="$owner" severity="$severity" status="$status"

        # violation handling
        if [[ "$status" == "violation" ]]; then
            emit "invariant_violation" id="$id" value="$value" comparator="$cmp" \
                threshold="$threshold" owner="$owner" severity="$severity" msg="$detail"
            if [[ "$severity" == "page" ]]; then
                page "$id" "$detail"
            else
                log "WARN violation (no page, severity=warn): $id — $detail"
            fi
        fi

        # snapshot fragment
        local frag
        frag="$(python3 -c '
import json,sys
print(json.dumps({
  "id": sys.argv[1], "status": sys.argv[2], "value": sys.argv[3],
  "comparator": sys.argv[4], "threshold": sys.argv[5],
  "owner": sys.argv[6], "severity": sys.argv[7], "detail": sys.argv[8],
}))' "$id" "$status" "${value:-NA}" "$cmp" "$threshold" "$owner" "$severity" "$detail" 2>/dev/null \
            || printf '{"id":"%s","status":"%s"}' "$id" "$status")"
        if [[ -z "$SNAP_ROWS" ]]; then SNAP_ROWS="$frag"; else SNAP_ROWS="$SNAP_ROWS,$frag"; fi

        [[ "$status" == "violation" ]] && log "VIOLATION [$severity]: $id — $detail" \
            || log "$status: $id — $detail"
    done < "$REGISTRY"

    # heartbeat — the guard is itself watchable (a dead ratchet stops ticking).
    emit "invariant_guard_tick" total="$N_TOTAL" ok="$N_OK" skip="$N_SKIP" \
        warn_violations="$N_WARN_VIOL" page_violations="$N_PAGE_VIOL" dry_run="$DRY"

    if [[ "$JSON" -eq 1 ]]; then
        printf '{"node":"%s","ts":"%s","total":%d,"ok":%d,"skip":%d,"warn_violations":%d,"page_violations":%d,"invariants":[%s]}\n' \
            "$NODE_ID" "$(ts_iso)" "$N_TOTAL" "$N_OK" "$N_SKIP" "$N_WARN_VIOL" "$N_PAGE_VIOL" "$SNAP_ROWS"
    else
        log "pass: total=$N_TOTAL ok=$N_OK skip=$N_SKIP warn_violations=$N_WARN_VIOL page_violations=$N_PAGE_VIOL"
    fi
}

if [[ "$LOOP" -eq 1 ]]; then
    log "loop mode: cadence=${CADENCE_MIN}m"
    while true; do
        run_pass || true
        sleep $(( CADENCE_MIN * 60 ))
    done
else
    run_pass
    # Exit non-zero iff a PAGE-severity invariant is violated — the strict-gate
    # contract (mirrors fleet-doctor-strict.sh). warn violations never fail.
    [[ "$N_PAGE_VIOL" -eq 0 ]]
fi
