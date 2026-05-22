#!/usr/bin/env bash
# scripts/content-bots/orchestrate-pipeline.sh — INFRA-1698 (META-066 phase 5)
#
# Pipeline orchestrator for the Content Bots Suite. Executes the DAG:
#
#                       ┌──→ DocuBot   ──┐
#   (Code Custodian) → PMM ┤                ├──→ CopyBot
#                       └──→ Evangelist ──┘
#
# Stages:
#   1. PMM runs first (leaf — consumes Code Custodian's architecture map).
#   2. On PMM success, DocuBot + Evangelist run in parallel (both consume
#      PMM's output via --predecessor-output).
#   3. CopyBot runs only when BOTH DocuBot and Evangelist succeed. It
#      consumes all three upstream outputs.
#
# Partial-failure handling:
#   - PMM fails        → entire run aborted; no downstream invocations.
#   - DocuBot fails    → CopyBot skipped (insufficient upstream context).
#   - Evangelist fails → CopyBot skipped.
#   On any abort: emit content_bot_pipeline_aborted to ambient.
#
# State tracking:
#   .chump-locks/content-bots/<run_id>/state.json holds per-stage status:
#     {pmm: ok|failed|skipped, docubot: …, evangelist: …, copybot: …}
#   Updated at each stage transition.
#
# Usage:
#   scripts/content-bots/orchestrate-pipeline.sh [--task <file>]
#                                                [--run-id <id>]
#                                                [--resume <run_id>]
#                                                [--dry-run]
#
# --resume re-reads state.json for the given run_id and picks up at the
# first non-ok stage (lets operator recover from an LLM transient failure
# without re-running PMM+upstream).
#
# Tracked: META-066 (productization), INFRA-1698 (this gap), INFRA-1695
# (dispatcher), INFRA-1700 (resolver), INFRA-1690 (foundation).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Honor CHUMP_DISPATCHER_OVERRIDE so smoke tests can swap in a stub without
# moving the orchestrator script (which would break BASH_SOURCE → REPO_ROOT
# resolution). Production code never sets this var.
DISPATCHER="${CHUMP_DISPATCHER_OVERRIDE:-$REPO_ROOT/scripts/content-bots/run-bot.sh}"
LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

# ── Arg parsing ──────────────────────────────────────────────────────────────
TASK_FILE=""
RUN_ID=""
RESUME=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK_FILE="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --resume) RUN_ID="$2"; RESUME=1; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -x "$DISPATCHER" ]]; then
    echo "[orchestrate] FAIL: dispatcher not found at $DISPATCHER" >&2
    echo "  INFRA-1695 must ship before the orchestrator can run." >&2
    exit 4
fi

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(date +%s)-$$"
fi
RUN_DIR="$LOCK_DIR/content-bots/$RUN_ID"
STATE_FILE="$RUN_DIR/state.json"
mkdir -p "$RUN_DIR"

# ── Ambient + state helpers ──────────────────────────────────────────────────
emit_event() {
    local kind="$1" payload="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$payload" \
        >> "$AMBIENT" 2>/dev/null || true
}

