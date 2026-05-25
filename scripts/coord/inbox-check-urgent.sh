#!/usr/bin/env bash
# scripts/coord/inbox-check-urgent.sh — INFRA-2016 (the real keystone)
#
# Reads the GLOBAL urgent inbox (.chump-locks/URGENT-INBOX.jsonl) that
# every agent's PostToolUse hook checks, regardless of session resolution.
#
# Why a global inbox?
#   Investigation 2026-05-25T19:40Z found 8 of 10 curators with non-empty
#   inbox files had NEVER read them — cursor=empty. The existing inbox-poll
#   (INFRA-1860) only fires when an agent's CHUMP_SESSION_ID matches an
#   inbox file. Most curator sessions are operator-spawned standalone
#   Claude windows without CHUMP_SESSION_ID. So their session-keyed inbox
#   never gets polled. Messages were correctly delivered + dead-lettered.
#
# The fix: CRIT/EMERGENCY messages go to a GLOBAL inbox file. Every
# agent's hook reads from it. Bypasses session-resolution for the
# class of messages that MUST get through.
#
# Output format (when global urgent inbox has unread):
#   <system-reminder>
#   ** INBOX URGENT (INFRA-2016 global) **
#   <inbox-interrupt urgency="..." from="..." ts="...">
#   body
#   </inbox-interrupt>
#   </system-reminder>
#
# State: .chump-locks/URGENT-INBOX.cursor stores byte offset
#
# Performance: <50ms on cold cache (single file stat + grep). Safe to
# call on every PostToolUse.

set -uo pipefail

if [[ "${CHUMP_INBOX_URGENT_DISABLE:-0}" == "1" ]]; then
    exit 0
fi

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
URGENT_INBOX="$REPO_ROOT/.chump-locks/URGENT-INBOX.jsonl"
CURSOR="$REPO_ROOT/.chump-locks/URGENT-INBOX.cursor"

[[ -f "$URGENT_INBOX" ]] || exit 0  # no global urgent inbox = nothing to do

# Read cursor
LAST=0
[[ -f "$CURSOR" ]] && LAST="$(cat "$CURSOR" 2>/dev/null | head -1 | xargs)"
LAST="${LAST:-0}"

SIZE="$(wc -l < "$URGENT_INBOX" | xargs)"
[[ "$SIZE" -le "$LAST" ]] && exit 0  # no new urgent messages

# Read new messages
NEW="$(tail -n +"$((LAST + 1))" "$URGENT_INBOX" 2>/dev/null)"
[[ -z "$NEW" ]] && exit 0

# Format as system-reminder for Claude Code to surface
echo "<system-reminder>"
echo "** INBOX URGENT (INFRA-2016 global) **"
echo "** This message was sent with urgency=CRIT or EMERGENCY. It bypasses"
echo "** session-keyed inboxes via the global urgent channel. Read + reply if it"
echo "** concerns your work; cursor will advance so you won't see it again."
echo ""
echo "$NEW" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.rstrip()
    if not line: continue
    try: o = json.loads(line)
    except: continue
    if not isinstance(o, dict): continue
    u = o.get("urgency","CRIT")
    sender = o.get("from") or o.get("session","unknown")
    ts = o.get("ts","")
    to = o.get("to","fleet-wide")
    body = (o.get("body") or o.get("reason") or o.get("gap") or "").strip()
    body = body.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
    print(f"<inbox-interrupt urgency=\"{u}\" from=\"{sender}\" to=\"{to}\" ts=\"{ts}\">")
    print(body)
    print("</inbox-interrupt>")
' 2>/dev/null
echo "</system-reminder>"

# Advance cursor
echo "$SIZE" > "$CURSOR.tmp" && mv "$CURSOR.tmp" "$CURSOR"

# Audit
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
COUNT="$(echo "$NEW" | wc -l | xargs)"
printf '{"ts":"%s","kind":"inbox_urgent_surfaced","source":"inbox_check_urgent","messages":%d,"new_cursor":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$COUNT" "$SIZE" \
    >> "$AMBIENT" 2>/dev/null || true

exit 0
