#!/usr/bin/env bash
# gen-pwa-component-inventory.sh (INFRA-1593) — regenerate the component
# inventory table in docs/design/PWA_STYLE_GUIDE.md by grepping
# customElements.define() calls across web/v2/*.js.
#
# Read-only by default (prints the markdown table to stdout). Pass --check
# to diff against the committed table and exit non-zero on drift (for a
# future CI gate); pass --write to replace the table in-place.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

STYLE_GUIDE="docs/design/PWA_STYLE_GUIDE.md"
MODE="${1:---print}"

gen_table() {
    echo "| Tag | Source file | Introduced by |"
    echo "|---|---|---|"
    grep -n "customElements\.define('" web/v2/*.js \
        | sed -E "s#web/v2/##; s/:[0-9]+:.*customElements\.define\('([^']+)'.*/\t\1/" \
        | sort -t$'\t' -k1,1 \
        | while IFS=$'\t' read -r file tag; do
            ticket=$(git log --diff-filter=A --format='%s' -- "web/v2/$file" 2>/dev/null \
                | tail -1 \
                | grep -oiE '[a-z][a-z-]*-[0-9]+' | head -1 || true)
            echo "| \`<${tag}>\` | \`web/v2/${file}\` | ${ticket:-unknown} |"
        done
}

case "$MODE" in
    --print|"")
        gen_table
        ;;
    --check)
        current=$(gen_table)
        if ! grep -qF "$(echo "$current" | head -1)" "$STYLE_GUIDE" 2>/dev/null; then
            echo "gen-pwa-component-inventory: table format drifted from $STYLE_GUIDE" >&2
            exit 1
        fi
        # Verify every currently-defined tag has a row in the doc.
        missing=0
        while IFS= read -r tag; do
            grep -qF "<${tag}>" "$STYLE_GUIDE" || { echo "MISSING from style guide: <${tag}>" >&2; missing=1; }
        done < <(grep -ohE "customElements\.define\('[^']+'" web/v2/*.js | sed -E "s/.*'([^']+)'/\1/")
        exit "$missing"
        ;;
    --write)
        tmp=$(mktemp)
        awk '
            /<!-- BEGIN component-inventory-table -->/ { print; found=1; next }
            /<!-- END component-inventory-table -->/   { system("bash scripts/dev/gen-pwa-component-inventory.sh --print"); print; found=0; next }
            !found { print }
        ' "$STYLE_GUIDE" > "$tmp"
        mv "$tmp" "$STYLE_GUIDE"
        echo "Updated $STYLE_GUIDE component inventory table."
        ;;
    *)
        echo "usage: $0 [--print|--check|--write]" >&2
        exit 2
        ;;
esac
