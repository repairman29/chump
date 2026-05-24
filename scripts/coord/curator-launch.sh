#!/usr/bin/env bash
# scripts/coord/curator-launch.sh — INFRA-1880
#
# Wrapper that launches a curator-opus session with CHUMP_SESSION_ID
# pre-exported. Closes the manual-paste workaround that curator-wake.sh
# (INFRA-1908) required: operator had to copy the `export CHUMP_SESSION_ID=...`
# line out of the wake template and paste it into the freshly-opened
# Claude window before any tool call could fire the inbox-poll hook
# (INFRA-1860) with the right session attribution.
#
# Now: `bash scripts/coord/curator-launch.sh <role>` exports the session
# id and execs claude in interactive mode. The hook sees the correct
# CHUMP_SESSION_ID from the first tool call.
#
# Pairs with:
#   - INFRA-1860 (PostToolUse inbox-poll)
#   - INFRA-1879 (5-path session-id derivation)
#   - INFRA-1908 (curator-wake bootstrap template, now mostly obsoleted by
#     META-097 .claude/agents/<role>.md subagent productization)
#
# Usage:
#   bash scripts/coord/curator-launch.sh <role>                 # interactive
#   bash scripts/coord/curator-launch.sh <role> -- -p "prompt"  # one-shot
#
# Valid roles: target / handoff / ci-audit / shepherd / decompose / md-links
#
# Bypass: CHUMP_SESSION_ID_AUTO=0 skips the auto-export (operator can
# set CHUMP_SESSION_ID manually before invoking).

set -euo pipefail

ROLES=(target handoff ci-audit shepherd decompose md-links)

if [[ $# -lt 1 ]]; then
    echo "usage: bash scripts/coord/curator-launch.sh <role> [-- claude-args...]" >&2
    echo "       roles: ${ROLES[*]}" >&2
    exit 2
fi

ROLE="$1"; shift

# Strip optional `--` separator
[[ "${1:-}" == "--" ]] && shift

# Validate role
valid=0
for r in "${ROLES[@]}"; do
    [[ "$r" == "$ROLE" ]] && valid=1 && break
done
if (( valid == 0 )); then
    echo "error: unknown role '$ROLE'. Valid: ${ROLES[*]}" >&2
    exit 2
fi

DATE="$(date +%Y-%m-%d)"
SESSION="curator-opus-${ROLE}-${DATE}"

# Auto-export unless bypass set
if [[ "${CHUMP_SESSION_ID_AUTO:-1}" == "1" ]]; then
    export CHUMP_SESSION_ID="$SESSION"
    echo "[curator-launch] CHUMP_SESSION_ID=$SESSION exported"
else
    echo "[curator-launch] CHUMP_SESSION_ID_AUTO=0 — not auto-exporting; using existing CHUMP_SESSION_ID=${CHUMP_SESSION_ID:-<unset>}"
fi

# Optionally print the wake-template hint so the operator sees the inbox-read +
# /loop incantation they would have pasted before INFRA-1880.
if [[ "${CHUMP_CURATOR_LAUNCH_PRINT_HINT:-1}" == "1" ]]; then
    cat <<HINT
[curator-launch] Once claude starts, paste:
  bash scripts/coord/chump-inbox.sh read --since cursor
  /loop 5m work your lane — read inbox, advance claim, pick next-best, dispatch Sonnet for code, emit DONE on ship
HINT
fi

# Exec claude with remaining args (so `-p` / file paths / etc. pass through)
if ! command -v claude >/dev/null 2>&1; then
    echo "error: claude CLI not found in PATH" >&2
    exit 1
fi

exec claude "$@"
