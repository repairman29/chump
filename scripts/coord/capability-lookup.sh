#!/usr/bin/env bash
# capability-lookup.sh — query the capability manifest for the best-fit
# session for a given skill (INFRA-1945, slice B of INFRA-1862 A2A mesh).
#
# Reads .chump-locks/capabilities/*.json (written by publish-capability.sh)
# and prints session ids whose skills list contains the requested skill,
# most-recently-updated first. Stale manifests (older than
# CHUMP_CAPABILITY_STALE_MIN, default 60 min) are excluded so a dead
# session's advertised role doesn't win a route it can no longer serve.
#
# Usage:
#   scripts/coord/capability-lookup.sh --skill <skill> [--role <role>]
#
# Exit codes: 0 = at least one match printed, 1 = no match.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
CAP_DIR="$LOCK_DIR/capabilities"
STALE_MIN="${CHUMP_CAPABILITY_STALE_MIN:-60}"

SKILL=""
ROLE_FILTER=""

while :; do
    case "${1:-}" in
        --skill)
            SKILL="${2:-}"; shift 2 ;;
        --role)
            ROLE_FILTER="${2:-}"; shift 2 ;;
        *) break ;;
    esac
done

[[ -n "$SKILL" ]] || { echo "Usage: $0 --skill <skill> [--role <role>]" >&2; exit 1; }

[[ -d "$CAP_DIR" ]] || { echo "[capability-lookup] no capability manifests published yet" >&2; exit 1; }

MATCHES="$(python3 -c "
import json, sys, os, glob, time

cap_dir, skill, role_filter, stale_min = sys.argv[1:5]
now = time.time()
rows = []
for path in glob.glob(os.path.join(cap_dir, '*.json')):
    try:
        with open(path) as f:
            doc = json.load(f)
    except Exception:
        continue
    if skill not in doc.get('skills', []):
        continue
    if role_filter and doc.get('role') != role_filter:
        continue
    try:
        updated = time.strptime(doc['updated_at'], '%Y-%m-%dT%H:%M:%SZ')
        age_min = (now - time.mktime(updated)) / 60.0
    except Exception:
        age_min = float('inf')
    if age_min > float(stale_min):
        continue
    rows.append((age_min, doc['session'], doc.get('role', '')))

rows.sort(key=lambda r: r[0])
for _, session, role in rows:
    print(f'{session}\t{role}')
" "$CAP_DIR" "$SKILL" "$ROLE_FILTER" "$STALE_MIN")"

if [[ -z "$MATCHES" ]]; then
    echo "[capability-lookup] no live session advertises skill=$SKILL${ROLE_FILTER:+ role=$ROLE_FILTER}" >&2
    exit 1
fi

printf '%s\n' "$MATCHES"
