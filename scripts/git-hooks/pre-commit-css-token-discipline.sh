#!/usr/bin/env bash
# pre-commit-css-token-discipline.sh — INFRA-1590
#
# Thin wrapper that calls scripts/lint/css-token-discipline.sh for staged
# web/**/*.{js,html,css} files. Mirrors the pre-commit-rust-first.sh pattern
# (META-064) exactly: env-bypass, bypass-trailer, ambient audit emit.
#
# Bypass: add 'Token-Discipline-Bypass: <one-sentence reason>' to commit body.

set -uo pipefail


# Only fire when staged files include web/**/*.{js,html,css}
STAGED_WEB=$(git diff --cached --name-only 2>/dev/null | grep -E '^web/.*\.(js|html|css)$' || true)
if [[ -z "$STAGED_WEB" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="$REPO_ROOT/scripts/lint/css-token-discipline.sh"

if [[ ! -x "$LINT" ]]; then
    echo "[css-token-discipline] WARN: linter not found at $LINT, skipping." >&2
    exit 0
fi

# Run the linter (staged files only — default mode)
if bash "$LINT"; then
    exit 0
fi

# Linter found violations. Check for bypass trailer.
MSG_FILE="$(git rev-parse --git-common-dir)/COMMIT_EDITMSG"
if [[ -f "$MSG_FILE" ]] && grep -qE '^Token-Discipline-Bypass:' "$MSG_FILE" 2>/dev/null; then
    reason="$(grep -E '^Token-Discipline-Bypass:' "$MSG_FILE" | head -1 | sed 's/^Token-Discipline-Bypass:[[:space:]]*//')"

    AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        staged_files="$(echo "$STAGED_WEB" | tr '\n' ',' | sed 's/,$//')"
        commit_sha="$(git rev-parse --short HEAD 2>/dev/null || echo 'pre-commit')"
        reason_json="$(printf '%s' "$reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '"unparseable"')"
        printf '{"ts":"%s","kind":"token_discipline_bypass","commit_sha":"%s","reason":%s,"files":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$commit_sha" \
            "$reason_json" \
            "$staged_files" \
            >> "$AMBIENT" 2>/dev/null || true
    fi

    echo "[css-token-discipline] Bypassed: $reason" >&2
    exit 0
fi

# Block.
echo "" >&2
echo "To bypass: add 'Token-Discipline-Bypass: <one-sentence reason>' to commit body." >&2
echo "Full doc: docs/process/CSS_TOKEN_DISCIPLINE.md" >&2
exit 1
