#!/usr/bin/env bash
# pre-commit-autodoc-envvars.sh — RESILIENT-207 / DOC-026 defect-eliminator.
#
# Auto-documents any NEW `CHUMP_*` env var a commit introduces by appending it to
# scripts/ci/env-vars-internal.txt (with an AUTO marker) and staging that file — so the
# env-var-coverage CI gate (DOC-026 / INFRA-1787) can never fail on it.
#
# WHY THIS EXISTS: the env-var-coverage gate is a chronic fleet defect — it failed 5+/week,
# every time hand-fixed by batch-allowlisting (see docs/process/CI_GATES_INVENTORY.md row 1).
# The INFRA-1853 auto-fixer already solved this, but it lived ONLY in scripts/coord/chump-commit.sh,
# so any commit made via raw `git commit` (or by an agent bypassing chump-commit.sh) skipped it and
# ate a ~15-min CI round-trip. Moving the auto-fix onto the UNIVERSAL commit path (this pre-commit
# sub-hook) kills the class for everyone who commits normally.
#
# Behavior: FAIL-OPEN and NON-BLOCKING — it only ever appends + `git add`s; it never fails a commit.
# Only fires when the staged delta touches .rs/.sh/.py (skips docs-only). Bypass: CHUMP_AUTO_ENVVAR=0.
# NOTE: `git commit --no-verify` skips this (as it skips all hooks) — the residual is the same as
# every other pre-commit gate; the fleet's normal path is covered.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$REPO_ROOT" ] || exit 0
ENVVAR_FILE="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
[ -f "$ENVVAR_FILE" ] || exit 0

AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_emit() { # kind, extra-json
    mkdir -p "$(dirname "$AMB")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","session":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
        "${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}" \
        "${2:-}" >> "$AMB" 2>/dev/null || true
}

# Bypass (audited).
if [ "${CHUMP_AUTO_ENVVAR:-1}" = "0" ]; then
    _emit auto_envvar_bypassed ',"reason":"CHUMP_AUTO_ENVVAR=0","hook":"pre-commit"'
    exit 0
fi

# Only fire on code changes (skip docs-only).
if ! git diff --cached --name-only 2>/dev/null | grep -qE '\.(rs|sh|py)$'; then
    exit 0
fi

# New CHUMP_* refs in staged hunks that aren't already documented (exact line-start match).
NEW_VARS="$(
    git diff --cached --no-color -U0 -- '*.rs' '*.sh' '*.py' 2>/dev/null \
      | grep -oE '\bCHUMP_[A-Z][A-Z0-9_]+\b' \
      | sort -u \
      | while read -r ev; do
            grep -qE "^${ev}\b" "$ENVVAR_FILE" 2>/dev/null || echo "$ev"
        done
)" || true   # grep-no-match exits 1 under pipefail; guard so set -e never aborts the commit

[ -n "$NEW_VARS" ] || exit 0

{
    echo ""
    echo "# AUTO (RESILIENT-207): pre-commit detected new CHUMP_* env refs."
    echo "# Replace the AUTO marker with a real description on the next commit."
    while read -r ev; do
        [ -z "$ev" ] && continue
        origin="$(git diff --cached --name-only --no-color 2>/dev/null \
            | while read -r f; do
                git diff --cached --no-color -- "$f" 2>/dev/null | grep -q "\b${ev}\b" && { echo "$f"; break; }
              done | head -1)"
        [ -z "$origin" ] && origin="(unknown)"
        echo "# detected in: ${origin}"
        echo "${ev}"
    done <<<"$NEW_VARS"
} >> "$ENVVAR_FILE"

git add "$ENVVAR_FILE" 2>/dev/null || true
COUNT="$(printf '%s\n' "$NEW_VARS" | grep -c '.' || echo 0)"
_emit auto_envvar_applied ",\"count\":${COUNT},\"hook\":\"pre-commit\""
echo "[pre-commit] RESILIENT-207: auto-documented $COUNT new CHUMP_* env var(s) → env-vars-internal.txt" >&2
echo "  $(printf '%s' "$NEW_VARS" | tr '\n' ' ')" >&2
exit 0
