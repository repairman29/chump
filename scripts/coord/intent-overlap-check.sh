#!/usr/bin/env bash
# intent-overlap-check.sh — Refuse a claim when another live session has
# active INTENT on overlapping paths (INFRA-1116).
#
# The protocol has been documented in broadcast.sh's header for months:
#   "Agents should check ambient.jsonl for INTENT events from the last 5
#    minutes before claiming a gap."
# This script ENFORCES the protocol mechanically instead of relying on
# voluntary discipline. INFRA-779 worktree corruption + multi-agent
# concurrent-shipping races (observed ≥5 times in one day) trace back to
# the gate not being enforced.
#
# Usage:
#   intent-overlap-check.sh <gap-id> [<paths-csv-or-glob-csv>]
#
# Exit codes:
#   0   No overlapping live INTENT — caller may proceed
#   14  Overlapping INTENT found — caller should abort or coordinate
#   2   Bad usage
#
# Environment:
#   CHUMP_CLAIM_INTENT_WINDOW_S       — how far back to scan (default 60s)
#   CHUMP_CLAIM_FORCE_OVERLAP=1       — bypass with audit-log entry
#   CHUMP_CLAIM_OVERRIDE_REASON=<txt> — reason for the bypass (required when forcing)
#   CHUMP_LOCK_DIR                    — override .chump-locks path (tests)
#
# Output (stderr) on overlap:
#   [intent-gate] OVERLAP: session X has active INTENT on paths {a,b} (intersect: {b})
#   [intent-gate]   X's lease: .chump-locks/X.json  expires_at=...
#   [intent-gate]   Suggested next steps:
#   [intent-gate]     wait — re-run preflight after 60s
#   [intent-gate]     mailbox-ping — broadcast.sh --to X ALERT kind=overlap "..."
#   [intent-gate]     force-override — CHUMP_CLAIM_FORCE_OVERLAP=1 CHUMP_CLAIM_OVERRIDE_REASON='<text>' chump claim ...
#
# Emits to ambient.jsonl:
#   kind=intent_overlap_detected  (on every refusal)
#   kind=intent_overlap_overridden (when CHUMP_CLAIM_FORCE_OVERLAP=1 used; with reason)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT="$LOCK_DIR/ambient.jsonl"
WINDOW_S="${CHUMP_CLAIM_INTENT_WINDOW_S:-60}"

