#!/usr/bin/env bash
# gap-template.sh — INFRA-905
#
# Outputs a gap YAML template for the specified pillar to stdout.
# Intended to be used as: gap-template.sh --pillar EFFECTIVE > my-gap.md
#
# This script is called by 'chump gap template --pillar PILLAR' when
# the chump binary delegates to external helpers, or run standalone.
#
# Usage:
#   gap-template.sh --pillar PILLAR [--list]
#
# Options:
#   --pillar PILLAR   Print the template for PILLAR
#                     (EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE|MISSION)
#   --list            List available templates
#
# Environment:
#   REPO_ROOT         Repo root (default: auto-detected)

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
TEMPLATES_DIR="$REPO_ROOT/docs/gaps/TEMPLATES"
PILLAR=""
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pillar)    PILLAR="$2"; shift 2 ;;
        --list)      LIST_ONLY=1; shift ;;
        -h|--help)
            echo "Usage: gap-template.sh --pillar PILLAR [--list]"
            echo "Pillars: EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE MISSION"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── List mode ─────────────────────────────────────────────────────────────────
if [[ "$LIST_ONLY" -eq 1 ]]; then
    echo "Available gap templates:"
    for f in "$TEMPLATES_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .md)
        echo "  $name"
    done
    exit 0
fi

if [[ -z "$PILLAR" ]]; then
    echo "Usage: gap-template.sh --pillar PILLAR" >&2
    echo "Pillars: EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE MISSION" >&2
    exit 1
fi

# ── Normalize pillar name ─────────────────────────────────────────────────────
PILLAR_UP=$(printf '%s' "$PILLAR" | tr '[:lower:]' '[:upper:]')

case "$PILLAR_UP" in
    EFFECTIVE)   template="EFFECTIVE-gap-template.md" ;;
    CREDIBLE)    template="CREDIBLE-gap-template.md" ;;
    RESILIENT)   template="RESILIENT-gap-template.md" ;;
    ZERO-WASTE|ZEROWASTE|ZERO_WASTE)
                 template="EFFECTIVE-gap-template.md"  # Alias to EFFECTIVE style
                 echo "# Note: using EFFECTIVE template for ZERO-WASTE pillar" >&2
                 ;;
    MISSION)     template="CREDIBLE-gap-template.md"   # Alias to CREDIBLE style
                 echo "# Note: using CREDIBLE template for MISSION pillar" >&2
                 ;;
    *)
        echo "Unknown pillar: $PILLAR" >&2
        echo "Valid pillars: EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE MISSION" >&2
        exit 1 ;;
esac

template_path="$TEMPLATES_DIR/$template"
if [[ ! -f "$template_path" ]]; then
    echo "Template not found: $template_path" >&2
    exit 1
fi

cat "$template_path"
