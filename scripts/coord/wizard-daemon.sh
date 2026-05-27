#!/usr/bin/env bash
# scripts/coord/wizard-daemon.sh — META-109 Phase 1 (THE FLOOR DRIVE primitive)
#
# Autonomous orchestrator that drives PRs toward merge without requiring a
# human operator or Opus session on duty.
#
# Phase 1 (this file) — Steps 1, 2, 6 + safety + audit:
#   Step 1 — Poll open PR queue (cache-first); classify each PR state
#   Step 2 — BLOCKED+stale-base or BLOCKED+cascading → trigger recovery-queue
#   Step 6 — Consume fleet_stalled / worker_stuck ambient events → broadcast CRIT
#
# Deferred (Phase 2 — separate follow-up gap):
#   Step 3 — real-fails URGENT-INBOX with author tag
#   Step 4 — pickable gap dispatch via chump --execute-gap
#   Step 5 — cascade rebase after a cluster clears
#
# Safety (mandatory — NEVER remove):
#   - REFUSES to act when `chump health --temp` is HOT
#   - REFUSES to act on a PR with mergeStateStatus=CONFLICTING
#   - REFUSES to run when CHUMP_WIZARD_DAEMON_PAUSE=1
#   - DEFAULT DISABLED: requires CHUMP_WIZARD_DAEMON_ENABLED=1 to run
#
# Usage:
#   CHUMP_WIZARD_DAEMON_ENABLED=1 bash scripts/coord/wizard-daemon.sh
#   CHUMP_WIZARD_DAEMON_PAUSE=1   bash scripts/coord/wizard-daemon.sh  # no-op
#
# Env overrides (testing + ops):
#   CHUMP_WIZARD_DAEMON_ENABLED=1     required to run (default: off)
#   CHUMP_WIZARD_DAEMON_PAUSE=1       emergency kill-switch (operator level)
#   CHUMP_AMBIENT_LOG                 override ambient.jsonl path
#   CHUMP_REPO / CHUMP_REPO_ROOT      override repo root
#   CHUMP_WIZARD_TEST_GH              path to mock gh binary (tests)
#   CHUMP_WIZARD_TEST_CHUMP           path to mock chump binary (tests)
#   CHUMP_WIZARD_RECOVERY_RATE_LIMIT  max recovery-queue emits per cycle (default 3)
#   CHUMP_WIZARD_STALL_LOOKBACK_S     how far back to scan ambient for stall events (default 600)
#
# Audit events emitted:
#   wizard_daemon_action        — every classification + decision
#   wizard_daemon_paused        — emitted once when PAUSE=1 is detected
#   wizard_daemon_safety_refusal — HOT-temp or CONFLICTING refusal
#
# Launchd: scripts/setup/install-wizard-daemon-launchd.sh (5-min cadence)
# Kill switch: CHUMP_WIZARD_DAEMON_PAUSE=1 OR remove plist from ~/Library/LaunchAgents/
#
# scanner-anchor: "kind":"wizard_daemon_action"
# scanner-anchor: "kind":"wizard_daemon_paused"
# scanner-anchor: "kind":"wizard_daemon_safety_refusal"

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GH="${CHUMP_WIZARD_TEST_GH:-gh}"
CHUMP_BIN="${CHUMP_WIZARD_TEST_CHUMP:-chump}"

RECOVERY_RATE_LIMIT="${CHUMP_WIZARD_RECOVERY_RATE_LIMIT:-3}"
STALL_LOOKBACK_S="${CHUMP_WIZARD_STALL_LOOKBACK_S:-600}"

EMIT_SCRIPT="$REPO_ROOT/scripts/coord/recovery-queue-emit.sh"
BROADCAST_SCRIPT="$REPO_ROOT/scripts/coord/broadcast-urgent.sh"
FLOOR_HOLD_SCRIPT="$REPO_ROOT/scripts/coord/fleet-hold-check.sh"
LIB_CACHE="$REPO_ROOT/scripts/coord/lib/github_cache.sh"

# Per-run rate-limit counter (recovery-queue emits this cycle)
_RECOVERY_EMITS_THIS_RUN=0

