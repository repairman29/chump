#!/usr/bin/env bash
# scripts/coord/target-loop.sh — curator-opus-target role CLI (harness-neutral)
#
# Productizes the curator-opus-target role per META-171 (Phase 1.5 reactor).
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way.
#
# Role: demo-target loop + META-074 children + INFRA-1318 Liaison Phase 2.
# Phase 1.5 reactor: votes on incoming proposals based on pillar-alignment
# with active demo-target bottleneck pillar from docs/ROADMAP.md.
#
# Rust-First-Bypass: glue between bash + chump CLI + jq; <200 LOC at first
# commit; read-only beyond ambient.jsonl appends (already append-idempotent).
#
# Usage:
#   scripts/coord/target-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick                 One work-your-lane cycle: Phase 0 inbox-drain +
#                        Phase 1.5 reactor (if CHUMP_FLEET_WIRE_V1=1) +
#                        Phase 1 work. Exit 0 if actionable, 1 if quiet.
#   heartbeat            Emit kind=target_heartbeat to ambient.jsonl.
#                        Exit 0 always.
#   help                 Print this help.
#
# Exit codes:
#   0 — actionable (tick: fresh inbox/reactor work; heartbeat: ok)
#   1 — quiet (tick: no actionable items)
#   2 — bad subcommand
#
# Env:
#   CHUMP_SESSION_ID       session id for ambient emits (default: target-<pid>)
#   CHUMP_AMBIENT_LOG      ambient.jsonl path override
#   CHUMP_FLEET_WIRE_V1    enable Phase 1.5 reactor (default: 0 / feature flag)
#   CHUMP_LOCK_DIR         override lock dir (tests)

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
SESSION_ID="${CHUMP_SESSION_ID:-target-$$}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Emit helper ───────────────────────────────────────────────────────────────

_emit() {
    local kind="$1"; shift
    local extras=""
    for kv in "$@"; do extras="$extras, $kv"; done
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","session":"%s"%s}\n' \
        "$(_now_iso)" "$kind" "$SESSION_ID" "$extras" \
        >> "$AMBIENT" 2>/dev/null || true
}
# scanner-anchor: "kind":"target_heartbeat"
# scanner-anchor: "kind":"target_reactor_voted"

# ── Inbox helpers ─────────────────────────────────────────────────────────────

_peek_inbox() {
    local inbox_file="$LOCK_DIR/inbox/${SESSION_ID}.jsonl"
    if [[ -f "$inbox_file" ]]; then
        tail -5 "$inbox_file" 2>/dev/null || true
    fi
}

# ── Phase 1.5 reactor (CHUMP_FLEET_WIRE_V1=1) ────────────────────────────────
# Votes on incoming `kind=proposal` events based on pillar-alignment with the
# active demo-target bottleneck pillar from docs/ROADMAP.md.
# Cooldown: 2h per corr_id.
# Anti-reaction-loop: skip kind=vote, kind=consensus_result, own-session.

