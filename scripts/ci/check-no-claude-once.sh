#!/usr/bin/env bash
# check-no-claude-once.sh — RESILIENT-1142
#
# Prevent usage of the prohibited "claude --once" flag in production scripts.
# The --once flag was a debug/test-only mode that should not be used in
# fleet execution paths like run-fleet.sh. Use "claude -p" for auth probes instead.
#
# Specifically detects: `claude --once` and `"$CLAUDE" --once` patterns.
#
# Default mode: CHANGED-ONLY (PR diff vs origin/main). Files outside the
# modification set are not scanned.
#
# Allowed locations (won't fire on these paths even when modified):
#   - scripts/ci/test-*.sh          # test scripts may use --once for testing
#   - scripts/setup/test-*.sh       # setup test scripts may use --once
#   - docs/**                       # documentation may reference the flag
#   - any line with the marker `# claude-once-ok`
#
# Default: BLOCKING.
#
# Usage:
#   bash scripts/ci/check-no-claude-once.sh                  # blocking, changed files
#   bash scripts/ci/check-no-claude-once.sh --warn-only      # advisory
#   bash scripts/ci/check-no-claude-once.sh --all            # full-repo audit
#   bash scripts/ci/check-no-claude-once.sh --all --warn-only

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

MODE="changed"
WARN_ONLY=0
BASE_BRANCH="${GITHUB_BASE_REF:-main}"
prev=""
for arg in "$@"; do
    case "$arg" in
        --all) MODE="all" ;;
        --changed) MODE="changed" ;;
        --warn-only) WARN_ONLY=1 ;;
        --blocking) WARN_ONLY=0 ;;
        --base) ;;
    esac
    [[ "$prev" == "--base" ]] && BASE_BRANCH="$arg"
    prev="$arg"
done

# Paths where --once usage is allowed (test/doc context)
ALLOWLIST_PATHS=(
    "scripts/ci/test-"
    "scripts/ci/check-no-claude-once.sh"  # checker itself may reference the pattern in comments
    "scripts/setup/test-"
    "docs/"
)

is_allowlisted() {
    local p="$1"
    # Normalize path: remove leading ./
    p="${p#./}"
    for a in "${ALLOWLIST_PATHS[@]}"; do
        if [[ "$p" == "$a"* || "$p" == "$a" ]]; then
            return 0
        fi
    done
    return 1
}

# Build the file list.
if [[ "$MODE" == "changed" ]]; then
    if git rev-parse --verify "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
        CHANGED="$(git diff --name-only --diff-filter=AM "origin/${BASE_BRANCH}...HEAD" 2>/dev/null || true)"
    elif git rev-parse --verify "${BASE_BRANCH}" >/dev/null 2>&1; then
        CHANGED="$(git diff --name-only --diff-filter=AM "${BASE_BRANCH}...HEAD" 2>/dev/null || true)"
    else
        CHANGED=""
    fi
    if [[ -z "$CHANGED" ]]; then
        echo "=== RESILIENT-1142: no changed files vs origin/${BASE_BRANCH} — skipping ==="
        exit 0
    fi
    FILES="$CHANGED"
else
    FILES=""
    # Scan all shell scripts
    while IFS= read -r f; do
        FILES+="$f"$'\n'
    done < <(find . -type f \( -name '*.sh' \) ! -path './.*' 2>/dev/null)
fi

VIOLATIONS=0
DETAILS=()
SCANNED=0

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_allowlisted "$f" && continue
    [[ -f "$f" ]] || continue
    SCANNED=$((SCANNED + 1))

    if [[ "$MODE" == "changed" ]]; then
        # NEW lines added in this PR that match 'claude --once' or '$CLAUDE --once'.
        # Skip lines with the explicit opt-out marker.
        new_hits=$(git diff "origin/${BASE_BRANCH}...HEAD" -- "$f" 2>/dev/null \
            | grep -E '^\+' \
            | grep -v '^+++' \
            | grep -E '(claude\s+--once|"\$CLAUDE"\s+--once|\$CLAUDE\s+--once)' \
            | grep -v 'claude-once-ok' \
            || true)
        if [[ -n "$new_hits" ]]; then
            hit_count=$(echo "$new_hits" | wc -l | tr -d ' ')
            VIOLATIONS=$((VIOLATIONS + hit_count))
            DETAILS+=("$f: $hit_count new line(s) with claude --once")
        fi
    else
        # Full-repo audit: every line counts.
        hits=$(grep -E '(claude\s+--once|"\$CLAUDE"\s+--once|\$CLAUDE\s+--once)' "$f" 2>/dev/null \
            | grep -v 'claude-once-ok' \
            | wc -l | tr -d ' ')
        if [[ "$hits" -gt 0 ]]; then
            VIOLATIONS=$((VIOLATIONS + hits))
            DETAILS+=("$f: $hits line(s) with claude --once")
        fi
    fi
done <<< "$FILES"

MODE_STR=$([[ "$WARN_ONLY" == "1" ]] && echo "ADVISORY" || echo "BLOCKING")
SCOPE_STR=$([[ "$MODE" == "all" ]] && echo "full-repo" || echo "changed-only")
echo "=== RESILIENT-1142 [${MODE_STR}, ${SCOPE_STR}] ==="
echo "Scanned: ${SCANNED} file(s) for prohibited 'claude --once' flag"
echo "Violations: ${VIOLATIONS}"

if [[ "${VIOLATIONS}" -gt 0 ]]; then
    echo ""
    for d in "${DETAILS[@]}"; do
        echo "  ${d}"
    done
    echo ""
    echo "The 'claude --once' flag is prohibited in production scripts (e.g., run-fleet.sh, worker.sh)."
    echo "It was a debug-only mode and should not be used in fleet execution paths."
    echo "Use 'claude -p' for auth probes instead."
    echo ""
    echo "Allowed contexts for 'claude --once':"
    for a in "${ALLOWLIST_PATHS[@]}"; do
        echo "  ${a}"
    done
    echo ""
    echo "Per-line opt-out (rare): append \`# claude-once-ok\` to the line."
fi

if [[ "${VIOLATIONS}" -gt 0 && "$WARN_ONLY" == "0" ]]; then
    exit 1
fi

if [[ "${VIOLATIONS}" -eq 0 ]]; then
    echo "No prohibited flags found."
fi

exit 0
