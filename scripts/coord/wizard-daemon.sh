#!/usr/bin/env bash
# scripts/coord/wizard-daemon.sh — META-109/META-107 (THE FLOOR DRIVE primitive)
#
# Autonomous orchestrator that drives PRs toward merge without requiring a
# human operator or Opus session on duty.
#
# Phase 1 (META-109) — Steps 1, 2, 6 + safety + audit:
#   Step 1 — Poll open PR queue (cache-first); classify each PR state
#   Step 2 — BLOCKED+stale-base or BLOCKED+cascading → trigger recovery-queue
#   Step 6 — Consume fleet_stalled / worker_stuck ambient events → broadcast CRIT
#
# Phase 2 (META-107) — Steps 3, 4, 5 completing the DRIVE primitive:
#   Step 3 — BLOCKED+real-fails → match W-NNN catalog signatures → emit
#             wedge_detected OR broadcast CRIT to URGENT-INBOX with author tag
#   Step 4 — Pickable-gap dispatch: P0/P1 gaps with no lease + AC complete
#             → spawn `chump --execute-gap <ID>` background; rate-limited to
#             CHUMP_WIZARD_MAX_PARALLEL concurrent (default 4)
#   Step 5 — Post-merge cascade rebase: after a gap ships, identify OTHER PRs
#             blocked on the same trunk-RED → trigger gh pr update-branch;
#             rate-limited to 3/hr per INFRA-1993 recovery-queue
#
# Safety (mandatory — NEVER remove):
#   - REFUSES to act when `chump health --temp` is HOT
#   - REFUSES to act on a PR with mergeStateStatus=CONFLICTING
#   - REFUSES to run when CHUMP_WIZARD_DAEMON_PAUSE=1
#   - REFUSES to dispatch >CHUMP_WIZARD_MAX_PARALLEL concurrent gaps (Step 4)
#   - REFUSES to dispatch gaps tagged wizard_skip:true (Step 4)
#   - REFUSES cascade rebase on PRs not authored by repairman29 (Step 5 anti-fork-takeover)
#   - DEFAULT DISABLED: requires CHUMP_WIZARD_DAEMON_ENABLED=1 to run
#
# Usage:
#   CHUMP_WIZARD_DAEMON_ENABLED=1 bash scripts/coord/wizard-daemon.sh
#   CHUMP_WIZARD_DAEMON_PAUSE=1   bash scripts/coord/wizard-daemon.sh  # no-op
#
# Env overrides (testing + ops):
#   CHUMP_WIZARD_DAEMON_ENABLED=1       required to run (default: off)
#   CHUMP_WIZARD_DAEMON_PAUSE=1         emergency kill-switch (operator level)
#   CHUMP_AMBIENT_LOG                   override ambient.jsonl path
#   CHUMP_REPO / CHUMP_REPO_ROOT        override repo root
#   CHUMP_WIZARD_TEST_GH                path to mock gh binary (tests)
#   CHUMP_WIZARD_TEST_CHUMP             path to mock chump binary (tests)
#   CHUMP_WIZARD_RECOVERY_RATE_LIMIT    max recovery-queue emits per cycle (default 3)
#   CHUMP_WIZARD_STALL_LOOKBACK_S       how far back to scan ambient for stall events (default 600)
#   CHUMP_WIZARD_MAX_PARALLEL           max concurrent gap dispatches (default 4)
#   CHUMP_WIZARD_DISPATCH_STATE         path to dispatch state JSON (default .chump-locks/wizard-daemon-dispatch-state.json)
#   CHUMP_WIZARD_DISPATCH_WINDOW_S      sliding window for dispatch tracking (default 3600)
#   CHUMP_WIZARD_CASCADE_RATE_LIMIT     max cascade rebases per cycle (default 3)
#   CHUMP_WIZARD_ALLOWED_REBASE_AUTHOR  PR author allowed for cascade rebase (default: repairman29)
#
# Audit events emitted:
#   wizard_daemon_action           — every classification + decision
#   wizard_daemon_paused           — emitted once when PAUSE=1 is detected
#   wizard_daemon_safety_refusal   — HOT-temp or CONFLICTING refusal
#   wizard_classify_deferred       — PR skipped this iteration: GitHub returned UNKNOWN merge state (INFRA-2042)
#   wedge_detected                 — W-NNN match for BLOCKED+real-fails PR (Step 3)
#   wizard_dispatch_executed       — gap dispatch fired via chump --execute-gap (Step 4)
#   wizard_dispatch_rate_limited   — dispatch refused (already at max parallel) (Step 4)
#   wizard_gap_skipped             — gap skipped due to wizard_skip:true (Step 4)
#   wizard_cascade_rebase_triggered — cascade rebase triggered for a sibling PR (Step 5)
#
# Launchd: scripts/setup/install-wizard-daemon-launchd.sh (5-min cadence)
# Kill switch: CHUMP_WIZARD_DAEMON_PAUSE=1 OR remove plist from ~/Library/LaunchAgents/
#
# scanner-anchor: "kind":"wizard_daemon_action"
# scanner-anchor: "kind":"wizard_daemon_paused"
# scanner-anchor: "kind":"wizard_daemon_safety_refusal"
# scanner-anchor: "kind":"wizard_classify_deferred"
# scanner-anchor: "kind":"wedge_detected"
# scanner-anchor: "kind":"wizard_dispatch_executed"
# scanner-anchor: "kind":"wizard_dispatch_rate_limited"
# scanner-anchor: "kind":"wizard_gap_skipped"
# scanner-anchor: "kind":"wizard_cascade_rebase_triggered"

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GH="${CHUMP_WIZARD_TEST_GH:-gh}"
CHUMP_BIN="${CHUMP_WIZARD_TEST_CHUMP:-chump}"

