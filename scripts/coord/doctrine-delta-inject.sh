#!/usr/bin/env bash
# scripts/coord/doctrine-delta-inject.sh — META-292
#
# SessionStart hook: surfaces "doctrine changed since your last session" so
# an agent doesn't need to have re-read CLAUDE.md/AGENTS.md/docs/process/*
# in full to know what shipped. Wired alongside ambient-context-inject.sh +
# inbox-check-urgent.sh in .claude/settings.json → hooks.SessionStart.
#
# State: ~/.chump/session-last-doctrine-commit stores the last origin/main
# commit sha seen by ANY session on this machine (shared, not per-repo —
# doctrine is repo-wide). Updated on every SessionStart run (not on session
# end — session end may not fire on crash, per AC #4).
#
# Output: Claude Code SessionStart hook JSON —
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
#
# Directive-freshness sub-check (AC #3): if SessionStart context (piped on
# stdin as hook JSON, field .directive or .prompt) contains a file:line
# reference (e.g. "line 2927 in src/main.rs" or "src/main.rs:2927"), verify
# the file exists at origin/main HEAD and note whether it has changed since
# a plausible directive-authoring point — here approximated as "since the
# stored doctrine-commit watermark" (the best available reference point;
# we have no per-directive timestamp).
#
# Env:
#   CHUMP_DOCTRINE_DELTA_STATE   override state file path (tests)
#   CHUMP_DOCTRINE_DELTA_DISABLE=1  disable entirely (emits empty context)

set -uo pipefail

if [[ "${CHUMP_DOCTRINE_DELTA_DISABLE:-0}" == "1" ]]; then
    echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":""}}'
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_FILE="${CHUMP_DOCTRINE_DELTA_STATE:-$HOME/.chump/session-last-doctrine-commit}"
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

cd "$REPO_ROOT" || exit 0

git fetch origin main --quiet 2>/dev/null || true
HEAD_SHA="$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")"

DOCTRINE_PATHS=(CLAUDE.md AGENTS.md docs/process/*.md docs/MISSION.md)

BODY=""

if [[ -f "$STATE_FILE" ]]; then
    STORED_SHA="$(head -1 "$STATE_FILE" 2>/dev/null | xargs)"
    if [[ -n "$STORED_SHA" && -n "$HEAD_SHA" && "$STORED_SHA" != "$HEAD_SHA" ]] \
        && git cat-file -e "$STORED_SHA" 2>/dev/null; then
        LOG_OUT="$(git log --pretty=format:'%h %s' --name-only \
            "$STORED_SHA..$HEAD_SHA" -- "${DOCTRINE_PATHS[@]}" 2>/dev/null)"
        if [[ -n "$LOG_OUT" ]]; then
            BODY="Doctrine changes since your last session:
${LOG_OUT}"
        fi
    fi
fi

# ── AC #3: operator-directive freshness sub-check ──────────────────────────
# Look for file:line references in the SessionStart hook's stdin payload
# (field .directive, falling back to whole payload text).
STDIN_PAYLOAD=""
if [[ ! -t 0 ]]; then
    STDIN_PAYLOAD="$(cat 2>/dev/null || true)"
fi

if [[ -n "$STDIN_PAYLOAD" ]]; then
    DIRECTIVE_TEXT="$(printf '%s' "$STDIN_PAYLOAD" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    o = json.loads(raw)
except Exception:
    print(raw)
    sys.exit(0)
if isinstance(o, dict):
    print(o.get("directive") or o.get("prompt") or o.get("message") or "")
else:
    print(raw)
' 2>/dev/null)"

    if [[ -n "$DIRECTIVE_TEXT" ]]; then
        # Matches "line 2927 in src/main.rs" or "src/main.rs:2927"
        REFS="$(printf '%s' "$DIRECTIVE_TEXT" | grep -oE '([A-Za-z0-9_./-]+\.[A-Za-z0-9]+):([0-9]+)|line [0-9]+ in [A-Za-z0-9_./-]+' 2>/dev/null || true)"
        if [[ -n "$REFS" ]]; then
            FRESHNESS_LINES=""
            while IFS= read -r ref; do
                [[ -z "$ref" ]] && continue
                if [[ "$ref" == line\ *\ in\ * ]]; then
                    LINE_NUM="$(printf '%s' "$ref" | sed -E 's/line ([0-9]+) in .*/\1/')"
                    FPATH="$(printf '%s' "$ref" | sed -E 's/line [0-9]+ in (.*)/\1/')"
                else
                    FPATH="${ref%%:*}"
                    LINE_NUM="${ref##*:}"
                fi
                [[ -z "$FPATH" ]] && continue
                if ! git cat-file -e "origin/main:$FPATH" 2>/dev/null; then
                    FRESHNESS_LINES="${FRESHNESS_LINES}⚠ ${FPATH} does not exist at origin/main HEAD — directive may be stale (referenced line ${LINE_NUM})
"
                    continue
                fi
                if [[ -f "$STATE_FILE" ]]; then
                    STORED_SHA="$(head -1 "$STATE_FILE" 2>/dev/null | xargs)"
                    if [[ -n "$STORED_SHA" ]] && git cat-file -e "$STORED_SHA" 2>/dev/null; then
                        CHANGED_SINCE="$(git log --oneline "$STORED_SHA..origin/main" -- "$FPATH" 2>/dev/null)"
                        if [[ -n "$CHANGED_SINCE" ]]; then
                            SHIFT_N="$(git diff --shortstat "$STORED_SHA..origin/main" -- "$FPATH" 2>/dev/null | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "")"
                            FRESHNESS_LINES="${FRESHNESS_LINES}⚠ ${FPATH} has been modified since this directive — line numbers may have shifted${SHIFT_N:+ (~${SHIFT_N} lines)}
"
                        else
                            FRESHNESS_LINES="${FRESHNESS_LINES}✓ ${FPATH} verified at HEAD
"
                        fi
                    else
                        FRESHNESS_LINES="${FRESHNESS_LINES}✓ ${FPATH} verified at HEAD
"
                    fi
                else
                    FRESHNESS_LINES="${FRESHNESS_LINES}✓ ${FPATH} verified at HEAD
"
                fi
            done <<< "$REFS"

            if [[ -n "$FRESHNESS_LINES" ]]; then
                if [[ -n "$BODY" ]]; then
                    BODY="${BODY}

Directive freshness:
${FRESHNESS_LINES}"
                else
                    BODY="Directive freshness:
${FRESHNESS_LINES}"
                fi
            fi
        fi
    fi
fi

# ── AC #4: update watermark on every SessionStart (not session end) ────────
if [[ -n "$HEAD_SHA" ]]; then
    printf '%s\n' "$HEAD_SHA" > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null || true
fi

if [[ -z "$BODY" ]]; then
    echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":""}}'
    exit 0
fi

python3 -c '
import json, sys
body = sys.stdin.read()
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": body}}))
' <<< "$BODY"

exit 0
