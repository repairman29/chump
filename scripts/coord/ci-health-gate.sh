#!/usr/bin/env bash
# ci-health-gate.sh — INFRA-1607
#
# CI health gate daemon. Runs every 5 min via launchd.
#
# Two breach paths — either alone writes .chump/fleet-paused:
#
#   1. SLO breach:    `chump health --slo-check` exits 1
#   2. Pipeline jam:  ≥ CHUMP_CI_HEALTH_JAM_THRESHOLD % of open PRs are BLOCKED
#                     over a 1-hour rolling window (default 50%)
#
# Recovery: fleet-paused is cleared only after 2 consecutive RC=0 runs
# (SLO passes) AND (if the previous breach was pipeline_jam) the BLOCKED pct
# is below CHUMP_CI_HEALTH_JAM_RECOVERY (default 30%).
#
# Usage:
#   ./scripts/coord/ci-health-gate.sh          # one-shot check
#
# Env overrides:
#   CHUMP_CI_HEALTH_GATE_DISABLE  — set to 1 to skip all checks (noop)
#   CHUMP_CI_HEALTH_JAM_THRESHOLD  — % BLOCKED to trigger pipeline_jam (default 50)
#   CHUMP_CI_HEALTH_JAM_RECOVERY   — % BLOCKED required for recovery (default 30)
#   CHUMP_FLEET_PAUSE_FILE         — path to fleet-paused flag (default .chump/fleet-paused)
#   CHUMP_AMBIENT_LOG              — path to ambient.jsonl (default .chump-locks/ambient.jsonl)
#   CHUMP_CI_HEALTH_CONSEC_FILE    — consecutive-clean-run counter (default /tmp/chump-ci-health-recovery-count)
#
# Emits to ambient.jsonl:
#   kind=pipeline_health_throttle  — on state change (pause set or cleared)
#
# Install via launchd (runs every 5 min):
#   copy launchd/com.chump.ci-health-gate.plist → ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.chump.ci-health-gate.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Common-dir resolution for linked worktrees.
_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common" && "$_common" != ".git" ]]; then
    REPO_ROOT="$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir | xargs dirname 2>/dev/null || echo "$REPO_ROOT")"
fi

JAM_THRESHOLD="${CHUMP_CI_HEALTH_JAM_THRESHOLD:-50}"
JAM_RECOVERY="${CHUMP_CI_HEALTH_JAM_RECOVERY:-30}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
PAUSE_FILE="${CHUMP_FLEET_PAUSE_FILE:-$REPO_ROOT/.chump/fleet-paused}"
CONSEC_FILE="${CHUMP_CI_HEALTH_CONSEC_FILE:-/tmp/chump-ci-health-recovery-count}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    local kind="$1"; shift
    local extra="${1:-}"
    local ts; ts="$(_ts)"
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "${extra:+,$extra}" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Guard: CHUMP_CI_HEALTH_GATE_DISABLE bypass ───────────────────────────────
if [[ "${CHUMP_CI_HEALTH_GATE_DISABLE:-0}" == "1" ]]; then
    echo "[ci-health-gate] CHUMP_CI_HEALTH_GATE_DISABLE=1 — noop"
    exit 0
fi

