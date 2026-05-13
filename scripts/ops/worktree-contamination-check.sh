#!/usr/bin/env bash
# worktree-contamination-check.sh — INFRA-931
#
# Detects untracked files in the current worktree that belong to OTHER active
# gap-claim branches (docs/gaps/*.yaml or scripts/ paths that match a foreign
# gap branch pattern).  These appear when macOS /tmp → /private/tmp symlink
# confusion or concurrent git worktree add calls "contaminate" a worktree with
# files left behind from a different gap session.
#
# Usage:
#   worktree-contamination-check.sh [--fix] [--dry-run] [--json] [WORKTREE_PATH]
#
# Options:
#   --fix       Remove detected contaminant files (preview shown before removal)
#   --dry-run   Print what would be done; never remove files or emit to ambient
#   --json      Output JSON summary to stdout instead of human text
#
# Environment:
#   REPO_ROOT              Repo root (auto-detected if omitted)
#   CHUMP_AMBIENT_LOG      Path to ambient.jsonl
#   CHUMP_CURRENT_GAP_ID   This session's gap ID (used in event payload)
#   DRY_RUN                If "1", suppress writes and removals
#
# Exit codes:
#   0  No contamination found (or --dry-run / --fix succeeded)
#   1  Contamination found and not fixed
#   2  Usage / environment error

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GAP_ID="${CHUMP_CURRENT_GAP_ID:-unknown}"
DRY_RUN="${DRY_RUN:-0}"
FIX=0
JSON_OUT=0
TARGET_WORKTREE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)      FIX=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --json)     JSON_OUT=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -30 | sed 's/^# \?//'
            exit 0 ;;
        -*)         echo "Unknown option: $1" >&2; exit 2 ;;
        *)          TARGET_WORKTREE="$1"; shift ;;
    esac
done

# Default to current working directory as the worktree to check
WORKTREE="${TARGET_WORKTREE:-$(pwd)}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Determine active gap-claim branches ──────────────────────────────────────
# Pattern: chump/<domain>-<number>-claim or docs/gaps/<ID>.yaml
# We detect "foreign" untracked files by checking if they match gap patterns
# that belong to a branch OTHER than the current branch.

CURRENT_BRANCH=""
if CURRENT_BRANCH=$(git -C "$WORKTREE" branch --show-current 2>/dev/null); then
    : # got it
else
    # worktree may be detached or git unavailable
    CURRENT_BRANCH=""
fi

# ── Collect untracked files via git ls-files ─────────────────────────────────
# Use git ls-files --others to get individual untracked file paths (not
# directory-level like git status --porcelain which shows "?? docs/" when
# the whole docs/ subtree is new).
CONTAMINANTS=()

while IFS= read -r filepath; do
    [[ -n "$filepath" ]] || continue

    # Check if this file matches a gap-claim contaminant pattern:
    #   docs/gaps/*.yaml  — a gap YAML that isn't part of this branch's work
    #   docs/gaps/<ID>.yaml where ID doesn't match current gap branch
    is_contaminant=0

    # Pattern 1: docs/gaps/<DOMAIN>-<NUMBER>.yaml from another gap
    if [[ "$filepath" =~ ^docs/gaps/([A-Z]+-[0-9]+)[.]yaml$ ]]; then
        alien_gap="${BASH_REMATCH[1]}"
        # If current branch is chump/<gap-id>-claim, this file is a contaminant
        # if its ID doesn't match OUR branch's gap
        if [[ -n "$CURRENT_BRANCH" ]]; then
            # Extract our gap ID from branch name: chump/infra-123-claim → INFRA-123
            if [[ "$CURRENT_BRANCH" =~ chump/([a-z]+-[0-9]+)-claim ]]; then
                our_gap=$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]' | sed 's/-//')
                # Normalize alien gap: INFRA-931 → INFRA931 for comparison
                alien_norm=$(echo "$alien_gap" | sed 's/-//')
                if [[ "$alien_norm" != "$our_gap" ]]; then
                    is_contaminant=1
                fi
            else
                # Not on a gap branch — any untracked gap YAML is suspicious
                is_contaminant=1
            fi
        fi
    fi

    # Pattern 2: scripts/ files from another gap-claim worktree that leaked
    # (e.g., scripts/ops/<something>.sh that doesn't belong to our gap)
    # We detect this if the file was created in a path that matches another
    # worktree's working directory (heuristic: file exists in REPO_ROOT too)
    if [[ "$filepath" =~ ^scripts/ ]] && [[ -f "$REPO_ROOT/$filepath" ]]; then
        # The file also exists in REPO_ROOT — it might be a leftover copy
        # from a sibling worktree that shared the same script path.
        # Only flag if it differs from HEAD (it was not intentionally modified).
        if git -C "$WORKTREE" diff --quiet HEAD -- "$filepath" 2>/dev/null; then
            : # same as HEAD — not a contaminant
        else
            is_contaminant=1
        fi
    fi

    if [[ "$is_contaminant" -eq 1 ]]; then
        CONTAMINANTS+=("$filepath")
    fi