_run_reactor() {
    local inbox_file="$LOCK_DIR/inbox/${SESSION_ID}.jsonl"
    [[ -f "$inbox_file" ]] || return 0

    local cooldown_dir="$LOCK_DIR/target-vote-cooldown"
    mkdir -p "$cooldown_dir" 2>/dev/null || true
    local cooldown_s=7200   # 2h

    # Detect bottleneck pillar from ROADMAP.md (look for the most-recently
    # mentioned pillar prefix in the "today's bets" / "this week's bets" sections)
    local bottleneck_pillar="EFFECTIVE"
    local roadmap="$REPO_ROOT/docs/ROADMAP.md"
    if [[ -f "$roadmap" ]]; then
        # Grep for pillar-prefix uppercase words; weight by recency (first match wins)
        local raw
        raw="$(grep -ioE '\b(EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE)\b' "$roadmap" 2>/dev/null \
               | head -20 | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || true)"
        [[ -n "$raw" ]] && bottleneck_pillar="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
    fi

    local voted=0

    # Process proposals from inbox (last 50 lines to stay bounded)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse kind + corr_id + subject + broadcaster_session_id
        local kind corr_id subject broadcaster
        kind="$(printf '%s' "$line" | grep -oE '"kind":"[^"]*"' | head -1 | sed 's/"kind":"//;s/"//')"
        corr_id="$(printf '%s' "$line" | grep -oE '"corr_id":"[^"]*"' | head -1 | sed 's/"corr_id":"//;s/"//')"
        subject="$(printf '%s' "$line" | grep -oE '"subject":"[^"]*"' | head -1 | sed 's/"subject":"//;s/"//' || echo "")"
        broadcaster="$(printf '%s' "$line" | grep -oE '"session":"[^"]*"' | head -1 | sed 's/"session":"//;s/"//' || echo "")"

        # Anti-reaction-loop: only react to proposal kind
        [[ "$kind" != "proposal" ]] && continue

        # Anti-reaction-loop: skip own broadcasts
        [[ "$broadcaster" == "$SESSION_ID" ]] && continue

        # Anti-reaction-loop: skip if consensus_result already fired for this corr_id
        if grep -q "\"kind\":\"consensus_result\".*\"corr_id\":\"${corr_id}\"" "$AMBIENT" 2>/dev/null; then
            continue
        fi

        # Cooldown: skip if voted within 2h
        [[ -z "$corr_id" ]] && continue
        local cooldown_file="$cooldown_dir/$corr_id"
        if [[ -f "$cooldown_file" ]]; then
            local file_age
            file_age="$(($(date +%s) - $(stat -f %m "$cooldown_file" 2>/dev/null || stat -c %Y "$cooldown_file" 2>/dev/null || echo 0)))"
            [[ "$file_age" -lt "$cooldown_s" ]] && continue
        fi

        # Decision logic: +1 if proposal title prefix matches bottleneck pillar, else 0
        local vote=0
        local reason="no-pillar-match"
        local upper_subject
        upper_subject="$(printf '%s' "$subject" | tr '[:lower:]' '[:upper:]')"
        if printf '%s' "$upper_subject" | grep -qF "$bottleneck_pillar"; then
            vote=1
            reason="pillar-match:${bottleneck_pillar}"
        fi

        # Cast vote via chump if available; emit ambient event either way
        if command -v chump >/dev/null 2>&1 && [[ -n "$corr_id" ]]; then
            chump vote "$corr_id" "$vote" --reason "target-reactor: $reason" 2>/dev/null || true
        fi

        _emit "target_reactor_voted" \
            "\"corr_id\":\"${corr_id}\"" \
            "\"vote\":${vote}" \
            "\"reason\":\"${reason}\"" \
            "\"bottleneck_pillar\":\"${bottleneck_pillar}\""

        # Stamp cooldown
        touch "$cooldown_file" 2>/dev/null || true
        voted=$((voted + 1))

    done < <(tail -50 "$inbox_file" 2>/dev/null || true)

    return 0
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_tick() {
    local actionable=0
    echo "=== curator-opus-target tick @ $(_now_iso) ==="
    echo

    # Phase 0: Inbox drain
    echo "## Inbox (session=${SESSION_ID})"
    local inbox_items
    inbox_items="$(_peek_inbox)"
    if [[ -n "$inbox_items" ]]; then
        printf '%s\n' "$inbox_items"
        actionable=1
    else
        echo "  (no inbox items)"
    fi
    echo

    # Phase 1.5: Fleet Wire reactor (feature-flagged)
    if [[ "${CHUMP_FLEET_WIRE_V1:-0}" == "1" ]]; then
        echo "## Phase 1.5: target reactor (CHUMP_FLEET_WIRE_V1=1)"
        _run_reactor
        echo "  target reactor complete"
        echo
    fi

    # Phase 1: Work (demo-target loop, META-074, INFRA-1318)
    echo "## Phase 1: target work"
    echo "  (demo-target / META-074 / INFRA-1318 work occurs in operator session)"
    echo

    if (( actionable > 0 )); then
        echo "[target] tick: actionable items found"
        return 0
    fi
    echo "[target] tick: quiet — no actionable items"
    return 1
}

cmd_heartbeat() {
    _emit "target_heartbeat" '"role":"target"'
    printf 'target heartbeat: %s session=%s\n' "$(_now_iso)" "$SESSION_ID"
    return 0
}

cmd_help() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//' | head -40
    return 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

SUBCMD="${1:-help}"
shift || true

case "$SUBCMD" in
    tick)      cmd_tick "$@" ;;
    heartbeat) cmd_heartbeat "$@" ;;
    help|--help) cmd_help "$@" ;;
    *)
        printf 'Unknown subcommand: %s\nRun: %s help\n' "$SUBCMD" "$0" >&2
        exit 2
        ;;
esac
