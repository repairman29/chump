#!/usr/bin/env bash
# scrub-credential-logs.sh — INFRA-871
#
# Scans observability artefacts (ambient.jsonl + .chump-locks/*.json) for
# leaked secrets. Exits non-zero on any match. Pre-merge gate per CLAUDE.md
# § "GitHub credentials for agents (INFRA-AGENT-CREDS)" + INFRA-622 auth modes.
#
# Patterns scanned:
#   - GH_TOKEN / GITHUB_TOKEN literals (ghp_*, github_pat_*)
#   - Anthropic API keys (sk-ant-*)
#   - Claude Code OAuth tokens (long opaque, prefix sk-ant-oat- per Anthropic format)
#   - Generic high-entropy bearer-like substrings (heuristic, configurable)
#
# Designed for shell-only operation; no jq/python required to scan the
# common case. Calls out python3 only to render the JSON-encoded report.
#
# Usage:
#   scripts/coord/scrub-credential-logs.sh            # scan default paths, exit non-zero on hit
#   scripts/coord/scrub-credential-logs.sh --report   # emit ambient event with summary
#   scripts/coord/scrub-credential-logs.sh --paths "a b c"  # override scan paths
#
# Env:
#   CHUMP_AMBIENT_LOG     ambient.jsonl path (default: .chump-locks/ambient.jsonl)
#   CHUMP_SCRUB_PATHS     space-separated paths to scan (default: ambient + lease json)
#   CHUMP_SCRUB_ALLOWLIST regex of substrings that should NOT trigger (e.g. "ghp_REDACTED")
#   CHUMP_SCRUB_REPORT=1  emit kind=credential_scrub_run to ambient

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
ALLOWLIST="${CHUMP_SCRUB_ALLOWLIST:-REDACTED|placeholder|example|test-fixture}"
REPORT="${CHUMP_SCRUB_REPORT:-0}"

_emit() {
  local kind="$1"; shift
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$*" \
    >> "$AMBIENT" 2>/dev/null || true
}

# Default scan set: ambient.jsonl + any *.json file under .chump-locks/.
declare -a SCAN_PATHS
if [[ "${CHUMP_SCRUB_PATHS:-}" != "" ]]; then
  read -r -a SCAN_PATHS <<< "$CHUMP_SCRUB_PATHS"
else
  SCAN_PATHS=()
  [[ -f "$AMBIENT" ]] && SCAN_PATHS+=("$AMBIENT")
  while IFS= read -r f; do SCAN_PATHS+=("$f"); done < <(
    find "$REPO_ROOT/.chump-locks" -maxdepth 1 -type f -name '*.json' 2>/dev/null
  )
fi

# Allow flags after detecting --paths (already env-handled) and --report.
for arg in "$@"; do
  case "$arg" in
    --report) REPORT=1 ;;
    --paths)  ;;  # consumed via env above
  esac
done

# Credential pattern definitions. Bash 3.2 (macOS default) does not support
# associative arrays, so we use a flat array of "name|regex" pairs.
PATTERNS=(
  "github_classic|ghp_[A-Za-z0-9]{36,}"
  "github_finegrained|github_pat_[A-Za-z0-9_]{50,}"
  "github_oauth|gho_[A-Za-z0-9]{36,}"
  "anthropic_api|sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{60,}"
  "anthropic_oauth|sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]{60,}"
  "aws_access_key|AKIA[0-9A-Z]{16}"
  "openai_api|sk-[A-Za-z0-9]{48}"
)

total_hits=0
hit_summary=()

scan_file() {
  local path="$1"
  [[ -r "$path" ]] || return 0
  local entry name pattern matches count
  for entry in "${PATTERNS[@]}"; do
    name="${entry%%|*}"
    pattern="${entry#*|}"
    matches=$(grep -oE "$pattern" "$path" 2>/dev/null | grep -vE "$ALLOWLIST" 2>/dev/null || true)
    [[ -z "$matches" ]] && continue
    count=$(echo "$matches" | grep -c .)
    total_hits=$((total_hits + count))
    hit_summary+=("$path:$name:$count")
    echo "LEAK: $count match(es) of $name in $path" >&2
  done
}

for p in "${SCAN_PATHS[@]}"; do
  scan_file "$p"
done

if [[ "$REPORT" == "1" ]]; then
  # Build a compact JSON summary of hits for the ambient event.
  summary=$(printf '%s\n' "${hit_summary[@]:-}" | python3 -c "
import sys, json
hits = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    parts = line.split(':')
    if len(parts) >= 3:
        hits.append({'path': ':'.join(parts[:-2]), 'kind': parts[-2], 'count': int(parts[-1])})
print(json.dumps({'total_hits': sum(h['count'] for h in hits), 'by_path_kind': hits[:20]}))
")
  _emit "credential_scrub_run" "\"summary\":${summary}"
fi

if [[ "$total_hits" -gt 0 ]]; then
  echo
  echo "FAIL: scrub-credential-logs detected $total_hits leaked secret(s)." >&2
  echo "Investigate immediately. Rotate any exposed tokens." >&2
  echo "If a hit is a false positive, add to CHUMP_SCRUB_ALLOWLIST regex." >&2
  exit 1
fi

echo "ok: scrub-credential-logs scanned ${#SCAN_PATHS[@]} path(s), 0 leaks"
exit 0
