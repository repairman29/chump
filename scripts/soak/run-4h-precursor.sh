#!/usr/bin/env bash
# run-4h-precursor.sh — 4-hour unattended precursor soak test (INFRA-008).
#
# Runs chump-orchestrator --watch --no-dry-run against a mixed infra+eval+docs
# backlog for up to 4 hours. A watchdog loop restarts the orchestrator on crash.
# On clean exit or walltime expiry, writes a summary to the run report.
#
# Usage:
#   scripts/soak/run-4h-precursor.sh                   # 4h soak
#   SOAK_WALLTIME_SEC=900 scripts/soak/run-4h-precursor.sh  # 15-min smoke test
#   nohup scripts/soak/run-4h-precursor.sh > logs/soak/current.log 2>&1 &
#
# Success criteria (INFRA-008):
#   (a) >=1 PR shipped
#   (b) zero unrecovered binary panics
#   (c) ambient.jsonl shows file_edit/commit/bash_call throughout
#   (d) cost under $5 (claude backend) or $1 (chump-local+Ollama)
#
# Env:
#   SOAK_WALLTIME_SEC        default 14400 (4h)
#   SOAK_MAX_PARALLEL        default 2 (passed to orchestrator)
#   SOAK_BACKEND             default "claude" (or "chump-local")
#   SOAK_REPORT_DIR          default docs/eval/
#   SOAK_LOG_DIR             default logs/soak/
#   SOAK_RESTART_DELAY_SEC   default 30 (wait before restarting crashed process)
#   SOAK_MAX_CRASHES         default 5 (give up after this many unrecovered crashes)
#   CHUMP_GAPS_FILTER        optional domain filter e.g. "infra,eval,docs"

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# ── Config ────────────────────────────────────────────────────────────────────
WALLTIME="${SOAK_WALLTIME_SEC:-14400}"
MAX_PARALLEL="${SOAK_MAX_PARALLEL:-2}"
BACKEND="${SOAK_BACKEND:-claude}"
REPORT_DIR="${SOAK_REPORT_DIR:-$REPO_ROOT/docs/eval}"
LOG_DIR="${SOAK_LOG_DIR:-$REPO_ROOT/logs/soak}"
RESTART_DELAY="${SOAK_RESTART_DELAY_SEC:-30}"
MAX_CRASHES="${SOAK_MAX_CRASHES:-5}"
RUN_DATE="$(date -u +%Y%m%d)"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"

REPORT_FILE="$REPORT_DIR/INFRA-008-soak-run-${RUN_DATE}.md"
LOG_FILE="$LOG_DIR/soak-${RUN_TS}.log"

mkdir -p "$LOG_DIR" "$REPORT_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
    local msg="[$(ts)] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

# ── Find orchestrator ─────────────────────────────────────────────────────────
find_orchestrator() {
    if [[ -x "$REPO_ROOT/target/release/chump-orchestrator" ]]; then
        echo "$REPO_ROOT/target/release/chump-orchestrator"
    elif command -v chump-orchestrator &>/dev/null; then
        command -v chump-orchestrator
    else
        echo ""
    fi
}

# ── Count PRs shipped since soak start ───────────────────────────────────────
count_prs_since() {
    local since_ts="$1"
    gh pr list --state merged --json mergedAt,number \
        --jq "[.[] | select(.mergedAt >= \"$since_ts\")] | length" 2>/dev/null || echo "0"
}

# ── Check for unrecovered panics in log ───────────────────────────────────────
count_panics() {
    grep -c "thread '.*' panicked\|SIGSEGV\|signal: 11\|fatal runtime error" \
        "$LOG_FILE" 2>/dev/null || echo "0"
}

# ── Check ambient stream activity ────────────────────────────────────────────
check_ambient_activity() {
    local since_minutes="${1:-60}"
    local cutoff
    cutoff="$(date -u -v-${since_minutes}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u --date="${since_minutes} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "")"
    if [[ -z "$cutoff" || ! -f "$REPO_ROOT/.chump-locks/ambient.jsonl" ]]; then
        echo "unknown"
        return
    fi
    local count
    count=$(awk -v cutoff="$cutoff" '
        /^{/ {
            if (match($0, /"ts":"([^"]+)"/, a)) {
                if (a[1] >= cutoff) active++
            }
        }
        END { print active+0 }
    ' "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || echo "0")
    echo "$count"
}