# ── Utilities ─────────────────────────────────────────────────────────────────

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[wizard-daemon %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

emit_ambient() {
    local kind="$1" extra="${2:-}"
    local line
    local timestamp; timestamp="$(ts)"
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$timestamp\",\"kind\":\"$kind\",\"source\":\"wizard_daemon\",$extra}"
    else
        line="{\"ts\":\"$timestamp\",\"kind\":\"$kind\",\"source\":\"wizard_daemon\"}"
    fi
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

emit_action() {
    local step="$1" target="$2" decision="$3" extra="${4:-}"
    local rl_state="emits_this_run=${_RECOVERY_EMITS_THIS_RUN},limit=${RECOVERY_RATE_LIMIT}"
    local fields="\"step\":\"$step\",\"target\":\"$target\",\"decision\":\"$decision\",\"rate_limit_state\":\"$rl_state\""
    [[ -n "$extra" ]] && fields="$fields,$extra"
    emit_ambient "wizard_daemon_action" "$fields"
    log "action step=$step target=$target decision=$decision"
}

emit_safety_refusal() {
    local reason="$1" target="${2:-}"
    emit_ambient "wizard_daemon_safety_refusal" \
        "\"reason\":\"$reason\",\"target\":\"$target\""
    log "SAFETY REFUSAL: reason=$reason target=$target"
}

# ── Guard: ENABLED check ──────────────────────────────────────────────────────

if [[ "${CHUMP_WIZARD_DAEMON_ENABLED:-0}" != "1" ]]; then
    log "wizard-daemon: NOT enabled (set CHUMP_WIZARD_DAEMON_ENABLED=1 to activate)"
    log "  This is a default-OFF safety feature. Enable only after Sprint 1-3 floor validation."
    exit 0
fi

# ── Guard: PAUSE kill-switch ──────────────────────────────────────────────────

if [[ "${CHUMP_WIZARD_DAEMON_PAUSE:-0}" == "1" ]]; then
    emit_ambient "wizard_daemon_paused" "\"reason\":\"CHUMP_WIZARD_DAEMON_PAUSE=1\""
    log "wizard-daemon: PAUSED (CHUMP_WIZARD_DAEMON_PAUSE=1)"
    exit 0
fi

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

log "wizard-daemon: starting (Phase 1 — steps 1, 2, 6)"

# ── Guard: fleet-hold ─────────────────────────────────────────────────────────
# If cluster-detector has raised a fleet-hold, respect it.
if [[ -x "$FLOOR_HOLD_SCRIPT" ]]; then
    if ! bash "$FLOOR_HOLD_SCRIPT" --quiet 2>/dev/null; then
        emit_action "preflight" "fleet-hold" "stand_down" \
            "\"reason\":\"fleet_hold_active\""
        log "wizard-daemon: fleet-hold active — standing down this cycle"
        exit 0
    fi
fi

# ── Guard: HOT temperature ────────────────────────────────────────────────────
# chump health --temp exits 0 on COLD/WARM, non-zero on HOT (or if cmd absent).
# If the health command isn't available, default to safe (proceed).
_floor_temp="UNKNOWN"
if command -v "$CHUMP_BIN" >/dev/null 2>&1; then
    _temp_out="$("$CHUMP_BIN" health --temp 2>/dev/null || true)"
    if printf '%s\n' "$_temp_out" | grep -qi "HOT"; then
        _floor_temp="HOT"
        emit_safety_refusal "floor_temp_HOT" "fleet"
        emit_action "preflight" "fleet" "stand_down" \
            "\"reason\":\"floor_temp_HOT\",\"temp_output\":\"$_temp_out\""
        log "wizard-daemon: floor temp is HOT — refusing to act (cascade preventer)"
        exit 0
    else
        _floor_temp="$(printf '%s\n' "$_temp_out" | grep -oE 'COLD|WARM|HOT' | head -1 || echo 'COLD')"
    fi
fi

log "wizard-daemon: floor_temp=$_floor_temp — proceeding"

# ── Load cache library ────────────────────────────────────────────────────────

if [[ -f "$LIB_CACHE" ]]; then
    # shellcheck source=scripts/coord/lib/github_cache.sh
    # shellcheck disable=SC1091  # path is dynamic (runtime-resolved REPO_ROOT)
    source "$LIB_CACHE"
    _CACHE_AVAILABLE=1
else
    _CACHE_AVAILABLE=0
    log "WARN: github_cache.sh not found — will use gh pr list directly"
fi

# ── Step 1: Poll PR queue + classify ─────────────────────────────────────────
#
# For each open PR, classify:
#   CLEAN+armed          — mergeable, auto-merge enabled, no failures
#   BLOCKED+stale-base   — BEHIND (needs rebase), auto-merge enabled
#   BLOCKED+real-fails   — CI failures (non-cascading), needs human/triage
#   BLOCKED+cascading    — CI failures consistent with trunk-RED cluster
#   DIRTY                — has changes but not auto-merge-armed
#   CONFLICTING          — mergeStateStatus=CONFLICTING (real conflict)
#
log "Step 1: classifying open PR queue..."

step1_classify_prs() {
    # Returns lines: "<number> <class>"
    local open_prs=""

    # Prefer cache; fall back to REST
    if [[ "$_CACHE_AVAILABLE" == "1" ]]; then
        local cached_raw
        cached_raw="$(cache_query_open_prs 2>/dev/null || true)"
        if [[ -n "$cached_raw" ]]; then
            # cache returns: number\ttitle\thead_ref per line
            open_prs="$(printf '%s\n' "$cached_raw" | awk -F'\t' '{print $1}')"
        fi
    fi

    # Fall back: direct gh pr list (background-tagged to yield bucket)
    if [[ -z "$open_prs" ]]; then
        open_prs="$(CHUMP_GH_CALL_CRITICALITY=background \
            "$GH" pr list --state open --json number \
            --jq '.[].number' 2>/dev/null || true)"
    fi

    if [[ -z "$open_prs" ]]; then
        log "Step 1: no open PRs found"
        return 0
    fi

    local pr_count; pr_count="$(printf '%s\n' "$open_prs" | wc -l | tr -d ' ')"
    log "Step 1: found $pr_count open PR(s)"

    # Check if a cluster fleet-hold is active (BLOCKED+cascading classifier signal)
    local hold_active=0
    if [[ -f "$REPO_ROOT/.chump-locks/fleet-hold.txt" ]]; then
        hold_active=1
    fi

    while IFS= read -r pr_num; do
        [[ -z "$pr_num" ]] && continue

        # Fetch PR state — cache-first
        local pr_json=""
        if [[ "$_CACHE_AVAILABLE" == "1" ]]; then
            pr_json="$(cache_lookup_pr "$pr_num" --max-age-s 120 2>/dev/null || true)"
        fi
        if [[ -z "$pr_json" ]]; then
            pr_json="$(CHUMP_GH_CALL_CRITICALITY=background \
                "$GH" pr view "$pr_num" --json number,title,mergeable,mergeStateStatus,autoMergeRequest,isDraft 2>/dev/null || true)"
        fi

        if [[ -z "$pr_json" ]]; then
            log "Step 1: PR #$pr_num — could not fetch state, skipping"
            emit_action "step1" "PR#$pr_num" "skip_fetch_failed"
            continue
        fi

        # Extract fields via python3 (avoids jq dependency, consistent parsing)
        local fields
        fields="$(python3 - "$pr_json" <<'PY' 2>/dev/null || echo "ERROR"
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("ERROR"); sys.exit(0)

mergeable       = d.get("mergeable","")          or ""
merge_state     = d.get("mergeStateStatus","")   or ""
auto_merge      = "1" if d.get("autoMergeRequest") else "0"
is_draft        = "1" if d.get("isDraft") else "0"
title           = (d.get("title") or "").replace('"','').replace("'","")[:80]

print(f"{mergeable}|{merge_state}|{auto_merge}|{is_draft}|{title}")
PY
)"

        if [[ "$fields" == "ERROR" ]] || [[ -z "$fields" ]]; then
            log "Step 1: PR #$pr_num — parse error, skipping"
            emit_action "step1" "PR#$pr_num" "skip_parse_error"
            continue
        fi

        IFS='|' read -r mergeable merge_state auto_merge is_draft pr_title <<<"$fields"

        # ── Classification logic ─────────────────────────────────────────────
        local pr_class="UNKNOWN"

        if [[ "$is_draft" == "1" ]]; then
            pr_class="DIRTY"
        elif [[ "$merge_state" == "CONFLICTING" ]]; then
            pr_class="CONFLICTING"
        elif [[ "$merge_state" == "BEHIND" ]] && [[ "$auto_merge" == "1" ]]; then
            # BEHIND + auto-armed = needs rebase
            if [[ "$hold_active" == "1" ]]; then
                # Fleet hold is active → likely cascading from trunk-RED
                pr_class="BLOCKED+cascading"
            else
                pr_class="BLOCKED+stale-base"
            fi
        elif [[ "$merge_state" == "BLOCKED" ]] || [[ "$merge_state" == "DIRTY" ]]; then
            if [[ "$hold_active" == "1" ]]; then
                pr_class="BLOCKED+cascading"
            else
                pr_class="BLOCKED+real-fails"
            fi
        elif [[ "$mergeable" == "MERGEABLE" ]] && [[ "$auto_merge" == "1" ]]; then
            pr_class="CLEAN+armed"
        elif [[ "$auto_merge" == "0" ]]; then
            pr_class="DIRTY"
        else
            pr_class="UNKNOWN"
        fi

        log "Step 1: PR #$pr_num class=$pr_class merge_state=$merge_state auto_merge=$auto_merge"
        emit_action "step1" "PR#$pr_num" "classified" \
            "\"pr_class\":\"$pr_class\",\"merge_state\":\"$merge_state\",\"auto_merge\":\"$auto_merge\",\"title\":\"$pr_title\""

        # Route to Step 2 handler
        step2_handle_pr "$pr_num" "$pr_class" "$pr_title"

    done < <(printf '%s\n' "$open_prs")
}

# ── Step 2: Recovery-queue for BLOCKED+stale-base / BLOCKED+cascading ────────
#
# Rate-limited: max RECOVERY_RATE_LIMIT emits per wizard-daemon run.
# The service (recovery-queue-service.sh) further enforces 3/hr fleet-wide.
#
step2_handle_pr() {
    local pr_num="$1" pr_class="$2" pr_title="$3"

    case "$pr_class" in
        "BLOCKED+stale-base"|"BLOCKED+cascading")
            ;;
        "CONFLICTING")
            # Safety: REFUSE to touch conflicting PRs
            emit_safety_refusal "pr_conflicting" "PR#$pr_num"
            emit_action "step2" "PR#$pr_num" "refused_conflicting" \
                "\"pr_class\":\"$pr_class\",\"reason\":\"real_conflict_needs_human\""
            return 0
            ;;
        *)
            # Not a case for Step 2
            return 0
            ;;
    esac

    # Rate limit: don't flood the recovery queue
    if [[ "$_RECOVERY_EMITS_THIS_RUN" -ge "$RECOVERY_RATE_LIMIT" ]]; then
        emit_action "step2" "PR#$pr_num" "rate_limited" \
            "\"pr_class\":\"$pr_class\",\"emits_this_run\":$_RECOVERY_EMITS_THIS_RUN,\"limit\":$RECOVERY_RATE_LIMIT"
        log "Step 2: PR #$pr_num rate-limited (already emitted $_RECOVERY_EMITS_THIS_RUN this run)"
        return 0
    fi

    if [[ ! -x "$EMIT_SCRIPT" ]]; then
        log "WARN: Step 2: recovery-queue-emit.sh not found at $EMIT_SCRIPT"
        emit_action "step2" "PR#$pr_num" "skip_no_emit_script" \
            "\"pr_class\":\"$pr_class\""
        return 0
    fi

    local reason="wizard-daemon detected PR #$pr_num as $pr_class"
    log "Step 2: emitting recovery-queue request for PR #$pr_num ($pr_class)"

    bash "$EMIT_SCRIPT" \
        --prs "$pr_num" \
        --reason "$reason" 2>/dev/null || true

    _RECOVERY_EMITS_THIS_RUN=$((_RECOVERY_EMITS_THIS_RUN + 1))

    emit_action "step2" "PR#$pr_num" "recovery_queue_emitted" \
        "\"pr_class\":\"$pr_class\",\"emits_this_run\":$_RECOVERY_EMITS_THIS_RUN"
}

