#!/usr/bin/env bash
# scripts/coord/queue-tender-loop.sh — Chump curator-opus-queue-tender role CLI (harness-neutral)
#
# Productizes the queue-tender daemon per META-243.
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way. The .claude/agents/curator-opus-queue-tender.md and
# .claude/skills/queue-tender/SKILL.md wrappers delegate here; they are
# convenience, not capability.
#
# Origin: 2026-05-30 an Opus orchestrator ran a 5-min CronCreate loop that
# snapshot open PR count, fired gh pr update-branch in parallel on DIRTY PRs,
# verified daemon liveness, and checked trunk. The queue stabilized at 34 PRs
# with 11 ships/hr sustained. This script makes that behavior a permanent
# fleet capability instead of a session-only cron that dies when Claude exits.
#
# Lane boundary (HARD, NOT BYPASSABLE):
#   DO NOT: gh pr merge --admin
#   DO NOT: dispatch Agent() subagents
#   DO NOT: gh pr close
#   DO NOT: chump gap reserve
#   DO NOT: touch ci.yml or any source code (read-only on the repo)
#   DO:     snapshot open PRs + fire gh pr update-branch + emit
#
# Rust-First-Bypass: glue between gh + jq + scripts/coord helpers; <250 LOC at
# first commit; read-mostly (only writes are .chump-locks/queue-tender-state.json
# + ambient.jsonl emit lines, both append-idempotent). Will be ported to Rust
# if the surface grows past the shell-OK criteria.
#
# Usage:
#   scripts/coord/queue-tender-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick         One full snapshot+rebase+emit cycle. Exit 0 on success,
#                exit 1 on queue-drained (no open PRs), exit 2 on bad input.
#   heartbeat    Emit kind=queue_tender_heartbeat to ambient.jsonl. Exit 0.
#   help         Print this help.
#
# Exit codes:
#   0 — success (tick fired or heartbeat emitted)
#   1 — queue drained (no open PRs; daemon can sleep)
#   2 — bad subcommand or missing required arg
#
# Env:
#   CHUMP_SESSION_ID                     session id for ambient emits (default: queue-tender-<pid>)
#   CHUMP_AMBIENT_LOG                    ambient.jsonl path override
#   CHUMP_QUEUE_TENDER_CADENCE_SEC       cadence used by launchd plist comment (default 300)
#   CHUMP_QUEUE_TENDER_PARALLEL_REBASE   max parallel gh pr update-branch (default 20)
#   CHUMP_QUEUE_TENDER_REBASE_HYSTERESIS_SEC  min seconds between rebases on same PR (default 300)
#   CHUMP_SKIP_QUEUE_TENDER              set to 1 to skip all work (kill-switch)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-queue-tender-$$}"
STATE_FILE="$LOCK_DIR/queue-tender-state.json"
PARALLEL_REBASE="${CHUMP_QUEUE_TENDER_PARALLEL_REBASE:-20}"
HYSTERESIS_SEC="${CHUMP_QUEUE_TENDER_REBASE_HYSTERESIS_SEC:-300}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date -u +%s; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Emit to ambient.jsonl. Each call site has a scanner-anchor comment.
_emit() {
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

# Read state file, return field value. Defaults to 0 if missing.
_state_get() {
    local field="$1"
    local default="${2:-0}"
    if [[ -f "$STATE_FILE" ]]; then
        # Use grep+sed rather than jq to avoid hard dependency.
        local val
        val="$(grep -oE "\"${field}\":[^,}]+" "$STATE_FILE" 2>/dev/null \
            | head -1 | sed 's/.*://; s/[^0-9]//g')" || true
        printf '%s' "${val:-$default}"
    else
        printf '%s' "$default"
    fi
}