usage() {
    echo "Usage: $0 <gap-id> [<paths-csv>]" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
GAP_ID="$1"
PATHS_CSV="${2:-}"
SELF_SESSION="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

# Resolve own session for self-skip (own INTENTs shouldn't block own claim).
if [[ -z "$SELF_SESSION" && -f "$LOCK_DIR/.wt-session-id" ]]; then
    SELF_SESSION="$(cat "$LOCK_DIR/.wt-session-id" 2>/dev/null || true)"
fi

emit_event() {
    local kind="$1" extra_fields="$2"
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s","session":"%s","gap":"%s","paths":"%s"%s}\n' \
        "$ts" "$kind" "$SELF_SESSION" "$GAP_ID" "$PATHS_CSV" "$extra_fields" \
        >> "$AMBIENT" 2>/dev/null || true
}

# Operator override path — record audit log and pass.
if [[ "${CHUMP_CLAIM_FORCE_OVERLAP:-0}" == "1" ]]; then
    REASON="${CHUMP_CLAIM_OVERRIDE_REASON:-(no reason given)}"
    emit_event "intent_overlap_overridden" ",\"reason\":\"$REASON\""
    printf '[intent-gate] OVERRIDE: CHUMP_CLAIM_FORCE_OVERLAP=1 — bypassing overlap check (reason: %s)\n' "$REASON" >&2
    exit 0
fi

[[ -f "$AMBIENT" ]] || exit 0   # no ambient yet → no overlaps to check

# Pythonic core: parse ambient.jsonl tail, filter to INTENT events in window,
# filter to live sessions, compute path overlap, emit details.
python3 - "$AMBIENT" "$LOCK_DIR" "$WINDOW_S" "$GAP_ID" "$PATHS_CSV" "${SELF_SESSION:-}" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone, timedelta

amb_path, lock_dir, window_s, gap_id, paths_csv, self_session = sys.argv[1:7]
window_s = int(window_s)
my_paths = [p.strip() for p in paths_csv.split(',') if p.strip()]
cutoff = datetime.now(timezone.utc) - timedelta(seconds=window_s)

# Walk ambient backwards, collect recent INTENT events.
events = []
try:
    with open(amb_path) as f:
        # Read the whole file — typically < 1MB; tail-optimized later.
        for line in f:
            line = line.strip()
            if not line:
                continue
            if '"event":"INTENT"' not in line and '"event": "INTENT"' not in line:
                continue
            try:
                evt = json.loads(line)
            except Exception:
                continue
            if evt.get('event') != 'INTENT':
                continue
            try:
                ts = datetime.fromisoformat(evt.get('ts', '').replace('Z', '+00:00'))
            except Exception:
                continue
            if ts < cutoff:
                continue
            events.append(evt)
except FileNotFoundError:
    sys.exit(0)

# Filter to OTHER sessions only.
events = [e for e in events if e.get('session') != self_session]

def lease_alive(session):
    p = os.path.join(lock_dir, f"{session}.json")
    if not os.path.exists(p):
        return False
    try:
        with open(p) as f:
            lease = json.load(f)
        exp = lease.get('expires_at', '')
        if not exp:
            return True
        exp_dt = datetime.fromisoformat(exp.replace('Z', '+00:00'))
        return exp_dt > datetime.now(timezone.utc)
    except Exception:
        return False

def paths_overlap(my, theirs):
    """Path overlap = any of my paths is a prefix of any of theirs (or vice versa),
    OR the paths are exactly equal (after stripping trailing /)."""
    if not my or not theirs:
        # Without declared paths on at least one side, we can't compute a
        # meaningful overlap. v0 default: NO overlap (don't block undeclared
        # claims; opt-in via --paths is the protected case). Future
        # tightening can change this default once most agents declare paths.
        return False
    norm = lambda p: p.rstrip('/')
    my = [norm(p) for p in my]
    th = [norm(p) for p in theirs]
    for a in my:
        for b in th:
            if a == b or a.startswith(b + '/') or b.startswith(a + '/'):
                return True
    return False

overlaps = []
for e in events:
    if not lease_alive(e.get('session', '')):
        continue
    their_paths = [p.strip() for p in (e.get('files') or '').split(',') if p.strip()]
    if paths_overlap(my_paths, their_paths):
        overlaps.append({
            'session': e.get('session', ''),
            'their_paths': their_paths,
            'their_gap': e.get('gap', ''),
            'their_ts': e.get('ts', ''),
        })

if not overlaps:
    sys.exit(0)

# Print structured refusal + suggested next steps.
print("[intent-gate] OVERLAP detected — refusing claim", file=sys.stderr)
for o in overlaps:
    print(f"[intent-gate]   session={o['session']}", file=sys.stderr)
    print(f"[intent-gate]     gap={o['their_gap']}  paths={','.join(o['their_paths']) or '(unspecified)'}", file=sys.stderr)
    print(f"[intent-gate]     announced={o['their_ts']}", file=sys.stderr)
print(f"[intent-gate]   my paths: {','.join(my_paths) or '(unspecified)'}", file=sys.stderr)
print(f"[intent-gate] Next steps:", file=sys.stderr)
print(f"[intent-gate]   wait — re-run preflight after {window_s}s (their INTENT may expire)", file=sys.stderr)
print(f"[intent-gate]   ping — scripts/coord/broadcast.sh --to {overlaps[0]['session']} ALERT kind=overlap '<message>'", file=sys.stderr)
print(f"[intent-gate]   force — CHUMP_CLAIM_FORCE_OVERLAP=1 CHUMP_CLAIM_OVERRIDE_REASON='<text>' chump claim ...", file=sys.stderr)

# Emit ambient event for fleet-status / waste-tally.
ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
amb_dir = os.path.dirname(amb_path)
os.makedirs(amb_dir, exist_ok=True)
with open(amb_path, 'a') as f:
    f.write(json.dumps({
        'ts': ts,
        'kind': 'intent_overlap_detected',
        'session': self_session,
        'gap': gap_id,
        'my_paths': my_paths,
        'conflicting': [{'session': o['session'], 'paths': o['their_paths'], 'gap': o['their_gap']} for o in overlaps],
    }) + '\n')

sys.exit(14)
PY