# ── Step 6: Consume fleet_stalled / worker_stuck events → broadcast CRIT ─────
#
# Scans trailing STALL_LOOKBACK_S of ambient.jsonl for fleet_stalled or
# worker_stuck events. If found and no CRIT has been broadcast recently
# for the same reason, broadcasts to URGENT-INBOX.
#
step6_broadcast_on_stall() {
    log "Step 6: scanning for fleet_stalled / worker_stuck events..."

    if [[ ! -f "$AMBIENT" ]]; then
        log "Step 6: ambient.jsonl not found — skipping"
        return 0
    fi

    # Find events in the lookback window
    local cutoff_epoch
    cutoff_epoch="$(date -u -v-"${STALL_LOOKBACK_S}"S +%s 2>/dev/null \
        || date -u -d "-${STALL_LOOKBACK_S} seconds" +%s 2>/dev/null \
        || echo "0")"

    # Grep for the two stall-class event kinds
    local stall_events
    stall_events="$(grep -E '"kind":"(fleet_stalled|worker_stuck)"' "$AMBIENT" 2>/dev/null \
        | tail -100 || true)"

    if [[ -z "$stall_events" ]]; then
        log "Step 6: no stall events in ambient — nothing to broadcast"
        return 0
    fi

    # Filter to events within lookback window using python (reliable ISO8601 parse)
    local recent_stalls
    recent_stalls="$(python3 - "$stall_events" "$cutoff_epoch" <<'PY' 2>/dev/null || true
import json, sys, datetime

raw_lines = sys.argv[1].strip().split('\n')
try:
    cutoff = int(sys.argv[2])
except Exception:
    cutoff = 0

recent = []
for line in raw_lines:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    ts_str = d.get("ts","")
    try:
        # Parse ISO8601 — strip Z, then parse
        t = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
        epoch = int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        epoch = 0
    if epoch >= cutoff:
        recent.append(d)

for evt in recent:
    print(json.dumps(evt))
PY
)"

    if [[ -z "$recent_stalls" ]]; then
        log "Step 6: stall events found but outside lookback window — no broadcast"
        return 0
    fi

    local stall_count; stall_count="$(printf '%s\n' "$recent_stalls" | wc -l | tr -d ' ')"

    # Dedup: don't re-broadcast if we already sent a wizard CRIT in the last cycle
    local already_broadcast=0
    local recent_wizard_crit
    recent_wizard_crit="$(grep -E '"kind":"wizard_daemon_action".*"step":"step6".*"decision":"broadcast_crit"' \
        "$AMBIENT" 2>/dev/null | tail -5 || true)"
    if [[ -n "$recent_wizard_crit" ]]; then
        # Check if it's within the lookback window
        local last_broadcast_epoch
        last_broadcast_epoch="$(python3 - "$recent_wizard_crit" <<'PY' 2>/dev/null || echo 0
