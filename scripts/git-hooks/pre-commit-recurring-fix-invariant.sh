#!/usr/bin/env bash
# pre-commit-recurring-fix-invariant.sh — RESILIENT-1107
#
# Meta-rule (Track A, docs/design/DESIGN_GAPS_SELF_RUNNING.md): "no fix for a
# recurring failure class ships without its invariant-check registered
# alongside it." A fix that isn't ratcheted un-solves silently (the
# Anti-Memento disease) — see RESILIENT-1104/1105's invariant registry +
# guard-organ (scripts/ops/invariant-registry.txt, scripts/ops/invariant-guard.sh).
#
# Trigger: the staged commit message flags itself as fixing a RECURRING
# class — the convention already in use fleet-wide (e.g. "recurring
# CREDIBLE-090", "end the recurring stomp"). When that marker is present,
# the commit must ALSO touch scripts/ops/invariant-registry.txt (register
# the guard-rail for the class just fixed), or carry a bypass trailer.
#
# Bypass: 'Invariant-Check-Bypass: <one-sentence reason>' commit trailer
#   (e.g. the fix predates the registry landing, or the class is already
#   covered by an existing registered invariant).
# Env hatch: CHUMP_RECURRING_FIX_CHECK=0

set -uo pipefail

if [[ "${CHUMP_RECURRING_FIX_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -z "$REPO_ROOT" ]] && exit 0

MSG_FILE="$(git rev-parse --git-common-dir 2>/dev/null)/COMMIT_EDITMSG"
[[ -f "$MSG_FILE" ]] || exit 0

# Only fire when the commit message self-identifies as fixing a recurring
# failure class. Deliberately narrow (word "recurring") to match the
# convention already used in commit history rather than guessing intent.
if ! grep -qiE 'recurring' "$MSG_FILE" 2>/dev/null; then
    exit 0
fi

REGISTRY_PATH="scripts/ops/invariant-registry.txt"

STAGED_FILES="$(git diff --cached --name-only 2>/dev/null || true)"

if echo "$STAGED_FILES" | grep -qxF "$REGISTRY_PATH"; then
    # Invariant registered alongside the fix. Nothing to do.
    exit 0
fi

# Registry untouched. Check for bypass trailer.
if grep -qE '^Invariant-Check-Bypass:' "$MSG_FILE" 2>/dev/null; then
    reason="$(grep -E '^Invariant-Check-Bypass:' "$MSG_FILE" | head -1 | sed 's/^Invariant-Check-Bypass:[[:space:]]*//')"

    AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        commit_sha="$(git rev-parse --short HEAD 2>/dev/null || echo 'pre-commit')"
        esc_reason="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{"ts":"%s","kind":"recurring_fix_invariant_bypass_used","commit_sha":"%s","reason":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$commit_sha" "$esc_reason" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
    exit 0
fi

echo "[pre-commit] BLOCKED (RESILIENT-1107): commit message flags a fix for a" >&2
echo "[pre-commit] RECURRING failure class, but the diff does not touch" >&2
echo "[pre-commit]   $REGISTRY_PATH" >&2
echo "[pre-commit] Register an invariant-check for the class alongside the fix" >&2
echo "[pre-commit] (see scripts/ops/invariant-guard.sh, RESILIENT-1104/1105), or" >&2
echo "[pre-commit] add a trailer: 'Invariant-Check-Bypass: <reason>'." >&2

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
if [[ -d "$(dirname "$AMBIENT")" ]]; then
    printf '{"ts":"%s","kind":"recurring_fix_invariant_blocked"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMBIENT" 2>/dev/null || true
fi

exit 1
