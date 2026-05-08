#!/usr/bin/env bash
# Extracts all env var names read by Chump's Rust source code.
# Emits a structured markdown list to stdout (or $1 if given).
# Usage: bash scripts/ci/extract-env-vars.sh [output-file]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-}"

emit() { if [[ -n "$OUT" ]]; then printf '%s\n' "$@" >> "$OUT"; else printf '%s\n' "$@"; fi; }

if [[ -n "$OUT" ]]; then truncate -s 0 "$OUT" 2>/dev/null || > "$OUT"; fi

emit "# ENV_VARS_RAW — Chump environment variable audit"
emit ""
emit "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
emit "Source: \`grep -rn 'std::env::var\\|env::var(' src/\`"
emit ""
emit "| Variable | File(s) | Context (comment above call, if any) |"
emit "|----------|---------|--------------------------------------|"

# Collect all env::var calls with file references
grep -rn 'std::env::var\b\|env::var(' "$REPO_ROOT/src/" \
  | grep -oE '[^:]+:[0-9]+:.*"[A-Z][A-Z0-9_]+"' \
  | while IFS= read -r line; do
      file=$(echo "$line" | cut -d: -f1)
      lineno=$(echo "$line" | cut -d: -f2)
      varname=$(echo "$line" | grep -oE '"[A-Z][A-Z0-9_]+"' | head -1 | tr -d '"')
      relfile="${file#"$REPO_ROOT/"}"
      echo "$varname|$relfile:$lineno"
  done \
  | sort -u \
  | awk -F'|' '
    {
      var=$1; loc=$2
      if (var != prev) {
        if (prev != "") printf "| %-55s | %-60s | %-40s |\n", prev, locs, ""
        prev=var; locs=loc
      } else {
        locs=locs ", " loc
      }
    }
    END { if (prev != "") printf "| %-55s | %-60s | %-40s |\n", prev, locs, "" }
  ' \
  | while IFS= read -r row; do emit "$row"; done

emit ""
emit "## Summary"
total=$(grep -rn 'std::env::var\b\|env::var(' "$REPO_ROOT/src/" \
  | grep -oE '"[A-Z][A-Z0-9_]+"' | tr -d '"' | sort -u | wc -l | tr -d ' ')
emit "Total unique env vars referenced in src/: **$total**"