# ── Build orchestrator command ────────────────────────────────────────────────
build_cmd() {
    local orch="$1"
    local cmd=("$orch"
        --no-dry-run
        --watch
        --max-parallel "$MAX_PARALLEL"
        --backlog "$REPO_ROOT/docs/gaps.yaml"
        --repo-root "$REPO_ROOT"
    )
    echo "${cmd[@]}"
}

# ── Write report header ───────────────────────────────────────────────────────
write_report_header() {
    local orch_bin="$1"
    cat > "$REPORT_FILE" <<EOF
# INFRA-008 Precursor Soak Run — $RUN_DATE

**Status:** IN PROGRESS
**Start:** $RUN_TS
**Walltime cap:** ${WALLTIME}s ($(( WALLTIME / 3600 ))h)
**Backend:** $BACKEND
**Orchestrator:** $orch_bin
**Max parallel:** $MAX_PARALLEL
**Log:** $LOG_FILE

## Success Criteria

| Criterion | Required | Result |
|-----------|----------|--------|
| (a) PRs shipped | ≥1 | TBD |
| (b) Unrecovered panics | 0 | TBD |
| (c) Ambient activity throughout | yes | TBD |
| (d) Cost | <\$5 (claude) / <\$1 (local) | TBD |

## Timeline

| Time (UTC) | Event |
|------------|-------|
| $RUN_TS | Soak started |

## Checkpoints

EOF
}

# ── Append a checkpoint row to the report ────────────────────────────────────
append_checkpoint() {
    local label="$1"
    local prs="$2"
    local panics="$3"
    local ambient="$4"
    local note="${5:-}"
    cat >> "$REPORT_FILE" <<EOF
### $label — $(ts)

| Metric | Value |
|--------|-------|
| PRs shipped since start | $prs |
| Unrecovered panics | $panics |
| Ambient events (last 60m) | $ambient |
| Note | $note |

EOF
}

# ── Finalize report ───────────────────────────────────────────────────────────
write_report_footer() {
    local outcome="$1"
    local prs="$2"
    local panics="$3"
    local ambient_ok="$4"
    local end_ts
    end_ts="$(ts)"

    # Update status line
    if command -v gsed &>/dev/null; then
        gsed -i "s/\*\*Status:\*\* IN PROGRESS/**Status:** $outcome/" "$REPORT_FILE"
    else
        sed -i "s/\*\*Status:\*\* IN PROGRESS/**Status:** $outcome/" "$REPORT_FILE"
    fi

    local pass_a="FAIL"
    local pass_b="FAIL"
    local pass_c="FAIL"
    [[ "$prs" -ge 1 ]] && pass_a="PASS"
    [[ "$panics" -eq 0 ]] && pass_b="PASS"
    [[ "$ambient_ok" == "yes" ]] && pass_c="PASS"

    cat >> "$REPORT_FILE" <<EOF
## Final Result

**End:** $end_ts
**Outcome:** $outcome

| Criterion | Required | Result | Pass? |
|-----------|----------|--------|-------|
| (a) PRs shipped | ≥1 | $prs | $pass_a |
| (b) Unrecovered panics | 0 | $panics | $pass_b |
| (c) Ambient activity throughout | yes | see checkpoints | $pass_c |
| (d) Cost | <\$5 | see GitHub billing | manual |

EOF
}

