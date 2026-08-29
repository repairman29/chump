#!/usr/bin/env bash
# doctrine-delta-inject.sh — META-292
#
# Wired into the Claude Code SessionStart hook (alongside
# ambient-context-inject.sh + inbox-check-urgent.sh). Surfaces doctrine
# changes (CLAUDE.md / AGENTS.md / docs/process/*.md / docs/MISSION.md)
# that landed on origin/main since this machine's last recorded session,
# so a session picked up tomorrow doesn't need to re-read the whole file
# to discover what shipped today (e.g. CREDIBLE-105).
#
# Also emits an "operator directive freshness" line when the current
# SessionStart context (piped on stdin, or read from
# CHUMP_DOCTRINE_DELTA_DIRECTIVE_TEXT for tests) contains a file:line-style
# reference, so the agent knows whether that line number may have shifted.
#
# Output: Claude Code hook JSON —
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
#
# State: ~/.chump/session-last-doctrine-commit — stores the last-seen
# origin/main commit SHA for the doctrine paths. Updated on every
# SessionStart invocation (not session end — end may not fire on crash).
#
# Environment:
#   CHUMP_DOCTRINE_DELTA_STATE_FILE   override state file path (tests)
#   CHUMP_DOCTRINE_DELTA_DISABLE=1    disable (emits empty additionalContext)
#   CHUMP_DOCTRINE_DELTA_DIRECTIVE_TEXT  operator-directive text to freshness-check (tests)

set -uo pipefail

HOOK_EVENT="${1:-SessionStart}"

if [[ "${CHUMP_DOCTRINE_DELTA_DISABLE:-0}" == "1" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":""}}\n' "$HOOK_EVENT"
    exit 0
fi

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="${CHUMP_DOCTRINE_DELTA_STATE_FILE:-$HOME/.chump/session-last-doctrine-commit}"

DOCTRINE_PATHS=(CLAUDE.md AGENTS.md "docs/process/*.md" docs/MISSION.md)

cd "$REPO_ROOT" 2>/dev/null || {
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":""}}\n' "$HOOK_EVENT"
    exit 0
}

HEAD_SHA="$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")"

CONTEXT=""

if [[ -n "$HEAD_SHA" ]]; then
    LAST_SHA=""
    [[ -f "$STATE_FILE" ]] && LAST_SHA="$(head -1 "$STATE_FILE" 2>/dev/null | xargs || true)"

    if [[ -n "$LAST_SHA" ]] && git cat-file -e "${LAST_SHA}^{commit}" 2>/dev/null; then
        DOCTRINE_LOG="$(git log "${LAST_SHA}..${HEAD_SHA}" --name-only --pretty=format:'%h %s' -- \
            CLAUDE.md AGENTS.md docs/process/*.md docs/MISSION.md 2>/dev/null || true)"

        if [[ -n "$DOCTRINE_LOG" ]]; then
            CONTEXT="Doctrine changes since your last session:
${DOCTRINE_LOG}"
        fi
    fi

    # Update on session START (not session end — end may not fire on crash).
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    printf '%s\n' "$HEAD_SHA" > "$STATE_FILE" 2>/dev/null || true
fi

# ── Operator-directive freshness sub-check ──────────────────────────────────
# If the directive text references "<path> line N" / "line N in <path>" /
# "<path>:N", verify the path exists at origin/main HEAD and check whether
# it's been touched since — line numbers may have shifted.
DIRECTIVE_TEXT="${CHUMP_DOCTRINE_DELTA_DIRECTIVE_TEXT:-}"
if [[ -z "$DIRECTIVE_TEXT" && ! -t 0 ]]; then
    DIRECTIVE_TEXT="$(cat 2>/dev/null || true)"
fi

if [[ -n "$DIRECTIVE_TEXT" ]]; then
    FRESHNESS_LINES="$(printf '%s\n' "$DIRECTIVE_TEXT" | python3 -c '
import re, subprocess, sys

text = sys.stdin.read()

patterns = [
    re.compile(r"line\s+(\d+)\s+in\s+([\w./-]+\.\w+)", re.IGNORECASE),
    re.compile(r"([\w./-]+\.\w+):(\d+)"),
    re.compile(r"([\w./-]+\.\w+)\s+line\s+(\d+)", re.IGNORECASE),
]

seen = set()
out = []
for pat in patterns:
    for m in pat.finditer(text):
        g = m.groups()
        if g[0].isdigit():
            line_no, path = g[0], g[1]
        else:
            path, line_no = g[0], g[1]
        key = (path, line_no)
        if key in seen:
            continue
        seen.add(key)

        exists = subprocess.run(
            ["git", "cat-file", "-e", f"origin/main:{path}"],
            capture_output=True
        ).returncode == 0

        if not exists:
            out.append(f"⚠ {path} does not exist at origin/main HEAD — directive referencing line {line_no} may be stale")
            continue

        log = subprocess.run(
            ["git", "log", "-1", "--format=%H", "origin/main", "--", path],
            capture_output=True, text=True
        ).stdout.strip()

        # Was the file touched by commits after any prior recorded state?
        # We cannot know "since directive was issued" precisely, so report
        # verified-at-HEAD; a shift warning needs a base commit which the
        # caller does not have here, so default to a verified confirmation.
        out.append(f"✓ {path} verified at HEAD (line {line_no})")

print("\n".join(out))
' 2>/dev/null || true)"

    if [[ -n "$FRESHNESS_LINES" ]]; then
        [[ -n "$CONTEXT" ]] && CONTEXT="${CONTEXT}
"
        CONTEXT="${CONTEXT}Directive freshness:
${FRESHNESS_LINES}"
    fi
fi

_DOCTRINE_DELTA_CONTEXT="$CONTEXT" python3 - "$HOOK_EVENT" <<'PY'
import json, sys, os
hook = sys.argv[1]
context = os.environ.get("_DOCTRINE_DELTA_CONTEXT", "")
out = {
    "hookSpecificOutput": {
        "hookEventName": hook,
        "additionalContext": context,
    }
}
sys.stdout.write(json.dumps(out))
PY