# Write state.json by reading current, updating one bot's status, writing back.
update_state() {
    local bot="$1" status="$2"
    python3 - "$STATE_FILE" "$bot" "$status" <<'PYEOF' 2>/dev/null
import json, os, sys
path, bot, status = sys.argv[1], sys.argv[2], sys.argv[3]
state = {}
if os.path.exists(path):
    try:
        state = json.load(open(path))
    except Exception:
        state = {}
state[bot] = status
with open(path, 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

# Read a bot's status from state.json (returns empty string if unset).
read_state() {
    local bot="$1"
    python3 - "$STATE_FILE" "$bot" <<'PYEOF' 2>/dev/null || true
import json, os, sys
path, bot = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    sys.exit(0)
try:
    s = json.load(open(path))
    print(s.get(bot, ""))
except Exception:
    pass
PYEOF
}

# Invoke the dispatcher for one bot. Stages = {pmm, docubot, evangelist, copybot}.
# Returns 0 on bot ok, non-zero on dispatcher failure.
run_bot() {
    local bot="$1"
    shift
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[orchestrate] DRY-RUN: would invoke $DISPATCHER $bot --run-id $RUN_ID $*"
        update_state "$bot" "ok"
        return 0
    fi
    if "$DISPATCHER" "$bot" --run-id "$RUN_ID" "$@"; then
        update_state "$bot" "ok"
        return 0
    else
        update_state "$bot" "failed"
        return 1
    fi
}

# Resume mode: if state.json has bot=ok already, skip the invocation.
should_skip() {
    [[ "$RESUME" == "1" ]] || return 1
    [[ "$(read_state "$1")" == "ok" ]]
}

abort_pipeline() {
    local reason="$1"
    emit_event "content_bot_pipeline_aborted" \
        "\"run_id\":\"$RUN_ID\",\"reason\":\"$reason\""
    echo "[orchestrate] ABORTED: $reason (run_id=$RUN_ID)" >&2
    echo "[orchestrate] state: $STATE_FILE" >&2
    exit 5
}

# ── Stage 1: PMM (leaf) ──────────────────────────────────────────────────────
echo "[orchestrate] run_id=$RUN_ID  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if should_skip pmm; then
    echo "[orchestrate] PMM: skipped (resume — already ok)"
else
    echo "[orchestrate] STAGE 1/3: PMM"
    # Build pmm args inline to avoid the `set -u` + empty-array trap.
    if [[ -n "$TASK_FILE" ]]; then
        if ! run_bot pmm --task "$TASK_FILE"; then
            abort_pipeline "pmm-failed"
        fi
    else
        if ! run_bot pmm; then
            abort_pipeline "pmm-failed"
        fi
    fi
fi

PMM_OUT="$RUN_DIR/pmm-output.md"

# ── Stage 2: DocuBot || Evangelist (parallel fan-out) ────────────────────────
echo "[orchestrate] STAGE 2/3: DocuBot + Evangelist (parallel)"

# Run both in subshells with their own log files so output doesn't interleave.
# We can't directly capture their exit codes from background jobs, so we
# write per-bot sentinel files {bot}.rc and inspect after `wait`.
DOCUBOT_RC=""
EVANGELIST_RC=""

# Per-bot subshells write only the .rc sentinel — we update state.json in
# the parent shell AFTER both branches complete to avoid a parallel-write
# race that loses one of the two updates.
# run_bot_quiet: invokes dispatcher (or echoes dry-run summary) but does NOT
# call update_state — the caller does that after waiting.
run_bot_quiet() {
    local bot="$1"; shift
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[orchestrate] DRY-RUN: would invoke $DISPATCHER $bot --run-id $RUN_ID $*"
        return 0
    fi
    "$DISPATCHER" "$bot" --run-id "$RUN_ID" "$@"
}

# DocuBot
if should_skip docubot; then
    echo "[orchestrate] DocuBot: skipped (resume — already ok)"
    DOCUBOT_RC=0
else
    (
        if run_bot_quiet docubot --predecessor-output "$PMM_OUT" \
            > "$RUN_DIR/docubot.log" 2>&1; then
            echo 0 > "$RUN_DIR/docubot.rc"
        else
            echo 1 > "$RUN_DIR/docubot.rc"
        fi
    ) &
    DOCUBOT_PID=$!
fi

# Evangelist
if should_skip evangelist; then
    echo "[orchestrate] Evangelist: skipped (resume — already ok)"
    EVANGELIST_RC=0
else
    (
        if run_bot_quiet evangelist --predecessor-output "$PMM_OUT" \
            > "$RUN_DIR/evangelist.log" 2>&1; then
            echo 0 > "$RUN_DIR/evangelist.rc"
        else
            echo 1 > "$RUN_DIR/evangelist.rc"
        fi
    ) &
    EVANGELIST_PID=$!
fi

# Wait for both parallel branches.
[[ -n "${DOCUBOT_PID:-}" ]]    && wait "$DOCUBOT_PID"    || true
[[ -n "${EVANGELIST_PID:-}" ]] && wait "$EVANGELIST_PID" || true

# Now serialize state.json updates (parent shell only — no parallel write race).
if [[ -z "$DOCUBOT_RC" ]]; then
    DOCUBOT_RC="$(cat "$RUN_DIR/docubot.rc" 2>/dev/null || echo 1)"
    if [[ "$DOCUBOT_RC" -eq 0 ]]; then update_state docubot ok; else update_state docubot failed; fi
fi
if [[ -z "$EVANGELIST_RC" ]]; then
    EVANGELIST_RC="$(cat "$RUN_DIR/evangelist.rc" 2>/dev/null || echo 1)"
    if [[ "$EVANGELIST_RC" -eq 0 ]]; then update_state evangelist ok; else update_state evangelist failed; fi
fi

if [[ "$DOCUBOT_RC" -ne 0 ]]; then
    update_state copybot skipped
    abort_pipeline "docubot-failed"
fi
if [[ "$EVANGELIST_RC" -ne 0 ]]; then
    update_state copybot skipped
    abort_pipeline "evangelist-failed"
fi

# ── Stage 3: CopyBot (terminus) ──────────────────────────────────────────────
echo "[orchestrate] STAGE 3/3: CopyBot"
if should_skip copybot; then
    echo "[orchestrate] CopyBot: skipped (resume — already ok)"
else
    # CopyBot's primary predecessor is PMM (positioning), but DocuBot and
    # Evangelist outputs are referenced via the task payload context.
    if ! run_bot copybot --predecessor-output "$PMM_OUT"; then
        abort_pipeline "copybot-failed"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
emit_event "content_bot_pipeline_step" \
    "\"from_bot\":\"orchestrate\",\"to_bot\":\"complete\",\"output_path\":\"$RUN_DIR\",\"run_id\":\"$RUN_ID\""

echo "[orchestrate] OK pipeline complete (run_id=$RUN_ID)"
echo "  outputs: $RUN_DIR/{pmm,docubot,evangelist,copybot}-output.md"
echo "  state:   $STATE_FILE"