done < <(git -C "$WORKTREE" ls-files --others --exclude-standard 2>/dev/null || true)

CONTAMINATED_COUNT="${#CONTAMINANTS[@]}"
EXAMPLE_FILE="${CONTAMINANTS[0]:-}"

# ── Emit ambient event if contamination found ─────────────────────────────────
_emit_event() {
    local ts; ts="$(_ts)"
    local payload
    payload=$(printf '{"ts":"%s","kind":"worktree_contaminated","gap_id":"%s","worktree_path":"%s","contaminated_count":%d,"example_file":"%s"}' \
        "$ts" "$GAP_ID" "$WORKTREE" "$CONTAMINATED_COUNT" "$EXAMPLE_FILE")

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would emit: $payload" >&2
    else
        mkdir -p "$(dirname "$AMB")"
        printf '%s\n' "$payload" >> "$AMB"
    fi
}

# ── Fix mode: remove contaminants ────────────────────────────────────────────
if [[ "$FIX" -eq 1 ]] && [[ "$CONTAMINATED_COUNT" -gt 0 ]]; then
    echo "Found $CONTAMINATED_COUNT contaminant(s) in $WORKTREE:" >&2
    for f in "${CONTAMINANTS[@]}"; do
        echo "  $f" >&2
    done

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would remove the above files" >&2
    else
        echo "Removing contaminants..." >&2
        for f in "${CONTAMINANTS[@]}"; do
            rm -f "$WORKTREE/$f"
            echo "  removed: $f" >&2
        done
        CONTAMINATED_COUNT=0
        CONTAMINANTS=()
        EXAMPLE_FILE=""
    fi
fi

# ── JSON output ───────────────────────────────────────────────────────────────
if [[ "$JSON_OUT" -eq 1 ]]; then
    contaminated_list=""
    for f in "${CONTAMINANTS[@]}"; do
        contaminated_list="$contaminated_list\"$f\","
    done
    contaminated_list="[${contaminated_list%,}]"
    printf '{"worktree_path":"%s","contaminated_count":%d,"example_file":"%s","files":%s,"current_branch":"%s"}\n' \
        "$WORKTREE" "$CONTAMINATED_COUNT" "$EXAMPLE_FILE" "$contaminated_list" "$CURRENT_BRANCH"
else
    if [[ "$CONTAMINATED_COUNT" -gt 0 ]]; then
        echo "CONTAMINATED: $CONTAMINATED_COUNT foreign gap file(s) in $WORKTREE" >&2
        echo "  example: $EXAMPLE_FILE" >&2
        echo "  Fix: $0 --fix $WORKTREE" >&2
    else
        echo "OK: no contamination detected in $WORKTREE"
    fi
fi

# ── Emit and exit ─────────────────────────────────────────────────────────────
if [[ "$CONTAMINATED_COUNT" -gt 0 ]]; then
    _emit_event
    exit 1
fi