# Write a JSON state file with updated fields.
_state_write() {
    local tick_count="$1"
    local last_baseline_open="$2"
    local ships_since_baseline="$3"
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    # Preserve last_rebase_at map from prior state if present.
    local prior_rebase_map="{}"
    if [[ -f "$STATE_FILE" ]]; then
        # Extract "last_rebase_at" object — crude but no jq required.
        prior_rebase_map="$(grep -oE '"last_rebase_at":\{[^}]*\}' "$STATE_FILE" 2>/dev/null \
            | sed 's/"last_rebase_at"://' || true)"
        [[ -z "$prior_rebase_map" ]] && prior_rebase_map="{}"
    fi
    printf '{"tick_count":%d,"last_baseline_open":%d,"ships_since_baseline":%d,"last_rebase_at":%s,"updated_at":"%s"}\n' \
        "$tick_count" "$last_baseline_open" "$ships_since_baseline" \
        "$prior_rebase_map" "$(_now_iso)" \
        > "$STATE_FILE" 2>/dev/null || true
}

# Record that PR $1 was rebased at epoch $2.
_state_record_rebase() {
    local pr="$1"
    local epoch="$2"
    if [[ ! -f "$STATE_FILE" ]]; then
        mkdir -p "$LOCK_DIR" 2>/dev/null || true
        printf '{"tick_count":0,"last_baseline_open":0,"ships_since_baseline":0,"last_rebase_at":{"%d":%d},"updated_at":"%s"}\n' \
            "$pr" "$epoch" "$(_now_iso)" > "$STATE_FILE" 2>/dev/null || true
        return
    fi
    # Inject or update "PR_NUM":EPOCH into the last_rebase_at object.
    # Strategy: sed replace inside the object if key exists, else append before }.
    local key="\"${pr}\""
    if grep -q "\"last_rebase_at\":" "$STATE_FILE" 2>/dev/null; then
        # If key already present, update value.
        if grep -oE "\"last_rebase_at\":\{[^}]*\"${pr}\":[0-9]+" "$STATE_FILE" >/dev/null 2>&1; then
            sed -i.bak "s/\"${pr}\":[0-9]*/\"${pr}\":${epoch}/g" "$STATE_FILE" 2>/dev/null || true
            rm -f "${STATE_FILE}.bak" 2>/dev/null || true
        else
            # Append key before the closing } of last_rebase_at.
            sed -i.bak "s/\"last_rebase_at\":{/\"last_rebase_at\":{${key}:${epoch},/g" \
                "$STATE_FILE" 2>/dev/null || true
            # Clean up double comma from empty map edge case.
            sed -i.bak 's/{,/{/g' "$STATE_FILE" 2>/dev/null || true
            rm -f "${STATE_FILE}.bak" 2>/dev/null || true
        fi
    fi
}

# Return 0 if PR $1 was last rebased within HYSTERESIS_SEC (skip), 1 if OK to rebase.
_hysteresis_check() {
    local pr="$1"
    local now
    now="$(_now_epoch)"
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1  # no state → OK to rebase
    fi
    local last_epoch
    last_epoch="$(grep -oE "\"${pr}\":[0-9]+" "$STATE_FILE" 2>/dev/null \
        | head -1 | sed 's/.*://')" || true
    [[ -z "$last_epoch" ]] && return 1  # no record → OK to rebase
    local age=$(( now - last_epoch ))
    if (( age < HYSTERESIS_SEC )); then
        return 0  # within window → skip
    fi
    return 1  # past window → OK to rebase
}

# Check whether daemon label $1 is listed in launchctl list output.
_daemon_alive() {
    local label="$1"
    launchctl list 2>/dev/null | grep -q "$label" && return 0 || return 1
}

# ── Subcommands ───────────────────────────────────────────────────────────────

