#!/usr/bin/env bash
# test-no-claude-leak.sh — INFRA-1051
#
# Prevent NEW Claude-specific references from leaking into the product
# layer (src/, scripts/coord/, scripts/dispatch/, scripts/ops/) after
# the harness-decoupling work in INFRA-1044/1045/1046/1048/1050 lands.
#
# Today's baseline: 39 files in those dirs contain "claude" references.
# That long-tail is INFRA-1053 backfill scope. This gate prevents
# regression: any PR adding NEW "claude" strings to product-layer code
# without justification fails.
#
# Default mode: CHANGED-ONLY (PR diff vs origin/main). Files outside
# the modification set are not scanned.
#
# Allowlist (won't fire on these paths even when modified):
#   - CLAUDE.md, .claude/**           # canonical Claude-Code overlay
#   - docs/process/CLAUDE_GOTCHAS.md  # operational notes
#   - scripts/dispatch/harnesses/claude.sh  # explicit Claude harness wrapper (INFRA-1045)
#   - scripts/dispatch/harnesses/*.sh # other harness wrappers may mention Claude as a peer
#   - any line with the marker `# chump-harness-ok: claude-mention`
#
# Default: WARN-ONLY. Promote to --strict (or CHUMP_NO_CLAUDE_LEAK_STRICT=1)
# once INFRA-1053 backfill is complete and the 39-file long-tail is cleaned.
#
# Usage:
#   bash scripts/ci/test-no-claude-leak.sh                  # warn-only, changed files
#   bash scripts/ci/test-no-claude-leak.sh --strict         # blocking
#   bash scripts/ci/test-no-claude-leak.sh --all --strict   # full-repo (audit)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

MODE="changed"
STRICT=0
BASE_BRANCH="${GITHUB_BASE_REF:-main}"
prev=""
for arg in "$@"; do
    case "$arg" in
        --all) MODE="all" ;;
        --changed) MODE="changed" ;;
        --strict) STRICT=1 ;;
        --base) ;;
    esac
    [[ "$prev" == "--base" ]] && BASE_BRANCH="$arg"
    prev="$arg"
done
[[ "${CHUMP_NO_CLAUDE_LEAK_STRICT:-0}" == "1" ]] && STRICT=1

# Paths that ARE product-layer (subject to the gate)
SCAN_PREFIXES=(
    "src/"
    "scripts/coord/"
    "scripts/dispatch/"
    "scripts/ops/"
)

# Paths that are NOT product-layer (Claude mentions OK):
ALLOWLIST_PATHS=(
    "CLAUDE.md"
    ".claude/"
    "docs/process/CLAUDE_GOTCHAS.md"
    "scripts/dispatch/harnesses/"  # INFRA-1045 harness wrappers
)

is_allowlisted() {
    local p="$1"
    for a in "${ALLOWLIST_PATHS[@]}"; do
        if [[ "$p" == "$a"* || "$p" == "$a" ]]; then
            return 0
        fi
    done
    return 1
}

is_in_scope() {
    local p="$1"
    is_allowlisted "$p" && return 1
    for s in "${SCAN_PREFIXES[@]}"; do
        if [[ "$p" == "$s"* ]]; then
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
        echo "=== INFRA-1051: no changed files vs origin/${BASE_BRANCH} — skipping ==="
        exit 0
    fi
    FILES="$CHANGED"
else
    FILES=""
    for s in "${SCAN_PREFIXES[@]}"; do
        if [[ -d "$s" ]]; then
            while IFS= read -r f; do
                FILES+="$f"$'\n'
            done < <(find "$s" -type f \( -name '*.rs' -o -name '*.sh' -o -name '*.py' -o -name '*.toml' \) 2>/dev/null)
        fi
    done
fi

VIOLATIONS=0
DETAILS=()
SCANNED=0

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_in_scope "$f" || continue
    [[ -f "$f" ]] || continue
    SCANNED=$((SCANNED + 1))

    if [[ "$MODE" == "changed" ]]; then
        # NEW lines added in this PR that match 'claude' case-insensitively.
        # Skip lines with the explicit opt-out marker.
        new_hits=$(git diff "origin/${BASE_BRANCH}...HEAD" -- "$f" 2>/dev/null \
            | grep -E '^\+' \
            | grep -v '^+++' \
            | grep -iE 'claude' \
            | grep -v 'chump-harness-ok: claude-mention' \
            || true)
        if [[ -n "$new_hits" ]]; then
            hit_count=$(echo "$new_hits" | wc -l | tr -d ' ')
            VIOLATIONS=$((VIOLATIONS + hit_count))
            DETAILS+=("$f: $hit_count new line(s)")
        fi
    else
        # Full-repo audit: every line counts.
        hits=$(grep -iE 'claude' "$f" 2>/dev/null \
            | grep -v 'chump-harness-ok: claude-mention' \
            | wc -l | tr -d ' ')
        if [[ "$hits" -gt 0 ]]; then
            VIOLATIONS=$((VIOLATIONS + hits))
            DETAILS+=("$f: $hits line(s)")
        fi
    fi
done <<< "$FILES"

MODE_STR=$([[ "$STRICT" == "1" ]] && echo STRICT || echo WARN-ONLY)
SCOPE_STR=$([[ "$MODE" == "all" ]] && echo full-repo || echo changed-only)
echo "=== INFRA-1051 [${MODE_STR}, ${SCOPE_STR}] ==="
echo "Scanned: ${SCANNED} file(s) in product-layer scope"
echo "Violations (new 'claude' mentions outside allowlist): ${VIOLATIONS}"

if [[ "${VIOLATIONS}" -gt 0 ]]; then
    echo ""
    for d in "${DETAILS[@]}"; do
        echo "  ${d}"
    done
    echo ""
    echo "Allowlist for product-layer files that legitimately mention Claude:"
    for a in "${ALLOWLIST_PATHS[@]}"; do
        echo "  ${a}"
    done
    echo ""
    echo "Per-line opt-out: append \`# chump-harness-ok: claude-mention\` to the line."
    echo "Per-PR opt-out (rare): CHUMP_NO_CLAUDE_LEAK_BYPASS=1 with justification in commit body."
fi

if [[ "${VIOLATIONS}" -gt 0 && "$STRICT" == "1" ]]; then
    exit 1
fi
exit 0
