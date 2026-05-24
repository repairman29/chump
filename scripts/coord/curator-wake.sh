#!/usr/bin/env bash
# scripts/coord/curator-wake.sh — INFRA-1908
#
# Generates paste-ready bootstrap text for waking a Chump curator session.
# Operator runs this once per curator Claude Code window, pastes the output,
# and the curator becomes self-tending via /loop.
#
# Why this exists: Claude Code sessions are event-driven. Without an active
# /loop OR new tool calls, they sit dormant — inbox messages from
# broadcast.sh never surface, and the curator misses wizard dispatches.
# INFRA-1860's PostToolUse inbox-poll only fires on tool calls, so a truly
# idle session never sees its inbox. This helper closes that bootstrap gap
# until INFRA-1880 (curator-launch auto-export) ships.
#
# Usage:
#   bash scripts/coord/curator-wake.sh                  # all 6 roles
#   bash scripts/coord/curator-wake.sh --role handoff   # one role
#   bash scripts/coord/curator-wake.sh --role handoff --copy  # + pbcopy
#
# Once paste lands in a curator window: curator reads inbox + starts /loop,
# becomes self-tending. Future cycles reach them via inbox-poll hook
# (INFRA-1860) without further operator intervention.

set -euo pipefail

ROLE=""
COPY=0
ALL=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) shift; ROLE="$1"; ALL=0; shift ;;
        --copy) COPY=1; shift ;;
        --all)  ALL=1; ROLE=""; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

DATE="$(date +%Y-%m-%d)"
ROLES=(target handoff ci-audit shepherd decompose md-links)

emit_template() {
    local role="$1"
    local sess="curator-opus-${role}-${DATE}"
    cat <<TEMPLATE
──────────── PASTE INTO curator-opus-${role} CLAUDE WINDOW ────────────

# 1. Export your session id so inbox-poll + claim attribution work
export CHUMP_SESSION_ID=${sess}

# 2. Read inbox NOW (wizard dispatches waiting)
bash scripts/coord/chump-inbox.sh read --since cursor

# 3. Start self-tending /loop (5min cadence)
/loop 5m work your lane — (1) read inbox via 'bash scripts/coord/chump-inbox.sh read --since cursor', (2) advance any active claim (rebase if DIRTY / retrigger if audit-cancel / ship if ready), (3) claim next-best from inbox OR from THE_PATH.md track matching your role, (4) dispatch Sonnet via Agent tool for any Rust/tests/>150 LOC work per docs/process/SUBAGENT_DISPATCH.md, (5) emit DONE to orchestrator-opus-${DATE} on each ship via 'bash scripts/coord/broadcast.sh --to orchestrator-opus-${DATE} DONE <gap-id> <commit-sha>'.

# 4. Ack alive
bash scripts/coord/broadcast.sh --to orchestrator-opus-${DATE} WARN "loop_started session=${sess}"

────────────────────────────────────────────────────────────────────────
TEMPLATE
}

# Validate role if specified
if [[ -n "$ROLE" ]]; then
    valid=0
    for r in "${ROLES[@]}"; do
        if [[ "$r" == "$ROLE" ]]; then valid=1; break; fi
    done
    if (( valid == 0 )); then
        echo "error: unknown role '$ROLE'. Valid: ${ROLES[*]}" >&2
        exit 2
    fi
fi

# Emit
if (( ALL )); then
    for r in "${ROLES[@]}"; do
        emit_template "$r"
        echo ""
    done
else
    emit_template "$ROLE"
    if (( COPY )) && command -v pbcopy >/dev/null 2>&1; then
        emit_template "$ROLE" | pbcopy
        echo ""
        echo "📋 copied to clipboard (paste into curator-opus-${ROLE} window)"
    fi
fi
