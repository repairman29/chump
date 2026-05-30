#!/usr/bin/env bash
# scripts/coord/ci-audit-loop.sh — Chump curator-opus-ci-audit role CLI (harness-neutral)
#
# Productizes the curator-opus-ci-audit role per INFRA-1923 + META-097.
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way. The .claude/agents/ci-audit.md + .claude/skills/ci-audit/
# wrappers delegate here; they are convenience, not capability.
#
# This role owns CI and test-gate health for the Chump fleet. It was created
# to own the failure patterns that repeated across sessions:
#   - INFRA-1395: grace-window misuse (|| true silencing real failures)
#   - INFRA-1459: stale auto-merge (PR armed then rebased without re-arming)
#   - INFRA-1939: bot-merge silent wedge (PR merged, gap not shipped)
#   - Voice-lint drift (banned words slipping through without policy file)
#   - Bounced-PR trunk red (PR rebased into conflict, CI passed on stale SHA)
#
# Rust-First-Bypass: glue between gh + jq + git + scripts/coord helpers;
# <200 LOC at first commit; read-mostly (only writes are ambient.jsonl emit
# lines + inbox broadcasts, both already-idempotent). Will be ported to Rust
# if the surface grows past 200 LOC.
#
# Usage:
#   scripts/coord/ci-audit-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick          One full work-your-lane cycle: read inbox, check ambient
#                 for CI-relevant events, print actionable summary.
#                 Exit 0 if actionable, exit 1 if quiet, exit 2 on bad input.
#   audit         Decompose latest CI failure cluster: classify events in
#                 ambient.jsonl into flake / logic-bug / missing-gate buckets.
#                 Prints one line per finding. Exit 0 ok, exit 1 quiet.
#   heartbeat     Emit kind=ci_audit_heartbeat to ambient.jsonl. Exit 0 always.
#   help          Print this.
#
# Exit codes:
#   0 — success / actionable items found
#   1 — quiet (no actionable items)
#   2 — bad subcommand or missing required arg
#   3 — ambient log missing or unreadable
#
# Env:
#   CHUMP_SESSION_ID          session id for inbox + emits (default: ci-audit-<pid>)
#   CHUMP_AMBIENT_LOG         ambient.jsonl path override
#   CHUMP_CI_AUDIT_LANE_OVERRIDE  if "1", lane-scope checks skip
#   CHUMP_FLEET_WIRE_V1       set to "1" to enable Phase 1.5 reactor (META-169)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-ci-audit-$$}"

