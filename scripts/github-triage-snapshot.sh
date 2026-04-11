#!/usr/bin/env bash
# W3.1 — Read-only GitHub triage snapshot: open issues as Markdown for COS / Farmer Brown.
# Requires: gh CLI, GITHUB_TOKEN if the repo is private.
#
# Usage:
#   CHUMP_TRIAGE_REPO=owner/name ./scripts/github-triage-snapshot.sh
#   ./scripts/github-triage-snapshot.sh owner/name
#
# Optional: CHUMP_TRIAGE_LIMIT (default 25), CHUMP_TRIAGE_LABEL (gh --label),
#           CHUMP_TRIAGE_OUT=path.md (write file; else stdout)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${1:-${CHUMP_TRIAGE_REPO:-}}"
LIMIT="${CHUMP_TRIAGE_LIMIT:-25}"
LABEL="${CHUMP_TRIAGE_LABEL:-}"

if [[ -z "$REPO" ]]; then
  echo "usage: CHUMP_TRIAGE_REPO=owner/name $0   or   $0 owner/name" >&2
  exit 1
fi

command -v gh >/dev/null || { echo "FAIL: gh not in PATH" >&2; exit 1; }

cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

args=(issue list --repo "$REPO" --state open --limit "$LIMIT" --json number,title,labels,url,createdAt)
if [[ -n "$LABEL" ]]; then
  args+=(--label "$LABEL")
fi

json=$(gh "${args[@]}") || { echo "FAIL: gh issue list for $REPO" >&2; exit 1; }

render() {
  echo "# GitHub triage snapshot: \`$REPO\`"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) (UTC)"
  echo
  if command -v jq >/dev/null; then
    local sorted
    sorted=$(echo "$json" | jq -c 'sort_by(-.number)')
    echo "| # | Title | Labels | Created | URL |"
    echo "|---|-------|--------|---------|-----|"
    echo "$sorted" | jq -r '.[] | "| \(.number) | \(.title | gsub("\\|"; "/")) | \(.labels // [] | map(.name) | join(", ")) | \(.createdAt) | \(.url) |"'
    echo
    echo "## Task stubs (for task tool / \`[COS]\`)"
    echo
    echo "$sorted" | jq -r '.[] | "- [ ] [COS] gh #\(.number): \(.title | gsub("\\|"; "/")) — \(.url)"' | head -n 15
  else
    echo "(Install \`jq\` for Markdown table; raw JSON below.)"
    echo
    echo "$json"
  fi
}

if [[ -n "${CHUMP_TRIAGE_OUT:-}" ]]; then
  render > "$CHUMP_TRIAGE_OUT"
  echo "Wrote $CHUMP_TRIAGE_OUT" >&2
else
  render
fi