RECOVERY_RATE_LIMIT="${CHUMP_WIZARD_RECOVERY_RATE_LIMIT:-3}"
STALL_LOOKBACK_S="${CHUMP_WIZARD_STALL_LOOKBACK_S:-600}"

# Phase 2 config
MAX_PARALLEL="${CHUMP_WIZARD_MAX_PARALLEL:-4}"
DISPATCH_STATE="${CHUMP_WIZARD_DISPATCH_STATE:-$REPO_ROOT/.chump-locks/wizard-daemon-dispatch-state.json}"
DISPATCH_WINDOW_S="${CHUMP_WIZARD_DISPATCH_WINDOW_S:-3600}"
CASCADE_RATE_LIMIT="${CHUMP_WIZARD_CASCADE_RATE_LIMIT:-3}"
ALLOWED_REBASE_AUTHOR="${CHUMP_WIZARD_ALLOWED_REBASE_AUTHOR:-repairman29}"
# Note: Step 3 uses an inline keyword pattern table derived from
# docs/process/WEDGE_CLASS_CATALOG.md — update both when adding new W-NNN classes.

EMIT_SCRIPT="$REPO_ROOT/scripts/coord/recovery-queue-emit.sh"
BROADCAST_SCRIPT="$REPO_ROOT/scripts/coord/broadcast-urgent.sh"
FLOOR_HOLD_SCRIPT="$REPO_ROOT/scripts/coord/fleet-hold-check.sh"
LIB_CACHE="$REPO_ROOT/scripts/coord/lib/github_cache.sh"

# Per-run rate-limit counters
_RECOVERY_EMITS_THIS_RUN=0
_CASCADE_REBASES_THIS_RUN=0

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