# Source cache helpers if available (INFRA-1081: cache-first reads).
_CACHE_LIB="$MAIN_REPO/scripts/coord/lib/github_cache.sh"
if [[ -f "$_CACHE_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_CACHE_LIB"
fi

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Emit an ambient line. Each call site has a scanner-anchor comment below.
_emit_kind() {
    local kind="$1"; shift
    local extra="${1:-}"
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    local body
    if [[ -n "$extra" ]]; then
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s",%s}' \
            "$(_now_iso)" "$kind" "$SESSION_ID" "$extra")"
    else
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s"}' \
            "$(_now_iso)" "$kind" "$SESSION_ID")"
    fi
    printf '%s\n' "$body" >> "$AMBIENT" 2>/dev/null || true
}

# Scan ambient.jsonl for CI-relevant events in the last N lines.
# Prints matching lines to stdout. Returns number of matches via exit code
# (0 = found something, 1 = nothing).
_scan_ambient_for_ci() {
    local window="${1:-100}"
    if [[ ! -f "$AMBIENT" ]]; then
        return 1
    fi
    local hits
    hits="$(tail -"${window}" "$AMBIENT" 2>/dev/null \
        | grep -E '"kind":"(pr_stuck|fleet_wedge|regression_attributed|ci_cluster_detected|ci_audit_heartbeat|sub_agent_dispatched)"' \
        || true)"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits"
        return 0
    fi
    return 1
}

# Read inbox items for this session (non-advancing peek).
_peek_inbox() {
    local inbox_file="$LOCK_DIR/inbox/${SESSION_ID}.jsonl"
    if [[ -f "$inbox_file" ]]; then
        tail -5 "$inbox_file" 2>/dev/null || true
    fi
}

# ── Phase 1.5 reactor helpers (META-169) ──────────────────────────────────────

# Drain all FEEDBACK kind=proposal messages from all inbox files owned by
# this session (primary + any lease-id inboxes). Returns one JSON line per
# message, deduped by message_id / ts+session+kind triple.
# Only called when CHUMP_FLEET_WIRE_V1=1.
_drain_inbox_proposals() {
    local seen_ids=()
    local inbox_dir="$LOCK_DIR/inbox"
    [[ -d "$inbox_dir" ]] || return 0

    # Collect candidate inbox files: primary SESSION_ID + any claim-*.json lease ids
    local files=()
    local primary="$inbox_dir/${SESSION_ID}.jsonl"
    [[ -f "$primary" ]] && files+=("$primary")

    local lease_file
    for lease_file in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lease_file" ]] || continue
        local lease_session
        lease_session="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$lease_file" 2>/dev/null | head -1)"
        [[ -z "$lease_session" || "$lease_session" == "$SESSION_ID" ]] && continue
        local lease_inbox="$inbox_dir/${lease_session}.jsonl"
        [[ -f "$lease_inbox" ]] && files+=("$lease_inbox")
    done

    local f line event kind msg_id dedup_key
    for f in "${files[@]}"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            event="$(printf '%s' "$line" | sed -n 's/.*"event"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
            [[ "$event" != "FEEDBACK" ]] && continue
            kind="$(printf '%s' "$line" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
            [[ "$kind" != "proposal" ]] && continue
            # Dedupe
            msg_id="$(printf '%s' "$line" | sed -n 's/.*"message_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
            if [[ -n "$msg_id" ]]; then
                dedup_key="$msg_id"
            else
                local ts session_f
                ts="$(printf '%s' "$line" | sed -n 's/.*"ts"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
                session_f="$(printf '%s' "$line" | sed -n 's/.*"session"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
                dedup_key="${ts}|${session_f}|${kind}"
            fi
            local already=0
            local id
            for id in "${seen_ids[@]:-}"; do
                [[ "$id" == "$dedup_key" ]] && already=1 && break
            done
            (( already )) && continue
            seen_ids+=("$dedup_key")
            printf '%s\n' "$line"
        done < "$f"
    done
}

# Check if a corr_id has already fired consensus_result in recent ambient.
_consensus_fired() {
    local corr_id="$1"
    [[ ! -f "$AMBIENT" ]] && return 1
    grep -q "\"kind\":\"consensus_result\".*\"corr_id\":\"${corr_id}\"" "$AMBIENT" 2>/dev/null \
        || grep -q "\"corr_id\":\"${corr_id}\".*\"kind\":\"consensus_result\"" "$AMBIENT" 2>/dev/null
}

# Return suspect_commits count from the most recent regression_attributed event
# in the last 200 ambient lines matching an optional corr_id filter.
# Outputs the integer count (0 if not found).
_regression_suspect_count() {
    local corr_id_filter="${1:-}"
    [[ ! -f "$AMBIENT" ]] && printf '0' && return 1
    local line candidates
    candidates="$(tail -200 "$AMBIENT" 2>/dev/null \
        | grep '"kind":"regression_attributed"' || true)"
    if [[ -z "$candidates" ]]; then
        printf '0'
        return 1
    fi
    # If corr_id filter provided, restrict to matching lines
    if [[ -n "$corr_id_filter" ]]; then
        local filtered
        filtered="$(printf '%s\n' "$candidates" \
            | grep "\"corr_id\":\"${corr_id_filter}\"" || true)"
        [[ -n "$filtered" ]] && candidates="$filtered"
    fi
    # Take the most recent line
    line="$(printf '%s\n' "$candidates" | tail -1)"
    # Extract suspect_commits (numeric field)
    local count
    count="$(printf '%s' "$line" \
        | sed -n 's/.*"suspect_commits"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        | head -1)"
    # Fallback: suspect_commits might be a string
    if [[ -z "$count" ]]; then
        count="$(printf '%s' "$line" \
            | sed -n 's/.*"suspect_commits"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' \
            | head -1)"
    fi
    printf '%s' "${count:-0}"
}

