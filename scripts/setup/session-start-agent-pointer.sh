#!/usr/bin/env bash
# scripts/setup/session-start-agent-pointer.sh — META-1038 (META-286 slice)
#
# SessionStart hook: print a pointer to AGENT_START_HERE.md (the north-star doc)
# near the top of session output, so every agent sees it without being told.
# Wired FIRST in .claude/settings.json → hooks.SessionStart.
#
# Idempotent: the pointer is printed once per session. A marker under
# .chump-locks/ (keyed by CHUMP_SESSION_ID / CLAUDE_SESSION_ID) suppresses
# repeats when the hook re-fires (resume, compact, clear). With no session id the
# marker is "anon" and only suppresses repeats within AGENT_POINTER_TTL_MIN
# minutes (default 10), so a genuinely new session later still gets the pointer.
#
# Graceful: if AGENT_START_HERE.md does not exist (yet, or in a checkout that
# doesn't carry it) the hook prints nothing and exits 0. It never errors and
# never blocks startup.
#
# Doc lookup: $CHUMP_AGENT_START_HERE_DOC, else docs/AGENT_START_HERE.md, else
# ./AGENT_START_HERE.md under the repo root.
#
# Env: CHUMP_AGENT_POINTER_DISABLE=1 turns it off; CHUMP_REPO overrides the root.
set -uo pipefail

[[ "${CHUMP_AGENT_POINTER_DISABLE:-0}" == "1" ]] && exit 0

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ -z "$REPO_ROOT" ]] && exit 0

DOC=""
for cand in "${CHUMP_AGENT_START_HERE_DOC:-}" "$REPO_ROOT/docs/AGENT_START_HERE.md" "$REPO_ROOT/AGENT_START_HERE.md"; do
    if [[ -n "$cand" && -f "$cand" ]]; then DOC="$cand"; break; fi
done
[[ -z "$DOC" ]] && exit 0   # doc absent: degrade silently

REL="${DOC#"$REPO_ROOT"/}"

SESSION="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
KEY="$(printf '%s' "${SESSION:-anon}" | tr -c 'A-Za-z0-9._-' '_')"
MARKER_DIR="${CHUMP_LOCKS_DIR:-$REPO_ROOT/.chump-locks}"
MARKER="$MARKER_DIR/agent-start-here-$KEY.shown"
TTL_MIN="${AGENT_POINTER_TTL_MIN:-10}"

if [[ -f "$MARKER" ]]; then
    if [[ -n "$SESSION" ]]; then exit 0; fi
    # anon: only suppress if the marker is recent.
    if [[ -n "$(find "$MARKER" -mmin "-$TTL_MIN" 2>/dev/null)" ]]; then exit 0; fi
fi

mkdir -p "$MARKER_DIR" 2>/dev/null && : > "$MARKER" 2>/dev/null || true

printf '** START HERE: read %s — the north-star for this repo (what we are building and how agents work here). **\n' "$REL"
exit 0
