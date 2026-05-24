#!/usr/bin/env bash
# scripts/dev/chump-pitch.sh — INFRA-1895
#
# One-command operator pitch. Ties together the META-067 Track 3 demo
# polish trio into a single CLI surface:
#
#   1. cat docs/DEMO_5MIN.md (sections 1-3)
#   2. scripts/dev/lightning-demo-timeline.sh --limit 10
#   3. scripts/dev/chump-dashboard-tui.sh
#   4. cat docs/DEMO_5MIN.md (sections 4-7)
#
# Use cases:
#   - Operator presents to Marcus / Gemini / grant readers without slide deck
#   - Screenshot capture: pipe to a file, share the output verbatim
#   - Sanity check: any developer joining the project runs this to see Chump
#     in 5 minutes of CLI text
#
# Usage:
#   chump-pitch.sh                 # all-at-once render (default)
#   chump-pitch.sh --paginate      # step through with less
#   chump-pitch.sh --limit 20      # bigger lightning table

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DOC="$REPO_ROOT/docs/DEMO_5MIN.md"
TIMELINE="$REPO_ROOT/scripts/dev/lightning-demo-timeline.sh"
DASHBOARD="$REPO_ROOT/scripts/dev/chump-dashboard-tui.sh"

PAGINATE=0
LIMIT=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --paginate) PAGINATE=1; shift ;;
        --limit) LIMIT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "chump-pitch: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

# Section 1-3 of DEMO_5MIN.md = top of the file through "Live lightning evidence"
# Section 4-7 = "Screenshot list" through end
print_demo_top() {
    if [[ -r "$DEMO_DOC" ]]; then
        awk '/^## Screenshot list/{exit} {print}' "$DEMO_DOC"
    else
        echo "(docs/DEMO_5MIN.md not found — skipping)"
    fi
}

print_demo_bottom() {
    if [[ -r "$DEMO_DOC" ]]; then
        awk '/^## Screenshot list/,EOF' "$DEMO_DOC"
    else
        echo "(docs/DEMO_5MIN.md not found — skipping)"
    fi
}

print_divider() {
    echo
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "▶ $1"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo
}

render() {
    print_divider "PITCH (1/4): The narrative (docs/DEMO_5MIN.md §1-3)"
    print_demo_top

    print_divider "PITCH (2/4): Last-${LIMIT} PR retrospective (lightning-demo-timeline)"
    if [[ -x "$TIMELINE" ]]; then
        "$TIMELINE" --limit "$LIMIT" 2>/dev/null || echo "(timeline script failed)"
    else
        echo "(scripts/dev/lightning-demo-timeline.sh not found — skipping)"
    fi

    print_divider "PITCH (3/4): Live snapshot (chump-dashboard-tui)"
    if [[ -x "$DASHBOARD" ]]; then
        "$DASHBOARD" 2>/dev/null || echo "(dashboard script failed)"
    else
        echo "(scripts/dev/chump-dashboard-tui.sh not found — skipping)"
    fi

    print_divider "PITCH (4/4): The takeaway (docs/DEMO_5MIN.md §4-end)"
    print_demo_bottom

    echo
    echo "──── END OF PITCH ──────────────────────────────────────────────────────"
    echo "  Re-run anytime: bash scripts/dev/chump-pitch.sh"
    echo "  Step through: bash scripts/dev/chump-pitch.sh --paginate"
}

if [[ "$PAGINATE" -eq 1 ]]; then
    if command -v less >/dev/null 2>&1; then
        render | less -R
    else
        render
    fi
else
    render
fi