# Check if regression_attributed event exists in ambient for the given
# corr_id within the last 4 hours. Returns 0 if found, 1 if not.
# If corr_id is empty, checks for ANY regression_attributed in last 4h.
_regression_in_last_4h() {
    local corr_id_filter="${1:-}"
    [[ ! -f "$AMBIENT" ]] && return 1

    local now_epoch cutoff line_ts line_epoch
    now_epoch="$(date +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))')"
    cutoff=$(( now_epoch - 14400 ))  # 4h = 14400s

    local found=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" != *'"kind":"regression_attributed"'* ]] && continue
        if [[ -n "$corr_id_filter" ]]; then
            [[ "$line" != *"\"corr_id\":\"${corr_id_filter}\""* ]] && continue
        fi
        line_ts="$(printf '%s' "$line" | sed -n 's/.*"ts"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        [[ -z "$line_ts" ]] && continue
        line_epoch="$(date -d "$line_ts" +%s 2>/dev/null \
            || python3 -c "import datetime,calendar; t=datetime.datetime.strptime('${line_ts}','%Y-%m-%dT%H:%M:%SZ'); print(calendar.timegm(t.timetuple()))" 2>/dev/null \
            || echo 0)"
        if (( line_epoch >= cutoff )); then
            found=1
            break
        fi
    done < <(tail -200 "$AMBIENT" 2>/dev/null)

    return $(( 1 - found ))
}

# Emit a FEEDBACK kind=vote to ambient for the given corr_id + vote value.
# Also writes to the deliberator's inbox if available.
_cast_vote() {
    local corr_id="$1"
    local vote_val="$2"   # +1 or 0
    local reason="${3:-ci-audit: regression_attributed suspect_commits vote}"

    # Emit to ambient (deliberator reads from here)
    local extra
    extra="$(printf '"event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":%s,"reason":"%s","voter_role":"ci-audit"' \
        "$corr_id" "$vote_val" "$reason")"
    _emit_kind "ci_audit_reactor_voted" \
        "$(printf '"corr_id":"%s","vote":%s,"reason":"%s"' "$corr_id" "$vote_val" "$reason")"
    # scanner-anchor: "kind":"ci_audit_reactor_voted"

    # Write FEEDBACK vote line directly to ambient so deliberator can tally it
    local vote_body
    vote_body="$(printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","session":"%s","corr_id":"%s","vote":%s,"reason":"%s","voter_role":"ci-audit"}' \
        "$(_now_iso)" "$SESSION_ID" "$corr_id" "$vote_val" "$reason")"
    printf '%s\n' "$vote_body" >> "$AMBIENT" 2>/dev/null || true

    # Also broadcast to deliberator inbox if broadcast.sh available
    local broadcast_sh="$MAIN_REPO/scripts/coord/broadcast.sh"
    if [[ -x "$broadcast_sh" ]]; then
        local today
        today="$(date -u +%Y-%m-%d)"
        "$broadcast_sh" --to "curator-opus-deliberator-${today}" \
            FEEDBACK vote "ci-audit reactor: regression_attributed corr_id=${corr_id}" \
            "ci-audit voted ${vote_val} on ${corr_id}: ${reason}" \
            "$vote_val" >/dev/null 2>&1 || true
    fi
}