log "wizard-daemon: starting (Phase 1+2 — steps 1, 2, 3, 4, 5, 6)"

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
        elif [[ "$merge_state" == "UNKNOWN" ]]; then
            # GitHub API returns UNKNOWN when mergeability hasn't been computed yet
            # (checks haven't started, or PR was just pushed). Defer this iteration
            # rather than misclassifying as DIRTY and triggering recovery actions.
            emit_ambient "wizard_classify_deferred" \
                "\"pr\":$pr_num,\"reason\":\"unknown_merge_state\",\"title\":\"$pr_title\""
            emit_action "step1" "PR#$pr_num" "deferred" \
                "\"merge_state\":\"$merge_state\",\"reason\":\"unknown_merge_state_not_yet_computed\",\"auto_merge\":\"$auto_merge\",\"title\":\"$pr_title\""
            log "Step 1: PR #$pr_num — UNKNOWN merge_state (GitHub computing), deferring this iteration"
            continue
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

        # Route to Step 2 handler (stale-base / cascading recovery)
        step2_handle_pr "$pr_num" "$pr_class" "$pr_title"

        # Route to Step 3 handler (real-fails classification + URGENT-INBOX)
        step3_handle_real_fails "$pr_num" "$pr_class" "$pr_title" "$pr_json"

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

# ── Step 3: BLOCKED+real-fails → W-NNN classification + URGENT-INBOX ─────────
#
# For each BLOCKED+real-fails PR:
#   1. Fetch failing check names from gh pr checks
#   2. Match against WEDGE_CLASS_CATALOG.md W-NNN signatures
#   3a. Matched → emit kind=wedge_detected (wedge-state-machine consumes)
#   3b. Unknown → broadcast CRIT to URGENT-INBOX with author tag + PR summary
#
# Signature matching uses keyword patterns extracted from the catalog.
# These patterns are intentionally conservative — false negatives are OK
# (they escalate to CRIT); false positives (wrong W-NNN) waste a remediation.
#
step3_handle_real_fails() {
    local pr_num="$1" pr_class="$2" pr_title="$3" pr_json="${4:-}"

    [[ "$pr_class" == "BLOCKED+real-fails" ]] || return 0

    log "Step 3: PR #$pr_num — classifying real failures..."

    # Fetch check run details for this PR
    local checks_json=""
    local head_sha=""
    head_sha="$(printf '%s\n' "$pr_json" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('headRefOid','') or d.get('headRefSha','') or '')" \
        2>/dev/null || true)"

    if [[ -n "$head_sha" ]] && [[ "$_CACHE_AVAILABLE" == "1" ]]; then
        checks_json="$(cache_lookup_checks "$head_sha" 2>/dev/null || true)"
    fi

    # Fall back to gh pr checks
    if [[ -z "$checks_json" ]]; then
        checks_json="$(CHUMP_GH_CALL_CRITICALITY=background \
            "$GH" pr checks "$pr_num" --json name,state,conclusion \
            2>/dev/null || true)"
    fi

    # Extract failing check names
    local failing_checks=""
    failing_checks="$(python3 - "$checks_json" <<'PY' 2>/dev/null || true
import json, sys
raw = sys.argv[1].strip() if len(sys.argv) > 1 else ""
if not raw:
    sys.exit(0)
try:
    # Try JSON array format (from gh pr checks --json)
    checks = json.loads(raw)
    if isinstance(checks, list):
        for c in checks:
            conclusion = c.get("conclusion","") or ""
            state = c.get("state","") or ""
            if conclusion in ("failure","timed_out","cancelled") or state == "FAILURE":
                name = c.get("name","") or ""
                if name:
                    print(name)
        sys.exit(0)
except Exception:
    pass
# Tab-separated format from cache (name\tstatus\tconclusion per line)
for line in raw.splitlines():
    parts = line.split("\t")
    if len(parts) >= 3:
        name, status, conclusion = parts[0], parts[1], parts[2]
        if conclusion in ("failure","timed_out","cancelled") or status == "FAILURE":
            print(name)