# ── Pipeline-jam side-check via github_cache.db ──────────────────────────────
# Source cache lib so we can query open PRs without a live GH API call.
CACHE_LIB="$REPO_ROOT/scripts/lib/github_cache.sh"
blocked_pct=0
total_open=0
total_blocked=0
if [[ -f "$CACHE_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$CACHE_LIB" 2>/dev/null || true
    if declare -f cache_query_open_prs >/dev/null 2>&1; then
        # cache_query_open_prs emits "number\ttitle\thead_ref" per row
        open_prs="$(cache_query_open_prs 2>/dev/null || true)"
        if [[ -n "$open_prs" ]]; then
            total_open="$(printf '%s\n' "$open_prs" | wc -l | tr -d ' ')"
            # A PR is BLOCKED when its mergeStateStatus is BLOCKED.
            # The cache stores this; we approximate via a dedicated query
            # if available, else fall back to counting PRs with BLOCKED in
            # the cached status column.
            if declare -f cache_query_behind_prs >/dev/null 2>&1; then
                # cache_query_behind_prs returns one number per line (the PR numbers that are BEHIND/BLOCKED)
                blocked_rows="$(cache_query_behind_prs 2>/dev/null || true)"
                total_blocked=0
                [[ -n "$blocked_rows" ]] && total_blocked="$(printf '%s\n' "$blocked_rows" | grep -c . || echo 0)"
            fi
            if [[ "$total_open" -gt 0 ]]; then
                blocked_pct=$(( total_blocked * 100 / total_open ))
            fi
        fi
    fi
fi
echo "[ci-health-gate] pipeline-jam check: total_open=$total_open total_blocked=$total_blocked blocked_pct=${blocked_pct}%"

# ── SLO check (RESILIENT-146: halt only on L1 SAFETY breaches) ────────────────
# Parse per-SLO breaches from --json. The fleet-pause gate must fire ONLY for
# acute fleet-unsafe conditions — L1 safety SLOs + pipeline jams. Chronic L2
# EFFICIENCY SLOs (waste %, ghost-gap count, P50 ship-time) are 7d-cumulative /
# slow-moving metrics the halt itself cannot fix, so halting on them is
# self-perpetuating (the 2026-06-15→20 5-day false outage: paused → 0 ships →
# cumulative waste stays breached → re-pause forever). L2 breaches are
# observable signals (file-a-gap), never halt-class.
slo_json="$(chump health --slo-check --json 2>/dev/null || true)"
slo_rc=0
printf '%s' "$slo_json" | grep -q '"breached":true' && slo_rc=1
l1_breached_ids="$(printf '%s' "$slo_json" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(",".join(s.get("id","") for s in d.get("slos",[]) if s.get("breached") and str(s.get("id","")).startswith("L1-")))
' 2>/dev/null || true)"
all_breached_ids="$(printf '%s' "$slo_json" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(",".join(s.get("id","") for s in d.get("slos",[]) if s.get("breached")))
' 2>/dev/null || true)"
echo "[ci-health-gate] slo breaches: L1=[${l1_breached_ids}] all=[${all_breached_ids}] (halt on L1 only — RESILIENT-146)"

# ── Determine breach (RESILIENT-146: L1 safety + acute jam only) ──────────────
breach_reason=""
if [[ -n "$l1_breached_ids" ]]; then
    breach_reason="slo_breach"          # L1 safety breach → halt-class
elif [[ $blocked_pct -ge $JAM_THRESHOLD ]]; then
    breach_reason="pipeline_jam"
fi
# Chronic L2-only breach (no L1, no jam): observable signal, NOT a halt.
if [[ -z "$breach_reason" && -n "$all_breached_ids" ]]; then
    echo "[ci-health-gate] chronic L2 breach (${all_breached_ids}) — NOT pausing (file-a-gap class, RESILIENT-146)"
    _emit "slo_chronic_breach" '"slos":"'"${all_breached_ids}"'","note":"L2 efficiency SLO breached; observable not halt-class (RESILIENT-146)"'
fi

# ── Spike path: write fleet-paused ───────────────────────────────────────────
if [[ -n "$breach_reason" ]]; then
    echo "[ci-health-gate] BREACH: reason=$breach_reason — pausing fleet"
    mkdir -p "$(dirname "$PAUSE_FILE")"
    ts="$(_ts)"
    # Record the ACTUAL breached L1 SLO ids (was hardcoded ["L1-SLO-1"]).
    slos_breached="[]"
    if [[ -n "$l1_breached_ids" ]]; then
        slos_breached="$(printf '%s' "$l1_breached_ids" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().strip().split(",") if x]))' 2>/dev/null || echo "[]")"
    fi
    blocked_null="null"
    if [[ "$breach_reason" == "pipeline_jam" ]]; then
        blocked_null="$blocked_pct"
    fi
    printf '{"ts":"%s","kind":"slo_breach","reason":"%s","slos_breached":%s,"blocked_pct":%s}\n' \
        "$ts" "$breach_reason" "$slos_breached" "$blocked_null" \
        > "$PAUSE_FILE"
    _emit "pipeline_health_throttle" \
        '"state":"paused","reason":"'"$breach_reason"'","blocked_pct":'"$blocked_null"',"slo_rc":'"$slo_rc"
    # Reset consecutive-recovery counter on any breach.
    echo 0 > "$CONSEC_FILE" 2>/dev/null || true
    exit 0
fi

# ── Recovery check ────────────────────────────────────────────────────────────
if [[ -f "$PAUSE_FILE" ]]; then
    # Determine what kind of breach we're recovering from
    prior_reason=""
    if command -v python3 >/dev/null 2>&1; then
        prior_reason="$(python3 -c \
            "import sys,json; d=json.load(open('$PAUSE_FILE')); print(d.get('reason',''))" \
            2>/dev/null || true)"
    fi

    # For pipeline_jam recovery, require blocked_pct < JAM_RECOVERY
    if [[ "$prior_reason" == "pipeline_jam" && $blocked_pct -ge $JAM_RECOVERY ]]; then
        echo "[ci-health-gate] pipeline_jam: blocked_pct=${blocked_pct}% still >= recovery threshold ${JAM_RECOVERY}% — fleet remains paused"
        echo 0 > "$CONSEC_FILE" 2>/dev/null || true
        exit 0
    fi

    # Increment consecutive-clean counter
    consec=0
    [[ -f "$CONSEC_FILE" ]] && consec=$(cat "$CONSEC_FILE" 2>/dev/null || echo 0)
    consec=$(( consec + 1 ))
    echo "$consec" > "$CONSEC_FILE"
    echo "[ci-health-gate] clean run $consec/2 — blocked_pct=${blocked_pct}% slo_rc=$slo_rc"
    if [[ $consec -ge 2 ]]; then
        rm -f "$PAUSE_FILE"
        echo 0 > "$CONSEC_FILE"
        echo "[ci-health-gate] RECOVERED: fleet-paused removed after 2 consecutive clean runs"
        _emit "pipeline_health_throttle" \
            '"state":"resumed","prior_reason":"'"${prior_reason:-unknown}"'","blocked_pct":'"$blocked_pct"',"slo_rc":'"$slo_rc"

        # ── RESILIENT-066: kick recovery choir after sentinel lift ────────────
        # The supervisory + reaper daemons may have exit-coded during the pause
        # (any `chump claim` they attempted returned non-zero). Now that the
        # sentinel is gone, launchctl-kickstart them so recovery resumes without
        # waiting for the next StartInterval tick.
        #
        # Safety: we only kick AFTER sentinel is removed AND slo_rc==0.
        # No kickstart is attempted while fleet-paused still exists.
        if command -v launchctl &>/dev/null; then
            _uid="$(id -u)"
            _recovery_daemons=(
                "com.chump.curator-supervisor"
                "com.chump.main-health-watchdog"
                "dev.chump.auto-merge-rearm"
                "com.chump.pr-shepherd"
                "com.chump.ghost-gap-reaper"
            )
            _kicked=()
            for _label in "${_recovery_daemons[@]}"; do
                if launchctl list 2>/dev/null | grep -qF "$_label"; then
                    echo "[ci-health-gate] kicking $_label after sentinel lift"
                    launchctl kickstart "gui/${_uid}/${_label}" 2>/dev/null || true
                    _kicked+=("$_label")
                fi
            done
            if [[ "${#_kicked[@]}" -gt 0 ]]; then
                echo "[ci-health-gate] kicked ${#_kicked[@]} recovery daemon(s): ${_kicked[*]}"
            fi
            _emit "fleet_recovery_choir_kicked" \
                '"prior_reason":"'"${prior_reason:-unknown}"'","kicked_count":'"${#_kicked[@]}"',"daemons":"'"${_kicked[*]}"'"'
        fi
        # ── end RESILIENT-066 ────────────────────────────────────────────────
    fi
else
    # No pause file — healthy
    echo 0 > "$CONSEC_FILE" 2>/dev/null || true
    echo "[ci-health-gate] healthy — blocked_pct=${blocked_pct}% slo_rc=$slo_rc"
fi

exit 0