# ── Phase 1.5: FEEDBACK proposal reactor (META-169) ───────────────────────────
#
# Scans FEEDBACK kind=proposal messages from inbox.
# For each proposal whose description/rationale references "regression_attributed":
#   1. Verify a matching regression_attributed event exists in ambient (last 4h)
#   2. Get suspect_commits count from that event
#   3. Vote +1 (high confidence) if count >= 3; vote 0 (low confidence) if < 3
#   4. Skip if no ambient match (not our lane)
# Gated by CHUMP_FLEET_WIRE_V1=1.
# Returns 0 if any votes were cast, 1 if quiet.
_phase_1_5_reactor() {
    if [[ "${CHUMP_FLEET_WIRE_V1:-0}" != "1" ]]; then
        return 1  # Feature flag off — noop
    fi

    local voted=0
    local cooldown_dir="$LOCK_DIR/ci-audit-vote-cooldown"
    mkdir -p "$cooldown_dir" 2>/dev/null || true

    local proposal
    while IFS= read -r proposal; do
        [[ -z "$proposal" ]] && continue

        # ── Anti-reaction-loop guard (META-168 AC #3 pattern) ──────────────
        # Skip kind=vote events (only react to proposal/preference/defect/retro)
        local p_kind
        p_kind="$(printf '%s' "$proposal" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        [[ "$p_kind" == "vote" ]] && continue

        # Skip own-session broadcasts
        local p_session
        p_session="$(printf '%s' "$proposal" | sed -n 's/.*"session"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        [[ "$p_session" == "$SESSION_ID" ]] && continue

        # Extract corr_id
        local corr_id
        corr_id="$(printf '%s' "$proposal" | sed -n 's/.*"corr_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        [[ -z "$corr_id" ]] && continue

        # Skip if consensus_result already fired for this corr_id
        _consensus_fired "$corr_id" && continue

        # ── 30min per-corr_id cooldown ──────────────────────────────────────
        local cooldown_file="$cooldown_dir/${corr_id}"
        if [[ -f "$cooldown_file" ]]; then
            local file_mtime now_epoch age_s
            now_epoch="$(date +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))')"
            file_mtime="$(stat -f %m "$cooldown_file" 2>/dev/null \
                || stat -c %Y "$cooldown_file" 2>/dev/null \
                || echo 0)"
            age_s=$(( now_epoch - file_mtime ))
            (( age_s < 1800 )) && continue  # 30min = 1800s
        fi

        # ── Lane check: does this proposal reference regression_attributed? ──
        local subject rationale
        subject="$(printf '%s' "$proposal" | sed -n 's/.*"subject"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        rationale="$(printf '%s' "$proposal" | sed -n 's/.*"rationale"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        local combined="${subject} ${rationale}"
        if [[ "$combined" != *"regression_attributed"* ]]; then
            continue  # Not our lane — skip
        fi

        # ── Ambient cross-reference: regression_attributed event in last 4h ──
        if ! _regression_in_last_4h ""; then
            # No regression_attributed event in ambient — not our lane
            echo "  [phase1.5] corr_id=${corr_id}: no regression_attributed event in last 4h — skip"
            continue
        fi

        # ── Vote per suspect_commits count ─────────────────────────────────
        local suspect_count vote_val vote_reason
        suspect_count="$(_regression_suspect_count "")"
        if (( suspect_count >= 3 )); then
            vote_val=1
            vote_reason="ci-audit: high-confidence regression (suspect_commits=${suspect_count}>=3)"
        else
            vote_val=0
            vote_reason="ci-audit: low-confidence regression (suspect_commits=${suspect_count}<3)"
        fi

        echo "  [phase1.5] corr_id=${corr_id}: regression_attributed found, suspect_commits=${suspect_count} → vote=${vote_val}"
        _cast_vote "$corr_id" "$vote_val" "$vote_reason"

        # Stamp cooldown file
        touch "$cooldown_file" 2>/dev/null || true

        voted=$(( voted + 1 ))
    done < <(_drain_inbox_proposals)

    (( voted > 0 )) && return 0
    return 1
}

# ── Subcommands ──────────────────────────────────────────────────────────────

_cmd_tick() {
    local actionable=0
    echo "=== curator-opus-ci-audit tick @ $(_now_iso) ==="
    echo

    # Phase 1: Inbox check
    echo "## Inbox (last 5 items for session ${SESSION_ID})"
    local inbox_items
    inbox_items="$(_peek_inbox)"
    if [[ -n "$inbox_items" ]]; then
        printf '%s\n' "$inbox_items"
        actionable=1
    else
        echo "  (no inbox items)"
    fi
    echo

    # Phase 1.5: FEEDBACK proposal reactor (META-169, gated by CHUMP_FLEET_WIRE_V1=1)
    if [[ "${CHUMP_FLEET_WIRE_V1:-0}" == "1" ]]; then
        echo "## Phase 1.5: FEEDBACK reactor (CHUMP_FLEET_WIRE_V1)"
        if _phase_1_5_reactor; then
            echo "  [phase1.5] votes cast"
            actionable=1
        else
            echo "  [phase1.5] no regression_attributed proposals to vote on"
        fi
        echo
    fi

    # Phase 2: Ambient CI event scan
    echo "## Ambient CI events (last 100 lines)"
    local ci_events
    ci_events="$(_scan_ambient_for_ci 100 || true)"
    if [[ -n "$ci_events" ]]; then
        printf '%s\n' "$ci_events"
        echo
        echo "[ci-audit] CI-relevant events found — consider running: $0 audit"
        actionable=1
    else
        echo "  (no CI-relevant events in recent ambient)"
    fi
    echo

    # Phase 3: Active lease check — confirm we have the lock
    echo "## Active leases"
    local lease_count=0
    local lock
    for lock in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lock" ]] || continue
        lease_count=$((lease_count + 1))
    done
    echo "  ${lease_count} active lease(s) under $LOCK_DIR"
    echo

    if (( actionable > 0 )); then
        echo "[ci-audit] tick: actionable items found"
        return 0
    fi
    echo "[ci-audit] tick: quiet — no actionable items"
    return 1
}

_cmd_audit() {
    echo "=== curator-opus-ci-audit audit @ $(_now_iso) ==="
    echo

    if [[ ! -f "$AMBIENT" ]]; then
        echo "[ci-audit] ambient log not found at $AMBIENT" >&2
        echo "  Cannot audit CI cluster without ambient stream." >&2
        return 3
    fi

    local found=0

    # Scan for pr_stuck events → potential logic bug or stale auto-merge
    echo "## pr_stuck events (last 200 ambient lines)"
    local stuck_events
    stuck_events="$(tail -200 "$AMBIENT" 2>/dev/null \
        | grep '"kind":"pr_stuck"' || true)"
    if [[ -n "$stuck_events" ]]; then
        local stuck_count
        stuck_count="$(printf '%s\n' "$stuck_events" | wc -l | tr -d ' ')"
        echo "  BUCKET: stale-auto-merge candidate (${stuck_count} pr_stuck events)"
        echo "  → Cross-check with INFRA-1459 pattern: PR armed then rebased without re-arming"
        printf '%s\n' "$stuck_events" | tail -3
        found=1
    else
        echo "  (none)"
    fi
    echo

    # Scan for fleet_wedge events → bot-merge silent wedge
    echo "## fleet_wedge events (last 200 ambient lines)"
    local wedge_events
    wedge_events="$(tail -200 "$AMBIENT" 2>/dev/null \
        | grep '"kind":"fleet_wedge"' || true)"
    if [[ -n "$wedge_events" ]]; then
        local wedge_count
        wedge_count="$(printf '%s\n' "$wedge_events" | wc -l | tr -d ' ')"
        echo "  BUCKET: bot-merge silent wedge candidate (${wedge_count} fleet_wedge events)"
        echo "  → Cross-check with INFRA-1939 pattern: PR merged but gap not shipped"
        printf '%s\n' "$wedge_events" | tail -3
        found=1
    else
        echo "  (none)"
    fi
    echo

    # Scan for regression_attributed events → blame-bot fingered specific commits
    # CREDIBLE-079: missing bucket was masking trunk-red signal — curator
    # heartbeat without action (L1-SLO-1 silent_agent breach root cause).
    echo "## regression_attributed events (last 200 ambient lines)"
    local regr_events
    regr_events="$(tail -200 "$AMBIENT" 2>/dev/null \
        | grep '"kind":"regression_attributed"' || true)"
    if [[ -n "$regr_events" ]]; then
        local regr_count
        regr_count="$(printf '%s\n' "$regr_events" | wc -l | tr -d ' ')"
        echo "  BUCKET: blame-bot regression cluster (${regr_count} regression_attributed events)"
        echo "  → Cross-check with CREDIBLE-080: blame-bot may be firing against stale green_sha"
        # Surface suspect_commits + checks_attributed from the most recent event
        local latest_regr
        latest_regr="$(printf '%s\n' "$regr_events" | tail -1)"
        local suspects
        suspects="$(printf '%s' "$latest_regr" | sed -n 's/.*"suspect_commits":"\([^"]*\)".*/\1/p')"
        local checks
        checks="$(printf '%s' "$latest_regr" | sed -n 's/.*"checks_attributed":"\([^"]*\)".*/\1/p')"
        local green
        green="$(printf '%s' "$latest_regr" | sed -n 's/.*"green_sha":"\([^"]*\)".*/\1/p')"
        [[ -n "$suspects" ]] && echo "  suspect_commits: $suspects"
        [[ -n "$checks" ]] && echo "  checks_attributed: $checks"
        [[ -n "$green" ]] && echo "  green_sha: $green"
        # Stale-green hint: if green_sha is > 5 commits behind HEAD, warn
        if [[ -n "$green" ]]; then
            local behind
            behind="$(git -C "$REPO_ROOT" rev-list --count "${green}..HEAD" 2>/dev/null || echo 0)"
            if (( behind > 5 )); then
                echo "  ⚠ stale-green warning: green_sha is ${behind} commits behind HEAD — see CREDIBLE-080"
            fi
        fi
        printf '%s\n' "$regr_events" | tail -3
        found=1
    else
        echo "  (none)"
    fi
    echo

    # Emit cluster-detected if we found something
    if (( found > 0 )); then
        _emit_kind "ci_cluster_detected" "\"bucket_count\":${found}"
        # scanner-anchor: "kind":"ci_cluster_detected"
        echo "[ci-audit] audit complete — ${found} failure bucket(s) found"
        echo "  Next step: dispatch Sonnet on flake buckets, file follow-up gaps for logic bugs"
        return 0
    fi

    echo "[ci-audit] audit: quiet — no CI failure patterns detected in recent ambient"
    return 1
}

_cmd_heartbeat() {
    _emit_kind "ci_audit_heartbeat" "\"role\":\"ci-audit\""
    # scanner-anchor: "kind":"ci_audit_heartbeat"
    echo "[ci-audit] heartbeat emitted at $(_now_iso) for session $SESSION_ID"
    return 0
}

_cmd_help() {
    sed -n '1,/^set -euo pipefail$/p' "$0" | grep '^#' | sed 's/^# //; s/^#$//'
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
    tick)
        # INFRA-2262: read fleet wire before doing tick work.
        "$(dirname "$0")/ambient-context-inject.sh" --tick-preamble ci-audit 2>/dev/null || true
        _cmd_tick "$@"
        ;;
    audit)      _cmd_audit "$@" ;;
    heartbeat)  _cmd_heartbeat "$@" ;;
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[ci-audit] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
