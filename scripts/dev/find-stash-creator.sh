#!/usr/bin/env bash
# find-stash-creator.sh — META-016 — analyze git-stash-trace.log for `claude-*-stash` invocations
#
# Companion to scripts/dev/git-stash-trace-wrapper.sh. Once the wrapper is
# installed and a `claude-other-stash` / `claude-watch-stash` event fires
# again, run this script to print the offending invocation with full
# process ancestry. That should reveal which process is creating these
# stashes.
#
# Usage:
#   scripts/dev/find-stash-creator.sh                    # all matches
#   scripts/dev/find-stash-creator.sh --since 1h         # last 1h only
#   scripts/dev/find-stash-creator.sh --pattern claude   # default match
#   scripts/dev/find-stash-creator.sh --pattern .        # all stash events
#   CHUMP_STASH_TRACE_LOG=/path scripts/dev/find-stash-creator.sh
#
# Output: one human-readable block per match, with timestamp, argv, and
# 5-level ancestry. Most-recent first.

set -u

LOG_FILE="${CHUMP_STASH_TRACE_LOG:-$HOME/.claude/projects/-Users-jeffadkins-Projects-Chump/notes/git-stash-trace.log}"
PATTERN="${PATTERN:-claude-(other|watch)-stash|claude-.*-stash}"
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pattern) PATTERN="$2"; shift 2 ;;
    --since)   SINCE="$2"; shift 2 ;;
    --log)     LOG_FILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#$//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$LOG_FILE" ]; then
  echo "no log file at $LOG_FILE" >&2
  echo "(have you installed scripts/dev/git-stash-trace-wrapper.sh? See its header.)" >&2
  exit 1
fi

# Compute SINCE cutoff if provided. Accept formats like "1h", "30m", "2d".
since_epoch=""
if [ -n "$SINCE" ]; then
  case "$SINCE" in
    *h) hours="${SINCE%h}"; since_epoch=$(($(date +%s) - hours * 3600)) ;;
    *m) mins="${SINCE%m}";  since_epoch=$(($(date +%s) - mins  * 60)) ;;
    *d) days="${SINCE%d}";  since_epoch=$(($(date +%s) - days  * 86400)) ;;
    *)  echo "unrecognized --since '$SINCE'; use 1h / 30m / 2d" >&2; exit 2 ;;
  esac
fi

python3 - "$LOG_FILE" "$PATTERN" "${since_epoch:-0}" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

log_file, pattern, since_epoch = sys.argv[1], sys.argv[2], int(sys.argv[3])
prog = re.compile(pattern)

records = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Filter by SINCE if requested
        if since_epoch:
            try:
                t = datetime.fromisoformat(r["ts"].replace("Z", "+00:00")).timestamp()
                if t < since_epoch:
                    continue
            except (KeyError, ValueError):
                continue
        # Match against argv (anywhere in any arg)
        argv = r.get("argv", [])
        if not any(prog.search(str(a)) for a in argv):
            continue
        records.append(r)

# Print most recent first
records.sort(key=lambda r: r.get("ts", ""), reverse=True)

if not records:
    print(f"no matches for /{pattern}/ in {log_file}", file=sys.stderr)
    sys.exit(1)

print(f"=== {len(records)} match(es) for /{pattern}/ ===\n")

for r in records:
    print(f"  ts:    {r.get('ts', '?')}")
    print(f"  pid:   {r.get('pid', '?')}")
    print(f"  ppid:  {r.get('ppid', '?')}")
    print(f"  argv:  {' '.join(r.get('argv', []))}")
    print(f"  ancestry:")
    for i, a in enumerate(r.get("ancestry", [])):
        indent = "    " + ("  " * i)
        print(f"{indent}[{a.get('pid', '?')}] {a.get('cmd', '?')}")
    print()
PY
