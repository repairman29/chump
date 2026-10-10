#!/usr/bin/env bash
# pre-commit-preflight-exceptions-autoappend.sh — RESILIENT-587 (RESILIENT-545 slice)
#
# Fires ONLY when .github/workflows/ci.yml is part of the staged diff.
# Scans the staged diff for newly-added gate identifiers (scripts/ci/*.sh
# paths referenced by a `run:` step, or new `- name: ...` step labels) and,
# for any gate that is not already mirrored in `chump preflight`
# (crates/chump-preflight/src/preflight.rs), not Tier-D
# (docs/process/CI_GATES_INVENTORY.md), and not already allowlisted
# (scripts/ci/preflight-ci-parity-exceptions.txt), appends a new allowlist
# entry so `test-preflight-ci-parity.sh` (the pre-commit gate right after
# this one, see pre-commit-preflight-ci-parity.sh) passes without manual
# intervention.
#
# This does NOT replace real classification — it's a safety net so a
# newly-added CI gate never silently blocks a commit; the auto-appended
# entry's reason explicitly flags it for proper follow-up (mirror in
# preflight.rs or Tier-D classification).
#
# Runs BEFORE pre-commit-preflight-ci-parity.sh in the main pre-commit
# hook (see scripts/git-hooks/pre-commit, section "preflight-vs-CI parity
# smoke") so the parity check sees the freshly-appended entry.
#
# Bypass: CHUMP_PREFLIGHT_AUTOAPPEND=0 (with reason) OR
#         git commit --no-verify.

set -uo pipefail

if [ "${CHUMP_PREFLIGHT_AUTOAPPEND:-1}" = "0" ]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 1

# Fast-mode gate: only fire when ci.yml is staged.
if ! git diff --cached --name-only 2>/dev/null | grep -qE '^\.github/workflows/ci\.yml$'; then
    exit 0
fi

EXCEPTIONS_FILE="$REPO_ROOT/scripts/ci/preflight-ci-parity-exceptions.txt"
PREFLIGHT_SRC="$REPO_ROOT/crates/chump-preflight/src/preflight.rs"
GATES_INVENTORY="$REPO_ROOT/docs/process/CI_GATES_INVENTORY.md"

DIFF_ADDED="$(git diff --cached -- .github/workflows/ci.yml 2>/dev/null | grep -E '^\+' | grep -v -F '+++ ')"

if [ -z "$DIFF_ADDED" ]; then
    exit 0
fi

# Walk the added lines sequentially, pairing each "- name: ..." with the
# "run: ..." that follows it (mirrors the step shape in ci.yml). The
# candidate identifier for a step is its scripts/ci/*.sh path when the run
# command references one (that's what preflight.rs and the exceptions file
# key on), otherwise the step name itself.
CANDIDATES_RAW="$(
    CURRENT_NAME=""
    while IFS= read -r line; do
        case "$line" in
            +*-\ name:*)
                CURRENT_NAME="$(printf '%s' "$line" | sed -E 's/^\+[[:space:]]*-[[:space:]]*name:[[:space:]]*//; s/^"//; s/"$//')"
                ;;
            +*run:*)
                run_cmd="$(printf '%s' "$line" | sed -E 's/^\+[[:space:]]*run:[[:space:]]*//')"
                script_path="$(printf '%s' "$run_cmd" | grep -oE 'scripts/ci/[^[:space:]"'"'"']+\.sh' | head -1)"
                if [ -n "$script_path" ]; then
                    printf '%s\n' "$script_path"
                elif [ -n "$CURRENT_NAME" ]; then
                    printf '%s\n' "$CURRENT_NAME"
                fi
                CURRENT_NAME=""
                ;;
        esac
    done <<< "$DIFF_ADDED" | sort -u
)"

if [ -z "$CANDIDATES_RAW" ]; then
    exit 0
fi

APPENDED=0

while IFS= read -r entry; do
    [ -z "$entry" ] && continue

    # Already mirrored in preflight.rs?
    if [ -f "$PREFLIGHT_SRC" ] && grep -qF -- "$entry" "$PREFLIGHT_SRC" 2>/dev/null; then
        continue
    fi

    # Already classified Tier-D?
    if [ -f "$GATES_INVENTORY" ] && grep -qF -- "$entry" "$GATES_INVENTORY" 2>/dev/null; then
        continue
    fi

    # Already allowlisted — AC4: pass without modification.
    if [ -f "$EXCEPTIONS_FILE" ] && grep -vE '^[[:space:]]*#' "$EXCEPTIONS_FILE" 2>/dev/null | grep -qF -- "$entry"; then
        continue
    fi

    # New, unclassified gate — append an allowlist entry.
    if ! printf '%s  # reason: auto-appended by pre-commit hook (RESILIENT-587) — new CI gate detected in staged ci.yml diff; classify properly (mirror in preflight.rs or Tier-D in CI_GATES_INVENTORY.md) in a follow-up\n' "$entry" >> "$EXCEPTIONS_FILE" 2>/tmp/chump-preflight-autoappend.err; then
        echo "[pre-commit] ERROR: preflight-exceptions-autoappend could not update $EXCEPTIONS_FILE for gate '$entry'" >&2
        [ -f /tmp/chump-preflight-autoappend.err ] && cat /tmp/chump-preflight-autoappend.err >&2
        rm -f /tmp/chump-preflight-autoappend.err
        exit 1
    fi
    rm -f /tmp/chump-preflight-autoappend.err
    APPENDED=1
    echo "[pre-commit] preflight-exceptions-autoappend: added '$entry' to $(basename "$EXCEPTIONS_FILE") (RESILIENT-587)" >&2
done <<EOF
$CANDIDATES_RAW
EOF

if [ "$APPENDED" = "1" ]; then
    if ! git add "$EXCEPTIONS_FILE" 2>/tmp/chump-preflight-autoappend.err; then
        echo "[pre-commit] ERROR: preflight-exceptions-autoappend could not stage $EXCEPTIONS_FILE" >&2
        [ -f /tmp/chump-preflight-autoappend.err ] && cat /tmp/chump-preflight-autoappend.err >&2
        rm -f /tmp/chump-preflight-autoappend.err
        exit 1
    fi
    rm -f /tmp/chump-preflight-autoappend.err
fi

exit 0