PY
)"

    # Fetch PR author for URGENT-INBOX tag
    local pr_author=""
    pr_author="$(printf '%s\n' "$pr_json" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('author',{}).get('login','') or d.get('headRefName','') or 'unknown')" \
        2>/dev/null || true)"
    [[ -z "$pr_author" ]] && pr_author="unknown"

    if [[ -z "$failing_checks" ]]; then
        log "Step 3: PR #$pr_num — no failing check names found, skipping catalog match"
        emit_action "step3" "PR#$pr_num" "skip_no_failing_checks" \
            "\"pr_class\":\"$pr_class\",\"author\":\"$pr_author\""
        return 0
    fi

    log "Step 3: PR #$pr_num — failing checks: $(printf '%s\n' "$failing_checks" | tr '\n' ' ')"

    # Match failing check names against W-NNN catalog signatures
    # Pattern table: (wedge_class, grep_pattern_in_check_name_or_failure)
    # Ordered most-specific first to reduce false-positive rate.
    local matched_class=""
    matched_class="$(python3 - "$failing_checks" <<'PY' 2>/dev/null || true
import sys, re

failing = sys.argv[1].strip().lower() if len(sys.argv) > 1 else ""

# (wedge_class, list_of_keyword_patterns)
# Patterns match against the concatenated failing check names (lowercased).
CATALOG = [
    # W-001: gh API false-positive merge conflicts
    ("W-001", ["pr_auto_rebase_failed", "auto_rebase", "cannot update pr branch"]),
    # W-002: Runner-side binary cache lag
    ("W-002", ["runner-binary", "binary cache", "chump --version", "binary-lag"]),
    # W-003: Config-warning stdout pollution
    ("W-003", ["config warning", "discord_token", "config-warning"]),
    # W-004: sqlite lock contention
    ("W-004", ["r2d2", "database is locked", "sqlite", "lock contention"]),
    # W-005: GIT_DIR env-leak
    ("W-005", ["git_dir", "pre-push-force-lease", "force-lease-guard"]),
    # W-007: Required-status-check absent
    ("W-007", ["required-status", "required_status", "status check absent", "required check"]),
    # W-008: Auto-merge wedged on CLEAN
    ("W-008", ["auto-merge", "auto_merge", "clean state", "wedged"]),
    # W-009: Cascade keystone
    ("W-009", ["cascade", "keystone", "children blocked"]),
    # W-010: Multi-layer protection
    ("W-010", ["repository rule violations", "ruleset", "branch protection"]),
    # W-011: Installer-manifest drift
    ("W-011", ["manifest", "installer", "unmapped", "install-script"]),
    # W-012: Workflow-env-overhead
    ("W-012", ["chump_repo", "workflow.*env", "overhead.*cascade"]),
    # W-013: Ambient path mismatch
    ("W-013", ["ambient.*path", "chump_lock_dir", "ambient-path"]),
]

for wedge_class, patterns in CATALOG:
    for pat in patterns:
        try:
            if re.search(pat, failing):
                print(wedge_class)
                sys.exit(0)
        except re.error:
            if pat in failing:
                print(wedge_class)
                sys.exit(0)

# No match
print("")
PY
)"

    if [[ -n "$matched_class" ]]; then
        # Matched a known W-NNN class → emit wedge_detected for state-machine
        log "Step 3: PR #$pr_num — matched $matched_class → emitting wedge_detected"
        local fail_summary
        fail_summary="$(printf '%s\n' "$failing_checks" | head -3 | tr '\n' ',' | sed 's/,$//')"
        emit_ambient "wedge_detected" \
            "\"wedge_class\":\"$matched_class\",\"pr_number\":$pr_num,\"pr_title\":\"$(printf '%s' "$pr_title" | head -c 60)\",\"failing_checks\":\"$fail_summary\",\"source\":\"wizard_daemon_step3\""
        emit_action "step3" "PR#$pr_num" "wedge_detected" \
            "\"wedge_class\":\"$matched_class\",\"author\":\"$pr_author\",\"failing_checks\":\"$fail_summary\""
    else
        # Unknown failure class → URGENT-INBOX with author tag
        log "Step 3: PR #$pr_num — unknown failure class, broadcasting to URGENT-INBOX (author=$pr_author)"
        local fail_summary
        fail_summary="$(printf '%s\n' "$failing_checks" | head -3 | tr '\n' ',' | sed 's/,$//')"
        local bcast_msg="wizard-daemon: PR #$pr_num BLOCKED+real-fails (unknown class) — @${pr_author} triage needed. Failing: ${fail_summary}"

        if [[ -x "$BROADCAST_SCRIPT" ]]; then
            bash "$BROADCAST_SCRIPT" \
                --urgency CRIT \
                --from "wizard-daemon-step3" \
                "$bcast_msg" 2>/dev/null || true
        else
            log "WARN: Step 3: broadcast-urgent.sh not found at $BROADCAST_SCRIPT"
        fi

        emit_action "step3" "PR#$pr_num" "urgent_inbox_broadcast" \
            "\"author\":\"$pr_author\",\"failing_checks\":\"$fail_summary\",\"wedge_class\":\"unknown\""
    fi
}

