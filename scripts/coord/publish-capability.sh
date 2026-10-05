#!/usr/bin/env bash
# publish-capability.sh — role/skill capability manifest (INFRA-1945, slice B
# of INFRA-1862 A2A mesh).
#
# Each curator/agent session publishes its role + skills to a known file-KV
# so routers can dispatch by skill match instead of "whoever claimed first".
# Manifest lives at .chump-locks/capabilities/<session>.json and is
# refreshed by re-running this script (last-write-wins, no lease needed —
# it's advisory metadata, not a claim).
#
# Usage:
#   scripts/coord/publish-capability.sh --role <role> --skills a,b,c [--session <id>]
#
# Example:
#   scripts/coord/publish-capability.sh --role curator-opus-ci-audit \
#     --skills rust,docs,sql,a2a
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
CAP_DIR="$LOCK_DIR/capabilities"

SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
SESSION_ID="${SESSION_ID:-$(cat "$HOME/.chump/session_id" 2>/dev/null || true)}"

ROLE=""
SKILLS=""

while :; do
    case "${1:-}" in
        --role)
            ROLE="${2:-}"; shift 2 ;;
        --skills)
            SKILLS="${2:-}"; shift 2 ;;
        --session)
            SESSION_ID="${2:-}"; shift 2 ;;
        *) break ;;
    esac
done

[[ -n "$ROLE" ]] || { echo "Usage: $0 --role <role> --skills a,b,c [--session <id>]" >&2; exit 1; }
[[ -n "$SESSION_ID" ]] || { echo "$0: no session id — set CHUMP_SESSION_ID or pass --session" >&2; exit 1; }

mkdir -p "$CAP_DIR"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 -c "
import json, sys
skills = [s.strip() for s in sys.argv[3].split(',') if s.strip()]
doc = {
    'session': sys.argv[1],
    'role': sys.argv[2],
    'skills': skills,
    'updated_at': sys.argv[4],
}
print(json.dumps(doc))
" "$SESSION_ID" "$ROLE" "$SKILLS" "$TS" > "$CAP_DIR/$SESSION_ID.json"

printf '[publish-capability] session=%s role=%s skills=%s\n' "$SESSION_ID" "$ROLE" "$SKILLS"
