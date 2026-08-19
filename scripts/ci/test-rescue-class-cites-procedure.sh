#!/usr/bin/env bash
# test-rescue-class-cites-procedure.sh — META-249 (META-247 slice)
#
# Rescue-class PRs (titles matching fix(...rescue), fix(...trunk-red),
# unblock, fix(...allowlist), or filed-by-pr-shepherd) must cite the
# specific §5 failure-surface pattern and §6 cascade-impact row from
# docs/process/PR_RESCUE_PROCEDURE.md in their PR body (per
# SUBAGENT_DISPATCH.md's "every Sonnet brief for rescue work needs
# explicit §5 + §6 citations"). Catches rescue PRs that invent a new
# approach instead of citing the doctrine we already solved.
#
# Non-rescue-class PRs are skipped (exit 0, no-op).
#
# Usage:
#   bash scripts/ci/test-rescue-class-cites-procedure.sh [PR_NUMBER]
#
# Title/body resolution order:
#   1. PR_TITLE / PR_BODY env vars (set by caller, e.g. workflow event fields)
#   2. `gh pr view <PR_NUMBER> --json title,body` (requires GH_TOKEN)
#
# Exit: 0 = not rescue-class, or rescue-class with both citations present.
#       1 = rescue-class PR missing '§5' and/or '§6' citation.

set -euo pipefail

fail() { printf '[FAIL] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

PR_NUMBER="${1:-${GITHUB_PR_NUMBER:-}}"
TITLE="${PR_TITLE:-}"
BODY="${PR_BODY:-}"

if [[ -z "$TITLE" || -z "$BODY" ]]; then
    if [[ -z "$PR_NUMBER" ]]; then
        info "no PR_NUMBER and no PR_TITLE/PR_BODY env vars — nothing to check, skipping."
        exit 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        info "gh CLI not available and PR_TITLE/PR_BODY unset — skipping."
        exit 0
    fi
    JSON="$(gh pr view "$PR_NUMBER" --json title,body 2>/dev/null || true)"
    if [[ -z "$JSON" ]]; then
        info "could not fetch PR #$PR_NUMBER via gh — skipping."
        exit 0
    fi
    [[ -z "$TITLE" ]] && TITLE="$(printf '%s' "$JSON" | jq -r '.title // empty')"
    [[ -z "$BODY" ]] && BODY="$(printf '%s' "$JSON" | jq -r '.body // empty')"
fi

if [[ -z "$TITLE" ]]; then
    info "no PR title resolved — skipping."
    exit 0
fi

# Rescue-class title patterns (case-insensitive).
is_rescue_class=0
shopt -s nocasematch
if [[ "$TITLE" =~ fix\(.*rescue.*\) ]] \
    || [[ "$TITLE" =~ fix\(.*trunk-red.*\) ]] \
    || [[ "$TITLE" =~ unblock ]] \
    || [[ "$TITLE" =~ fix\(.*allowlist.*\) ]] \
    || [[ "$TITLE" =~ filed-by-pr-shepherd ]]; then
    is_rescue_class=1
fi
shopt -u nocasematch

if [[ "$is_rescue_class" -eq 0 ]]; then
    info "PR title '$TITLE' is not rescue-class — skipping."
    exit 0
fi

info "PR title '$TITLE' matched rescue-class pattern — checking §5/§6 citations."

MISSING=()
if [[ "$BODY" != *"§5"* ]]; then
    MISSING+=("§5 failure-surface citation")
fi
if [[ "$BODY" != *"§6"* ]]; then
    MISSING+=("§6 cascade-impact citation")
fi

if [[ "${#MISSING[@]}" -gt 0 ]]; then
    fail "rescue-class PR body is missing: ${MISSING[*]}"
    fail "Every rescue-class PR must cite the specific §5 failure-surface pattern"
    fail "and §6 cascade-impact row from docs/process/PR_RESCUE_PROCEDURE.md."
    fail "Example: 'Match §5.3 pattern — fix in <file> per that section's"
    fail "prescription. After this lands, expect §6.2 cascade — trigger rebase wave.'"
    exit 1
fi

info "rescue-class PR cites both §5 and §6 — OK."
exit 0
