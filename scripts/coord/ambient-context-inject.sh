#!/usr/bin/env bash
# ambient-context-inject.sh — FLEET-020
#
# Wired into Claude Code SessionStart and PreToolUse hooks by FLEET-022. Reads
# .chump-locks/ambient.jsonl + active lease files and emits a compact summary
# as Claude Code hook JSON so the agent's first token is already aware of
# sibling sessions, recent commits, and ALERT events — without having to
# remember the manual `tail -30` step in CLAUDE.md.
#
# Output is one of:
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}
# (whichever the hook is configured for; passed via $1, defaults to SessionStart)
#
# Environment:
#   CHUMP_AMBIENT_INJECT_N  number of events to tail (default: 30 SessionStart, 10 PreToolUse)
#   CHUMP_AMBIENT_INJECT=0  disable (emits empty additionalContext)
#   CHUMP_AMBIENT_LOG       override ambient.jsonl path
#   CHUMP_AMBIENT_DEBUG=1   echo the rendered context to stderr

set -euo pipefail

HOOK_EVENT="${1:-SessionStart}"

# ── Resolve repo + lock dir (same logic as ambient-emit.sh) ────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

# Default tail length depends on hook
default_n=30
[[ "$HOOK_EVENT" == "PreToolUse" ]] && default_n=10
N="${CHUMP_AMBIENT_INJECT_N:-$default_n}"

emit_empty() {
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":""}}\n' "$HOOK_EVENT"
    exit 0
}

# Resolve our session ID so we can hide our own events from the digest
# (also used by the session_start emit below — must be set before the
# kill switch / missing-log short-circuits so first-ever invocations
# still produce the event).
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]] && [[ -f "$REPO_ROOT/.chump-locks/.wt-session-id" ]]; then
    SESSION_ID="$(cat "$REPO_ROOT/.chump-locks/.wt-session-id" 2>/dev/null || true)"
fi