# ── Step 4: Pickable-gap dispatch ─────────────────────────────────────────────
#
# Query open P0/P1 gaps with no active lease + AC complete.
# Filter: skip gaps with wizard_skip:true in YAML notes.
# Rate-limited: at most MAX_PARALLEL concurrent dispatches (tracked by
#   .chump-locks/wizard-daemon-dispatch-state.json sliding window).
# For each eligible gap: spawn `chump --execute-gap <ID>` in background.
#
# Dispatch state JSON schema:
#   { "dispatches": [ { "gap_id": "X", "ts": "ISO8601", "pid": N } ] }
#
step4_dispatch_pickable_gaps() {
    log "Step 4: querying pickable gaps for dispatch..."

    if ! command -v "$CHUMP_BIN" >/dev/null 2>&1; then
        log "Step 4: chump binary not found — skipping dispatch"
        emit_action "step4" "fleet" "skip_no_chump_bin"
        return 0
    fi

    # Load current dispatch state (prune entries older than DISPATCH_WINDOW_S)
    local active_count=0
    local now_epoch; now_epoch="$(date -u +%s)"

    # Read + prune state
    local state_json='{"dispatches":[]}'
    if [[ -f "$DISPATCH_STATE" ]]; then
        state_json="$(cat "$DISPATCH_STATE" 2>/dev/null || echo '{"dispatches":[]}')"
    fi

    # Count still-active dispatches (within window, process still running)
    active_count="$(python3 - "$state_json" "$now_epoch" "$DISPATCH_WINDOW_S" <<'PY' 2>/dev/null || echo 0
import json, sys, os
try:
    state = json.loads(sys.argv[1])
    now = int(sys.argv[2])
    window = int(sys.argv[3])
except Exception:
    print(0); sys.exit(0)

active = []
for d in state.get("dispatches", []):
    try:
        import datetime
        ts_str = d.get("ts","")
        t = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
        epoch = int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
        if (now - epoch) > window:
            continue  # expired
        pid = d.get("pid", 0)
        # Check if process still alive
        if pid and pid > 0:
            try:
                os.kill(pid, 0)
                active.append(d)
            except OSError:
                pass  # process gone
        else:
            active.append(d)
    except Exception:
        pass

print(len(active))
PY
)"

    log "Step 4: active dispatches=$active_count max=$MAX_PARALLEL"

    if [[ "$active_count" -ge "$MAX_PARALLEL" ]]; then
        log "Step 4: at max parallel dispatches ($active_count/$MAX_PARALLEL) — rate limited"
        emit_ambient "wizard_dispatch_rate_limited" \
            "\"active_count\":$active_count,\"max_parallel\":$MAX_PARALLEL,\"source\":\"wizard_daemon\""
        emit_action "step4" "fleet" "dispatch_rate_limited" \
            "\"active_count\":$active_count,\"max_parallel\":$MAX_PARALLEL"
        return 0
    fi

    local slots_available=$(( MAX_PARALLEL - active_count ))
    log "Step 4: $slots_available dispatch slot(s) available"

    # Query pickable gaps: P0/P1 open, no deps blocking
    local gap_list=""
    gap_list="$("$CHUMP_BIN" gap list --status open --priority P0,P1 --json 2>/dev/null \
        | python3 -c "
