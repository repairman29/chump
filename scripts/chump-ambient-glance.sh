#!/usr/bin/env bash
# chump-ambient-glance.sh — INFRA-083: codify the ambient-stream peripheral-vision
# glance at coordination choke points (gap-claim, chump-commit, bot-merge).
#
# Reads .chump-locks/ambient.jsonl and prints (or returns programmatically) the
# recent sibling-session events that overlap with the current operation:
#
#   - INTENT for the same gap        → another agent is starting the same work
#   - file_edit on a claimed path    → another agent is touching your files
#   - commit with the same gap       → another agent already shipped it
#
# Self-exclusion uses the same session-ID priority chain as gap-claim.sh
# (CHUMP_SESSION_ID > CLAUDE_SESSION_ID > .wt-session-id > $HOME).
#
# Usage:
#   scripts/chump-ambient-glance.sh [--gap GAP-ID] [--paths f1,f2,...]
#                                   [--since-secs N] [--limit N]
#                                   [--quiet] [--check-overlap]
#
# Modes:
#   default        — print summary to stderr, exit 0 (advisory)
#   --check-overlap — exit 2 if a sibling has INTENT for the same gap or a
#                    file_edit on a claimed path within the last 60s. Useful
#                    as a hard gate before lease writes / commits.
#
# Bypass: CHUMP_AMBIENT_GLANCE=0 silences all output and exits 0 immediately.

set -euo pipefail

if [[ "${CHUMP_AMBIENT_GLANCE:-1}" == "0" ]]; then
    exit 0
fi

GAP=""
PATHS_CSV=""
SINCE_SECS=600
LIMIT=10
QUIET=0
CHECK_OVERLAP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gap) shift; GAP="${1:-}";;
        --gap=*) GAP="${1#--gap=}";;
        --paths) shift; PATHS_CSV="${1:-}";;
        --paths=*) PATHS_CSV="${1#--paths=}";;
        --since-secs) shift; SINCE_SECS="${1:-600}";;
        --since-secs=*) SINCE_SECS="${1#--since-secs=}";;
        --limit) shift; LIMIT="${1:-10}";;
        --limit=*) LIMIT="${1#--limit=}";;
        --quiet) QUIET=1;;
        --check-overlap) CHECK_OVERLAP=1;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
    shift
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT="$LOCK_DIR/ambient.jsonl"

if [[ ! -f "$AMBIENT" ]]; then
    [[ "$QUIET" == "0" ]] && echo "[ambient-glance] (no ambient stream yet)" >&2
    exit 0
fi

# Resolve current session ID (mirror of gap-claim.sh priority chain).
SELF_SID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SELF_SID" ]] && [[ -f "$LOCK_DIR/.wt-session-id" ]]; then
    SELF_SID="$(cat "$LOCK_DIR/.wt-session-id" 2>/dev/null || true)"
fi
if [[ -z "$SELF_SID" ]] && [[ -f "$HOME/.chump/session_id" ]]; then
    SELF_SID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi

python3 - "$AMBIENT" "$SELF_SID" "$GAP" "$PATHS_CSV" "$SINCE_SECS" "$LIMIT" "$QUIET" "$CHECK_OVERLAP" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

amb, self_sid, gap, paths_csv, since_secs, limit, quiet, check_overlap = sys.argv[1:]
since_secs = int(since_secs); limit = int(limit)
quiet = quiet == "1"; check_overlap = check_overlap == "1"
paths = [p.strip() for p in paths_csv.split(",") if p.strip()]
now = datetime.now(timezone.utc)

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z","+00:00"))
    except Exception:
        return None

# Tail-load — only last ~2000 lines is plenty for a 10-min window.
try:
    with open(amb, "rb") as f:
        f.seek(0, 2); end = f.tell()
        f.seek(max(0, end - 512*1024))
        lines = f.read().decode("utf-8", errors="replace").splitlines()[-2000:]
except OSError:
    sys.exit(0)

hits = []
overlap_intent = False
overlap_edit = False
for line in lines:
    line = line.strip()
    if not line: continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    sid = ev.get("session", "")
    if sid and self_sid and sid == self_sid:
        continue  # self
    ts = parse_ts(ev.get("ts", ""))
    if not ts: continue
    age = (now - ts).total_seconds()
    if age > since_secs: continue
    kind = ev.get("event", "")
    relevant = False; reason = ""
    if gap and kind == "INTENT" and ev.get("gap") == gap:
        relevant = True; reason = f"INTENT for {gap}"
        if age <= 120: overlap_intent = True
    elif gap and kind == "commit" and ev.get("gap") == gap:
        relevant = True; reason = f"committed {gap} ({ev.get('sha','')[:7]})"
    elif kind == "file_edit" and ev.get("path"):
        path = ev.get("path", "")
        bn = os.path.basename(path)
        for p in paths:
            if p in path or bn == os.path.basename(p):
                relevant = True; reason = f"file_edit {bn}"
                if age <= 120: overlap_edit = True
                break
    elif gap and kind == "ALERT":
        relevant = True; reason = f"ALERT {ev.get('kind','')}"
    if relevant:
        hits.append((age, sid, kind, reason, ts.isoformat()))

hits.sort()
if hits and not quiet:
    print(f"[ambient-glance] {len(hits)} sibling event(s) in last {since_secs}s:", file=sys.stderr)
    for age, sid, kind, reason, ts in hits[:limit]:
        sid_short = sid.split("-")[-2] if sid.count("-") >= 2 else sid
        print(f"  [{int(age)}s ago] {sid_short}: {reason}", file=sys.stderr)

if check_overlap and (overlap_intent or overlap_edit):
    if not quiet:
        msg = "INTENT collision" if overlap_intent else "file_edit collision"
        print(f"[ambient-glance] HARD STOP: sibling {msg} within last 120s.", file=sys.stderr)
        print("[ambient-glance] Re-tail .chump-locks/ambient.jsonl and re-plan, or set CHUMP_AMBIENT_GLANCE=0 to bypass.", file=sys.stderr)
    sys.exit(2)

sys.exit(0)
PYEOF
