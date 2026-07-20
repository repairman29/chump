#!/usr/bin/env bash
# scripts/dev/role-card-query.sh — INFRA-2017 (RCA Change 2 follow-up)
#
# Reads the tail of ambient.jsonl for kind=role_card events, dedupes by
# session_id (the physical Claude Code session, NOT alias-name — a single
# session can hold multiple curator aliases across a shift), and prints the
# LATEST role-card per physical session. Peers use this for dispatch dedup
# so they don't double-dispatch to a session already inhabiting the target
# lane under a different alias.
#
# Usage:
#   scripts/dev/role-card-query.sh [--session <id>] [--lines N]
#
# Output: one JSON object per physical session, newest role_card event per
# session_id, one per line.
#
# Environment:
#   CHUMP_AMBIENT_LOG  override the log path (default: <repo>/.chump-locks/ambient.jsonl)

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

FILTER_SESSION=""
TAIL_LINES=2000

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session) FILTER_SESSION="${2:-}"; shift 2 ;;
        --lines)   TAIL_LINES="${2:-2000}"; shift 2 ;;
        --help|-h)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ ! -f "$AMBIENT" ]]; then
    echo "[role-card-query] No ambient log found at $AMBIENT" >&2
    exit 0
fi

tail -n "$TAIL_LINES" "$AMBIENT" 2>/dev/null \
    | grep -- '"kind":"role_card"' \
    | python3 -c '
import sys, json

filter_session = sys.argv[1] if len(sys.argv) > 1 else ""
latest = {}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("kind") != "role_card":
        continue
    sid = ev.get("session_id")
    if not sid:
        continue
    if filter_session and sid != filter_session:
        continue
    # tail is chronological, so the last one seen per session_id wins
    latest[sid] = ev

for sid in latest:
    print(json.dumps(latest[sid]))
' "$FILTER_SESSION"