import json,sys
try:
    gaps = json.load(sys.stdin)
    if not isinstance(gaps, list):
        gaps = gaps.get('gaps', gaps.get('items', []))
    for g in gaps:
        gid = g.get('id','')
        notes = g.get('notes','') or ''
        # Skip wizard_skip gaps
        if 'wizard_skip: true' in notes or 'wizard_skip:true' in notes:
            print(f'SKIP:{gid}')
            continue
        ac = g.get('acceptance_criteria','')
        if not ac or ac == 'TODO':
            continue
        print(gid)
except Exception as e:
    pass
" 2>/dev/null || true)"

    if [[ -z "$gap_list" ]]; then
        log "Step 4: no pickable P0/P1 gaps found"
        emit_action "step4" "fleet" "no_pickable_gaps"
        return 0
    fi

    local dispatched_count=0
    local new_dispatches=()

    while IFS= read -r gap_entry; do
        [[ -z "$gap_entry" ]] && continue

        # Handle wizard_skip gaps
        if [[ "$gap_entry" == SKIP:* ]]; then
            local skip_id="${gap_entry#SKIP:}"
            log "Step 4: gap $skip_id has wizard_skip:true — skipping"
            emit_ambient "wizard_gap_skipped" \
                "\"gap_id\":\"$skip_id\",\"reason\":\"wizard_skip_true\",\"source\":\"wizard_daemon\""
            emit_action "step4" "gap:$skip_id" "gap_skipped" \
                "\"reason\":\"wizard_skip_true\""
            continue
        fi

        local gap_id="$gap_entry"

        # Check preflight — is it actually pickable?
        if ! "$CHUMP_BIN" gap preflight "$gap_id" >/dev/null 2>&1; then
            log "Step 4: gap $gap_id failed preflight — skipping"
            emit_action "step4" "gap:$gap_id" "skip_preflight_failed"
            continue
        fi

        if [[ "$dispatched_count" -ge "$slots_available" ]]; then
            log "Step 4: filled all $slots_available slot(s) — stopping dispatch loop"
            break
        fi

        # Dispatch in background
        log "Step 4: dispatching gap $gap_id via chump --execute-gap (background)"
        "$CHUMP_BIN" --execute-gap "$gap_id" >/dev/null 2>&1 &
        local dispatch_pid=$!

        local dispatch_ts; dispatch_ts="$(ts)"
        new_dispatches+=("{\"gap_id\":\"$gap_id\",\"ts\":\"$dispatch_ts\",\"pid\":$dispatch_pid}")

        emit_ambient "wizard_dispatch_executed" \
            "\"gap_id\":\"$gap_id\",\"pid\":$dispatch_pid,\"source\":\"wizard_daemon\""
        emit_action "step4" "gap:$gap_id" "dispatch_executed" \
            "\"pid\":$dispatch_pid,\"active_before\":$active_count"

        dispatched_count=$(( dispatched_count + 1 ))

    done < <(printf '%s\n' "$gap_list")

    # Persist updated dispatch state
    if [[ "${#new_dispatches[@]}" -gt 0 ]]; then
        local new_entries
        new_entries="$(IFS=','; printf '%s' "${new_dispatches[*]}")"
        # Merge with existing non-expired entries and write
        python3 - "$state_json" "$now_epoch" "$DISPATCH_WINDOW_S" "$new_entries" <<'PY' > "$DISPATCH_STATE" 2>/dev/null || true
import json, sys, os, datetime

try:
    state   = json.loads(sys.argv[1])
    now     = int(sys.argv[2])
    window  = int(sys.argv[3])
    new_raw = sys.argv[4] if len(sys.argv) > 4 else "[]"
except Exception:
    print('{"dispatches":[]}'); sys.exit(0)

# Keep non-expired entries
kept = []
for d in state.get("dispatches", []):
    try:
        t = datetime.datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ")
        epoch = int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
        if (now - epoch) <= window:
            kept.append(d)
    except Exception:
        pass

# Parse new entries (passed as comma-separated JSON objects)
try:
    new_list = json.loads(f"[{new_raw}]")
    kept.extend(new_list)