# ── INFRA-102: emit session_start on the SessionStart hook ───────────────────
# CLAUDE.md advertises session_start as one of the ambient.jsonl event kinds
# agents pick up via peripheral vision. The 2026-04-26 audit found a 50-row
# tail with zero session_start events: FLEET-019/022 wired session_end on the
# Stop hook (ambient-session-end.sh) but never wired the symmetric
# session_start emit on the SessionStart hook. This block restores the
# emitter (best-effort, mirrors ambient-session-end.sh).
#
# Runs *before* the CHUMP_AMBIENT_INJECT=0 kill switch and the
# missing-log short-circuit so the event still lands when (a) context
# injection is disabled but agents still want session-start visibility, and
# (b) ambient.jsonl doesn't yet exist (ambient-emit.sh creates it on append).
# Bypass with CHUMP_AMBIENT_SESSION_START_EMIT=0.
if [[ "$HOOK_EVENT" == "SessionStart" ]] \
        && [[ "${CHUMP_AMBIENT_SESSION_START_EMIT:-1}" != "0" ]] \
        && [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
    CHUMP_SESSION_ID="$SESSION_ID" \
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" session_start 2>/dev/null || true
fi

# Kill switch
[[ "${CHUMP_AMBIENT_INJECT:-1}" == "0" ]] && emit_empty
[[ ! -f "$AMBIENT_LOG" ]] && emit_empty

# ── Build the digest in Python (proper JSON parsing + escaping) ───────────────
CONTEXT="$(
    AMBIENT_LOG="$AMBIENT_LOG" \
    LOCK_DIR="$LOCK_DIR" \
    SESSION_ID="$SESSION_ID" \
    HOOK_EVENT="$HOOK_EVENT" \
    N="$N" \
    python3 - <<'PY'
import json, os, sys, time
from pathlib import Path
from datetime import datetime, timezone

ambient = Path(os.environ["AMBIENT_LOG"])
lock_dir = Path(os.environ["LOCK_DIR"])
session_id = os.environ.get("SESSION_ID", "")
hook = os.environ["HOOK_EVENT"]
n = int(os.environ.get("N", "30"))

# Tail last 4096 lines, filter to last n events, parse each as JSON.
lines: list[str] = []
try:
    with ambient.open("rb") as f:
        f.seek(0, 2)
        size = f.tell()
        chunk = 64 * 1024
        buf = b""
        while size > 0 and buf.count(b"\n") < n + 200:
            read = min(chunk, size)
            f.seek(size - read)
            buf = f.read(read) + buf
            size -= read
        lines = buf.decode("utf-8", errors="replace").splitlines()
except Exception:
    lines = []

events = []
for line in lines[-(n + 200):]:
    line = line.strip()
    if not line:
        continue
    try:
        events.append(json.loads(line))
    except Exception:
        continue
events = events[-n:]

# Active leases (exclude ours)
leases = []
for p in sorted(lock_dir.glob("*.json")):
    try:
        data = json.loads(p.read_text())
        if data.get("session_id") == session_id:
            continue
        leases.append(data)
    except Exception:
        continue

# ALERT events from the last 30 min
now_ts = time.time()
alerts = []
for e in events:
    if e.get("event") == "ALERT" or e.get("kind") == "ALERT":
        ts = e.get("ts", "")
        try:
            event_ts = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            if now_ts - event_ts < 30 * 60:
                alerts.append(e)
        except Exception:
            alerts.append(e)

# Sibling sessions in the digest window (exclude ours)
siblings = {}
for e in events:
    s = e.get("session", "")
    if not s or s == session_id:
        continue
    siblings.setdefault(s, {"count": 0, "last_event": "", "last_ts": "", "worktree": e.get("worktree", "")})
    siblings[s]["count"] += 1
    siblings[s]["last_event"] = e.get("event", "")
    siblings[s]["last_ts"] = e.get("ts", "")

# Render compact context block
lines_out = []
lines_out.append("=== Ambient stream (FLEET-019 matrix wiring, hook=" + hook + ") ===")
lines_out.append(
    f"Window: last {len(events)} events from .chump-locks/ambient.jsonl  |  "
    f"siblings: {len(siblings)}  |  active leases: {len(leases)}  |  alerts(30m): {len(alerts)}"
)

if alerts:
    lines_out.append("")
    lines_out.append("ALERTS (last 30 min) — read before claiming/editing:")
    for a in alerts[-5:]:
        kind = a.get("kind") or a.get("subkind") or a.get("event")
        note = a.get("note") or a.get("msg") or ""
        sess = a.get("session", "?")
        lines_out.append(f"  - [{a.get('ts','?')}] {kind} session={sess} note={note[:120]}")

if leases:
    lines_out.append("")
    lines_out.append("Active sibling leases (do NOT collide):")
    for l in leases:
        gap = l.get("gap_id") or l.get("purpose") or "?"
        sess = l.get("session_id", "?")
        exp = l.get("expires_at", "?")
        paths = l.get("paths") or []
        path_str = "" if not paths else f"  paths={','.join(paths[:3])}"
        lines_out.append(f"  - {gap}  session={sess}  expires={exp}{path_str}")

if siblings:
    lines_out.append("")
    lines_out.append("Recent sibling activity:")
    for s, info in sorted(siblings.items(), key=lambda kv: kv[1]["last_ts"], reverse=True)[:5]:
        lines_out.append(
            f"  - {s} (worktree={info['worktree']}, {info['count']} events, last={info['last_event']} @ {info['last_ts']})"
        )

# Last few events themselves (for direct visibility on commits / file_edits)
recent_meaningful = [
    e for e in events
    if e.get("event") in ("commit", "file_edit", "ALERT", "INTENT", "session_start")
       and e.get("session") != session_id
]
if recent_meaningful:
    lines_out.append("")
    lines_out.append("Recent meaningful events:")
    for e in recent_meaningful[-8:]:
        kind = e.get("event", "?")
        ts = e.get("ts", "?")
        if kind == "commit":
            tag = f"sha={e.get('sha','?')[:8]} gap={e.get('gap','?')} msg={(e.get('msg','') or '')[:60]}"
        elif kind == "file_edit":
            tag = f"path={e.get('path','?')}"
        elif kind == "INTENT":
            tag = f"gap={e.get('gap','?')}"
        else:
            tag = e.get("note") or e.get("msg") or ""
        lines_out.append(f"  - [{ts}] {kind} {tag}"[:200])

lines_out.append("")
lines_out.append(
    "Tap into the matrix: `tail -50 .chump-locks/ambient.jsonl` for raw stream; "
    "`chump-coord watch` for cross-machine NATS view (FLEET-006). "
    "If you need to act on shared state, re-check this digest before commit/ship."
)

context = "\n".join(lines_out)
out = {
    "hookSpecificOutput": {
        "hookEventName": hook,
        "additionalContext": context,
    }
}
sys.stdout.write(json.dumps(out))
PY
)"

if [[ "${CHUMP_AMBIENT_DEBUG:-0}" == "1" ]]; then
    printf '%s\n' "$CONTEXT" >&2
fi

printf '%s\n' "$CONTEXT"