import json, sys, datetime
lines = sys.argv[1].strip().split('\n')
epochs = []
for l in lines:
    try:
        d = json.loads(l.strip())
        ts = d.get("ts","")
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
        epochs.append(int(t.replace(tzinfo=datetime.timezone.utc).timestamp()))
    except Exception:
        pass
print(max(epochs) if epochs else 0)
PY
)"
        local now_epoch; now_epoch="$(date -u +%s)"
        local age=$(( now_epoch - last_broadcast_epoch ))
        if [[ "$age" -lt "$STALL_LOOKBACK_S" ]]; then
            already_broadcast=1
        fi
    fi

    if [[ "$already_broadcast" == "1" ]]; then
        log "Step 6: already broadcast CRIT within lookback window — deduping"
        emit_action "step6" "fleet" "broadcast_deduped" \
            "\"stall_events_found\":$stall_count"
        return 0
    fi

    # Build summary of first stall event
    local summary_kind
    summary_kind="$(printf '%s\n' "$recent_stalls" | head -1 | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('kind','stall'))" 2>/dev/null \
        || echo "stall")"

    local broadcast_msg="wizard-daemon: $stall_count stall event(s) detected in last ${STALL_LOOKBACK_S}s (kind=$summary_kind) — triage required"

    if [[ ! -x "$BROADCAST_SCRIPT" ]]; then
        log "WARN: Step 6: broadcast-urgent.sh not found at $BROADCAST_SCRIPT"
        emit_action "step6" "fleet" "skip_no_broadcast_script" \
            "\"stall_events_found\":$stall_count"
        return 0
    fi

    log "Step 6: broadcasting CRIT — $stall_count stall event(s) found"
    bash "$BROADCAST_SCRIPT" \
        --urgency CRIT \
        --from "wizard-daemon" \
        "$broadcast_msg" 2>/dev/null || true

    emit_action "step6" "fleet" "broadcast_crit" \
        "\"stall_events_found\":$stall_count,\"kind\":\"$summary_kind\",\"msg\":\"$broadcast_msg\""
}

# ── Run the orchestration loop ────────────────────────────────────────────────

step1_classify_prs
step6_broadcast_on_stall

log "wizard-daemon: Phase 1 cycle complete (recovery_emits=$_RECOVERY_EMITS_THIS_RUN)"
emit_ambient "wizard_daemon_action" \
    "\"step\":\"cycle_complete\",\"target\":\"fleet\",\"decision\":\"done\",\"recovery_emits_this_run\":$_RECOVERY_EMITS_THIS_RUN,\"rate_limit_state\":\"limit=${RECOVERY_RATE_LIMIT}\""

exit 0