_cmd_tick() {
    # Kill-switch: CHUMP_SKIP_QUEUE_TENDER=1 → exit immediately, no work.
    if [[ "${CHUMP_SKIP_QUEUE_TENDER:-0}" == "1" ]]; then
        echo "[queue-tender] CHUMP_SKIP_QUEUE_TENDER=1 — skipping all work"
        return 0
    fi

    echo "=== curator-opus-queue-tender tick @ $(_now_iso) ==="
    echo

    # ── Phase 1: PR snapshot ──────────────────────────────────────────────────
    echo "## PR snapshot"
    local pr_json=""
    pr_json="$(gh pr list --state open --limit 200 --json number,title,mergeStateStatus 2>/dev/null || true)"
    if [[ -z "$pr_json" || "$pr_json" == "[]" ]]; then
        echo "  open: 0 (queue drained)"
        # scanner-anchor: "kind":"queue_tender_queue_drained"
        _emit "queue_tender_queue_drained"
        return 1
    fi

    # Count states. mergeStateStatus values: BLOCKED, DIRTY, BEHIND, MERGEABLE, UNKNOWN.
    local open_count blocked_count dirty_count behind_count mergeable_count
    open_count="$(printf '%s\n' "$pr_json" | grep -o '"number"' | wc -l | tr -d ' ')"
    blocked_count="$(printf '%s\n' "$pr_json" | grep -o '"mergeStateStatus":"BLOCKED"' | wc -l | tr -d ' ')"
    dirty_count="$(printf '%s\n' "$pr_json" | grep -o '"mergeStateStatus":"DIRTY"' | wc -l | tr -d ' ')"
    behind_count="$(printf '%s\n' "$pr_json" | grep -o '"mergeStateStatus":"BEHIND"' | wc -l | tr -d ' ')"
    mergeable_count="$(printf '%s\n' "$pr_json" | grep -o '"mergeStateStatus":"MERGEABLE"' | wc -l | tr -d ' ')"

    echo "  open=${open_count} blocked=${blocked_count} dirty=${dirty_count} behind=${behind_count} mergeable=${mergeable_count}"
    echo

    # ── Phase 2: Rebase DIRTY PRs in parallel ─────────────────────────────────
    echo "## Rebase DIRTY PRs (parallel cap: ${PARALLEL_REBASE})"
    # Extract DIRTY PR numbers.
    local dirty_prs=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        dirty_prs+=("$line")
    done < <(printf '%s\n' "$pr_json" \
        | grep -B2 '"mergeStateStatus":"DIRTY"' \
        | grep '"number"' \
        | sed 's/.*"number": *\([0-9]*\).*/\1/' || true)

    local rebased=0
    local skipped_hysteresis=0
    local rebase_failed=0
    local rebase_prs_done=()

    if (( ${#dirty_prs[@]} == 0 )); then
        echo "  (no DIRTY PRs to rebase)"
    else
        # Filter through hysteresis before spawning parallel jobs.
        local eligible_prs=()
        local pr
        for pr in "${dirty_prs[@]}"; do
            if _hysteresis_check "$pr"; then
                skipped_hysteresis=$(( skipped_hysteresis + 1 ))
                echo "  PR #${pr}: skipping (rebased within last ${HYSTERESIS_SEC}s)"
            else
                eligible_prs+=("$pr")
            fi
        done

        if (( ${#eligible_prs[@]} > 0 )); then
            # Run gh pr update-branch in parallel. Capture results.
            local tmp_results
            tmp_results="$(mktemp)"
            # Note: xargs with PARALLEL_REBASE parallelism.
            printf '%s\n' "${eligible_prs[@]}" \
                | xargs -P "${PARALLEL_REBASE}" -I{} bash -c \
                    "if gh pr update-branch {} --rebase 2>/dev/null; then echo \"OK {}\"; else echo \"FAIL {}\"; fi" \
                >> "$tmp_results" 2>/dev/null || true

            while IFS= read -r result_line; do
                [[ -z "$result_line" ]] && continue
                local outcome pr_num
                outcome="$(printf '%s' "$result_line" | cut -d' ' -f1)"
                pr_num="$(printf '%s' "$result_line" | cut -d' ' -f2)"
                if [[ "$outcome" == "OK" ]]; then
                    rebased=$(( rebased + 1 ))
                    rebase_prs_done+=("$pr_num")
                    _state_record_rebase "$pr_num" "$(_now_epoch)"
                    echo "  PR #${pr_num}: rebased OK"
                else
                    rebase_failed=$(( rebase_failed + 1 ))
                    echo "  PR #${pr_num}: rebase FAILED (gh pr update-branch returned non-zero)"
                fi
            done < "$tmp_results"
            rm -f "$tmp_results"
        fi
    fi

    local action_taken="rebase:${rebased} skip_hysteresis:${skipped_hysteresis} fail:${rebase_failed}"
    echo
    echo "  result: ${action_taken}"
    echo

    # ── Phase 3: Daemon liveness ───────────────────────────────────────────────
    echo "## Daemon liveness"
    local daemons_alive=0
    local daemons_dead=()
    local daemon_labels=(
        "com.chump.stale-pr-rebase-bot"
        "com.chump.integrator-daemon"
        "com.chump.trunk-red-detector"
        "com.chump.flake-detector"
    )
    for label in "${daemon_labels[@]}"; do
        if _daemon_alive "$label"; then
            daemons_alive=$(( daemons_alive + 1 ))
            echo "  ${label}: alive"
        else
            daemons_dead+=("$label")
            echo "  ${label}: DEAD (not in launchctl list)"
        fi
    done
    local daemons_alive_str="${daemons_alive}/${#daemon_labels[@]}"
    echo

    # ── Phase 4: Trunk check ─────────────────────────────────────────────────
    echo "## Trunk check (main branch CI)"
    local trunk_conclusion="unknown"
    local trunk_json=""
    trunk_json="$(gh run list --branch main --workflow ci.yml --limit 1 \
        --json conclusion 2>/dev/null || true)"
    if [[ -n "$trunk_json" && "$trunk_json" != "[]" ]]; then
        trunk_conclusion="$(printf '%s\n' "$trunk_json" \
            | grep -oE '"conclusion":"[^"]*"' | head -1 \
            | sed 's/"conclusion":"//; s/"//')"
        [[ -z "$trunk_conclusion" ]] && trunk_conclusion="unknown"
    fi
    echo "  trunk ci.yml conclusion: ${trunk_conclusion}"
    if [[ "$trunk_conclusion" == "failure" ]]; then
        echo "  WARN: trunk RED — see ci-audit curator (this curator does not diagnose)"
        # scanner-anchor: "kind":"trunk_red_observed_by_queue_tender"
        _emit "trunk_red_observed_by_queue_tender" \
            "\"trunk_conclusion\":\"${trunk_conclusion}\",\"note\":\"ci-audit owns diagnosis\""
    fi
    echo

    # ── Phase 5: State counter + emit ────────────────────────────────────────
    local tick_count
    tick_count="$(_state_get tick_count 0)"
    tick_count=$(( tick_count + 1 ))
    local last_baseline_open
    last_baseline_open="$(_state_get last_baseline_open "${open_count}")"
    local ships_since_baseline
    ships_since_baseline=$(( last_baseline_open - open_count ))
    (( ships_since_baseline < 0 )) && ships_since_baseline=0
    _state_write "$tick_count" "$open_count" "$ships_since_baseline"

    # scanner-anchor: "kind":"queue_tend_tick"
    _emit "queue_tend_tick" \
        "\"open\":${open_count},\"blocked\":${blocked_count},\"dirty\":${dirty_count},\"behind\":${behind_count},\"ships_since_baseline\":${ships_since_baseline},\"action_taken\":\"${action_taken}\",\"daemons_alive\":\"${daemons_alive_str}\",\"trunk_conclusion\":\"${trunk_conclusion}\",\"tick_count\":${tick_count}"

    echo "=== tick ${tick_count} done — open=${open_count} rebased=${rebased} trunk=${trunk_conclusion} ==="
    return 0
}

_cmd_heartbeat() {
    # scanner-anchor: "kind":"queue_tender_heartbeat"
    _emit "queue_tender_heartbeat" "\"role\":\"queue-tender\""
    echo "[queue-tender] heartbeat emitted at $(_now_iso) for session $SESSION_ID"
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
        # INFRA-2262: inject ambient context before tick work.
        "$(dirname "$0")/ambient-context-inject.sh" --tick-preamble queue-tender 2>/dev/null || true
        _cmd_tick "$@"
        ;;
    heartbeat) _cmd_heartbeat "$@" ;;
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[queue-tender] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