# ── Main watchdog loop ────────────────────────────────────────────────────────
main() {
    local orch
    orch="$(find_orchestrator)"

    if [[ -z "$orch" ]]; then
        log "ERROR: chump-orchestrator not found in target/release/ or PATH"
        log "Falling back to scripts/dev/agent-loop.sh"
        orch="agent-loop.sh fallback"
    fi

    local deadline=$(( $(date +%s) + WALLTIME ))
    local crash_count=0
    local start_ts
    start_ts="$(ts)"
    local checkpoint_interval=3600  # hourly checkpoints
    local last_checkpoint
    last_checkpoint="$(date +%s)"

    log "=== INFRA-008 PRECURSOR SOAK STARTING ==="
    log "Walltime: ${WALLTIME}s, deadline: $(date -u -r $deadline +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u --date=@$deadline +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo $deadline)"
    log "Backend: $BACKEND"
    log "Report: $REPORT_FILE"

    write_report_header "${orch}"

    # Emit T0 to ambient stream
    if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" \
            kind=soak_start gap=INFRA-008 walltime=${WALLTIME}s 2>/dev/null || true
    fi

    while true; do
        local now
        now="$(date +%s)"

        # ── Walltime check ─────────────────────────────────────────────────
        if [[ "$now" -ge "$deadline" ]]; then
            log "Walltime ($WALLTIME s) reached — stopping orchestrator"
            break
        fi

        # ── Hourly checkpoint ──────────────────────────────────────────────
        if (( now - last_checkpoint >= checkpoint_interval )); then
            local prs panics ambient elapsed_h
            prs="$(count_prs_since "$start_ts")"
            panics="$(count_panics)"
            ambient="$(check_ambient_activity 60)"
            elapsed_h=$(( (now - (deadline - WALLTIME)) / 3600 ))
            log "Checkpoint T+${elapsed_h}h: prs=$prs panics=$panics ambient_events=${ambient}"
            append_checkpoint "T+${elapsed_h}h checkpoint" "$prs" "$panics" "$ambient"
            last_checkpoint="$now"
        fi

        # ── Launch orchestrator (or agent-loop fallback) ───────────────────
        log "Starting orchestrator run (crash_count=$crash_count)"
        local orch_bin
        orch_bin="$(find_orchestrator)"
        local run_exit=0

        if [[ -n "$orch_bin" ]]; then
            # Compute remaining seconds for this orchestrator invocation
            local remaining=$(( deadline - now ))
            # Run orchestrator with timeout; ignore non-zero exits from natural completion
            timeout "$remaining" \
                "$orch_bin" \
                --no-dry-run \
                --watch \
                --max-parallel "$MAX_PARALLEL" \
                --backlog "$REPO_ROOT/docs/gaps.yaml" \
                --repo-root "$REPO_ROOT" \
                2>&1 | tee -a "$LOG_FILE" || run_exit=$?
        else
            # Fallback: agent-loop.sh with a walltime cap via timeout
            local remaining=$(( deadline - now ))
            timeout "$remaining" \
                "$REPO_ROOT/scripts/dev/agent-loop.sh" \
                --max-gaps 999 \
                2>&1 | tee -a "$LOG_FILE" || run_exit=$?
        fi

        now="$(date +%s)"

        # ── Classify exit ─────────────────────────────────────────────────
        if [[ "$now" -ge "$deadline" ]]; then
            log "Orchestrator stopped at walltime limit (exit=$run_exit)"
            break
        fi

        if [[ "$run_exit" -eq 124 ]]; then
            # timeout sent SIGTERM — this is expected at walltime boundary
            log "Orchestrator timed out cleanly (SIGTERM)"
            break
        fi

        if [[ "$run_exit" -ne 0 ]]; then
            crash_count=$(( crash_count + 1 ))
            log "Orchestrator exited with code $run_exit (crash #$crash_count)"
            if [[ "$crash_count" -ge "$MAX_CRASHES" ]]; then
                log "ERROR: exceeded MAX_CRASHES ($MAX_CRASHES) — aborting soak"
                break
            fi
            log "Restarting in ${RESTART_DELAY}s..."
            sleep "$RESTART_DELAY"
        else
            log "Orchestrator finished all available gaps (exit=0). Waiting 60s for more..."
            sleep 60
        fi
    done

    # ── Finalize ──────────────────────────────────────────────────────────────
    local final_prs final_panics
    final_prs="$(count_prs_since "$start_ts")"
    final_panics="$(count_panics)"
    local ambient_ok="yes"
    [[ "$(check_ambient_activity 240)" -eq 0 ]] && ambient_ok="no"

    local outcome="COMPLETE"
    [[ "$crash_count" -ge "$MAX_CRASHES" ]] && outcome="ABORTED (too many crashes)"
    [[ "$final_panics" -gt 0 ]] && outcome="COMPLETE (with panics — see below)"

    log "=== SOAK COMPLETE: prs=$final_prs panics=$final_panics outcome=$outcome ==="
    write_report_footer "$outcome" "$final_prs" "$final_panics" "$ambient_ok"

    # Emit soak_end to ambient stream
    if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" \
            kind=soak_end gap=INFRA-008 prs=$final_prs panics=$final_panics outcome="$outcome" \
            2>/dev/null || true
    fi

    if [[ "$final_panics" -eq 0 && "$final_prs" -ge 1 ]]; then
        log "SUCCESS: all criteria met (a,b confirmed; c,d require manual check)"
        exit 0
    else
        log "PARTIAL: prs=$final_prs panics=$final_panics — check report for details"
        exit 1
    fi
}

main "$@"