except Exception:
    pass

print(json.dumps({"dispatches": kept}, indent=2))
PY
    fi

    log "Step 4: dispatched $dispatched_count gap(s) this cycle"
}

# ── Step 5: Post-merge cascade rebase ────────────────────────────────────────
#
# After a gap ships (gap_shipped event), check OTHER PRs that were BLOCKED
# on the same trunk-RED cluster. If their last_failure matches the just-
# resolved class, trigger `gh pr update-branch` to rebase them.
#
# Rate-limited: max CASCADE_RATE_LIMIT per cycle (mirrors recovery-queue 3/hr).
# Safety: only rebases PRs authored by ALLOWED_REBASE_AUTHOR (anti-fork-takeover).
#
step5_cascade_rebase() {
    log "Step 5: scanning for post-merge cascade rebase opportunities..."

    if [[ ! -f "$AMBIENT" ]]; then
        log "Step 5: ambient.jsonl not found — skipping"
        return 0
    fi

    # Find recent gap_shipped events (within STALL_LOOKBACK_S)
    local cutoff_epoch
    cutoff_epoch="$(date -u -v-"${STALL_LOOKBACK_S}"S +%s 2>/dev/null \
        || date -u -d "-${STALL_LOOKBACK_S} seconds" +%s 2>/dev/null \
        || echo "0")"

    local shipped_events
    shipped_events="$(grep -E '"kind":"gap_shipped"' "$AMBIENT" 2>/dev/null \
        | tail -50 || true)"

    if [[ -z "$shipped_events" ]]; then
        log "Step 5: no gap_shipped events in ambient — nothing to cascade"
        emit_action "step5" "fleet" "no_shipped_events"
        return 0
    fi

    # Filter to events within lookback window, extract cluster_id or failing_class
    local recent_ships
    recent_ships="$(python3 - "$shipped_events" "$cutoff_epoch" <<'PY' 2>/dev/null || true
import json, sys, datetime

raw_lines = sys.argv[1].strip().split('\n')
try:
    cutoff = int(sys.argv[2])
except Exception:
    cutoff = 0

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
        t = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
        epoch = int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        epoch = 0
    if epoch >= cutoff:
        # Emit: cluster_id (or wedge_class) that this ship resolves
        cluster_id = d.get("cluster_id","") or d.get("wedge_class","") or d.get("gap_id","")
        print(cluster_id)
PY
)"

    if [[ -z "$recent_ships" ]]; then
        log "Step 5: no recent gap_shipped events within lookback window"
        emit_action "step5" "fleet" "no_recent_ships"
        return 0
    fi

    # For each resolved cluster, find BEHIND PRs that share the same failure class
    # and are authored by ALLOWED_REBASE_AUTHOR
    local open_prs=""
    if [[ "$_CACHE_AVAILABLE" == "1" ]]; then
        open_prs="$(cache_query_open_prs 2>/dev/null | awk -F'\t' '{print $1}' || true)"
    fi
    if [[ -z "$open_prs" ]]; then
        open_prs="$(CHUMP_GH_CALL_CRITICALITY=background \
            "$GH" pr list --state open --json number \
            --jq '.[].number' 2>/dev/null || true)"
    fi

    if [[ -z "$open_prs" ]]; then
        log "Step 5: no open PRs to cascade-rebase"
        return 0
    fi

    local rebased_count=0

    while IFS= read -r pr_num; do
        [[ -z "$pr_num" ]] && continue
        [[ "$_CASCADE_REBASES_THIS_RUN" -ge "$CASCADE_RATE_LIMIT" ]] && break

        # Fetch PR state to check: BEHIND + authored by allowed author
        local pr_json_c=""
        if [[ "$_CACHE_AVAILABLE" == "1" ]]; then
            pr_json_c="$(cache_lookup_pr "$pr_num" --max-age-s 120 2>/dev/null || true)"
        fi
        if [[ -z "$pr_json_c" ]]; then
            pr_json_c="$(CHUMP_GH_CALL_CRITICALITY=background \
                "$GH" pr view "$pr_num" \
                --json number,mergeStateStatus,headRefName,author \
                2>/dev/null || true)"
        fi
        [[ -z "$pr_json_c" ]] && continue

        # Extract merge state and author
        local pr_fields
        pr_fields="$(python3 - "$pr_json_c" <<'PY' 2>/dev/null || echo "ERROR||"
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("ERROR||"); sys.exit(0)
merge_state = d.get("mergeStateStatus","") or ""
author_obj  = d.get("author", {}) or {}
author      = author_obj.get("login","") if isinstance(author_obj, dict) else ""
head_ref    = d.get("headRefName","") or ""
print(f"{merge_state}|{author}|{head_ref}")
PY
)"

        [[ "$pr_fields" == "ERROR"* ]] && continue
        IFS='|' read -r pr_merge_state pr_author pr_head_ref <<<"$pr_fields"

        # Safety: only rebase PRs from the allowed author (anti-fork-takeover)
        if [[ "$pr_author" != "$ALLOWED_REBASE_AUTHOR" ]]; then
            log "Step 5: PR #$pr_num author=$pr_author not in allowed list ($ALLOWED_REBASE_AUTHOR) — skipping cascade rebase"
            emit_action "step5" "PR#$pr_num" "skip_author_not_allowed" \
                "\"author\":\"$pr_author\",\"allowed\":\"$ALLOWED_REBASE_AUTHOR\""
            continue
        fi

        # Only rebase PRs that are BEHIND (need rebase, not real conflicts)
        if [[ "$pr_merge_state" != "BEHIND" ]]; then
            continue
        fi

        log "Step 5: cascade-rebasing PR #$pr_num (author=$pr_author, head=$pr_head_ref)"

        # Trigger rebase via gh pr update-branch
        if "$GH" pr update-branch "$pr_num" 2>/dev/null; then
            _CASCADE_REBASES_THIS_RUN=$(( _CASCADE_REBASES_THIS_RUN + 1 ))
            rebased_count=$(( rebased_count + 1 ))
            emit_ambient "wizard_cascade_rebase_triggered" \
                "\"pr_number\":$pr_num,\"author\":\"$pr_author\",\"head_ref\":\"$pr_head_ref\",\"source\":\"wizard_daemon\""
            emit_action "step5" "PR#$pr_num" "cascade_rebase_triggered" \
                "\"author\":\"$pr_author\",\"rebases_this_run\":$_CASCADE_REBASES_THIS_RUN"
        else
            log "Step 5: PR #$pr_num — gh pr update-branch failed (conflict or API error)"
            emit_action "step5" "PR#$pr_num" "cascade_rebase_failed" \
                "\"author\":\"$pr_author\",\"reason\":\"gh_update_branch_failed\""
        fi

    done < <(printf '%s\n' "$open_prs")

    log "Step 5: cascade-rebased $rebased_count PR(s) this cycle"
    emit_action "step5" "fleet" "cascade_cycle_done" \
        "\"rebased_count\":$rebased_count,\"rebases_this_run\":$_CASCADE_REBASES_THIS_RUN"
}

# ── Run the orchestration loop ────────────────────────────────────────────────

step1_classify_prs
step4_dispatch_pickable_gaps
step5_cascade_rebase
step6_broadcast_on_stall

log "wizard-daemon: Phase 1+2 cycle complete (recovery_emits=$_RECOVERY_EMITS_THIS_RUN cascade_rebases=$_CASCADE_REBASES_THIS_RUN)"
emit_ambient "wizard_daemon_action" \
    "\"step\":\"cycle_complete\",\"target\":\"fleet\",\"decision\":\"done\",\"recovery_emits_this_run\":$_RECOVERY_EMITS_THIS_RUN,\"cascade_rebases_this_run\":$_CASCADE_REBASES_THIS_RUN,\"rate_limit_state\":\"limit=${RECOVERY_RATE_LIMIT}\""

exit 0
