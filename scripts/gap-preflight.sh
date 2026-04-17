#!/usr/bin/env bash
# gap-preflight.sh — Verify gap IDs are still open/unclaimed on origin/main.
#
# Run this BEFORE claiming a gap or starting work on a new branch. If a gap is
# already `done` on main, exit non-zero so the caller can abort early and save
# the inference budget.
#
# Usage:
#   scripts/gap-preflight.sh GAP-ID [GAP-ID ...]
#   scripts/gap-preflight.sh AUTO-003 COMP-002
#
# Exit codes:
#   0  All specified gaps are open (or in_progress by this session) — proceed.
#   1  One or more gaps are already done or claimed by another session — abort.
#
# Environment:
#   REMOTE            git remote to check (default: origin)
#   BASE              base branch to check against (default: main)
#   CHUMP_SESSION_ID  current agent session ID — used to distinguish "our" claims
#                     from other agents' claims. Set automatically by the Chump
#                     agent_lease bootstrap or from CLAUDE_SESSION_ID.

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 GAP-ID [GAP-ID ...]" >&2
    exit 0
fi

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
# Honour CLAUDE_SESSION_ID (set by the Claude agent SDK) as a fallback.
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

red()   { printf '\033[0;31m[gap-preflight] %s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m[gap-preflight] %s\033[0m\n' "$*" >&2; }
info()  { printf '[gap-preflight] %s\n' "$*" >&2; }

# Fetch silently; tolerate offline environments (CI cache, airgap).
git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    info "WARN: could not fetch $REMOTE/$BASE — skipping remote check (offline?)"
    exit 0
}

GAPS_YAML=$(git show "$REMOTE/$BASE:docs/gaps.yaml" 2>/dev/null) || {
    info "WARN: docs/gaps.yaml not found on $REMOTE/$BASE — skipping check"
    exit 0
}

# Extract a field value from a gap block.
# Usage: gap_field GAP_ID FIELD_NAME
# Returns the first value of FIELD_NAME after the gap's `- id:` line.
gap_field() {
    local gid="$1" field="$2"
    echo "$GAPS_YAML" | awk \
        "/^  - id: ${gid}\$/{found=1} found && /^    ${field}:/{sub(/^    ${field}: */,\"\"); print; exit}"
}

FAILED=0

for GAP_ID in "$@"; do
    STATUS=$(gap_field "$GAP_ID" "status")

    if [[ -z "$STATUS" ]]; then
        info "WARN: $GAP_ID not found in gaps.yaml — skipping (new gap?)"
        continue
    fi

    case "$STATUS" in
        done)
            red "SKIP $GAP_ID — already status:done on $REMOTE/$BASE."
            red "  The work exists. No need to re-implement. Choose a different gap."
            FAILED=1
            ;;
        in_progress)
            CLAIMED_BY=$(gap_field "$GAP_ID" "claimed_by")
            if [[ -n "$SESSION_ID" && "$CLAIMED_BY" == "$SESSION_ID" ]]; then
                green "OK $GAP_ID — in_progress and claimed by this session."
            elif [[ -n "$CLAIMED_BY" && "$CLAIMED_BY" != "$SESSION_ID" ]]; then
                red "SKIP $GAP_ID — in_progress and claimed by '$CLAIMED_BY'."
                red "  Coordinate before duplicating work."
                FAILED=1
            else
                info "OK $GAP_ID — in_progress (no conflicting claimer found)."
            fi
            ;;
        open)
            green "OK $GAP_ID — open and unclaimed."
            ;;
        partial|deferred|blocked)
            info "NOTE $GAP_ID — status:$STATUS. Verify you're not duplicating existing partial work."
            ;;
        *)
            info "WARN $GAP_ID — unknown status '$STATUS'. Proceeding with caution."
            ;;
    esac
done

if [[ $FAILED -eq 1 ]]; then
    red "Pre-flight failed: one or more gaps already done or claimed."
    red "Run: git show $REMOTE/$BASE:docs/gaps.yaml | grep -A10 'id: GAP-XYZ'"
    exit 1
fi

green "Pre-flight passed — all specified gaps are available."
exit 0
