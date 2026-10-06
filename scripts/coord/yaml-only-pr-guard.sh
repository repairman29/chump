#!/usr/bin/env bash
# scripts/coord/yaml-only-pr-guard.sh — INFRA-3614 (waste-prevention slice)
#
# Exit 1 when every path in the diff is a docs/gaps/<ID>.yaml mirror file.
# state.db is canonical (ZERO-WASTE-020); the YAML is a generated mirror, so a
# PR that touches only those files has no outcome and just becomes a
# CONFLICTING zombie. Exit 0 otherwise (including an empty diff).
#
# Usage: yaml-only-pr-guard.sh [<base-ref>]   (default origin/main)
#        git diff --name-only ... | yaml-only-pr-guard.sh -   (read paths on stdin)
#   CHUMP_ALLOW_YAML_ONLY_PR=1  bypass (exit 0)
set -uo pipefail
[[ "${CHUMP_ALLOW_YAML_ONLY_PR:-0}" == "1" ]] && exit 0
if [[ "${1:-}" == "-" ]]; then
    files="$(cat)"
else
    files="$(git diff --name-only "${1:-origin/main}..HEAD" 2>/dev/null)"
fi
[[ -z "$files" ]] && exit 0
if grep -qvE '^docs/gaps/[A-Za-z0-9-]+\.yaml$' <<<"$files"; then
    exit 0
fi
exit 1
