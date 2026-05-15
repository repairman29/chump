#!/usr/bin/env bash
# scripts/coord/reach-classifier.sh — INFRA-1299
#
# Decides which delivery channels an a2a event should fire on, based on
# its urgency field + (future, INFRA-1300) operator filter rules.
#
# Input: JSON event on stdin OR --event '<json>' arg.
# Output: JSON {channels: [...]} on stdout.
#
# Channels (current Phase 1):
#   inbox  — always (audit trail; the event already landed there via broadcast.sh)
#   toast  — in-app PWA toast (PRODUCT-105 will subscribe via SSE)
#   push   — out-of-app Web Push (INFRA-1301; not yet wired)
#   digest — included in daily digest (INFRA-1302; default channel for low-urgency)
#
# Default urgency by event-kind (when input omits urgency):
#   ALERT       → now
#   STUCK       → hours
#   HANDOFF     → hours
#   FEEDBACK retro → digest
#   everything else → hours
#
# Phase 1 rules (hardcoded; INFRA-1300 will load .chump/operator-rules.yaml):
#   urgency=now    → [inbox, toast, push]
#   urgency=hours  → [inbox, toast]
#   urgency=digest → [inbox, digest]

set -uo pipefail

EVENT_JSON=""
while [ $# -gt 0 ]; do
    case "$1" in
        --event) EVENT_JSON="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[reach-classifier] unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$EVENT_JSON" ] && [ -t 0 ]; then
    echo "[reach-classifier] no event input (stdin tty + no --event); pass via stdin or --event" >&2
    exit 2
fi

if [ -z "$EVENT_JSON" ]; then
    EVENT_JSON="$(cat)"
fi

python3 -c "
import json, sys

raw = sys.argv[1] if len(sys.argv) > 1 else ''
try:
    e = json.loads(raw)
except Exception as exc:
    print(f'[reach-classifier] invalid JSON: {exc}', file=sys.stderr)
    sys.exit(2)

event = e.get('event', '').upper()
kind = (e.get('kind') or '').lower()

# Resolve urgency: explicit field wins; else derive from event/kind.
urgency = (e.get('urgency') or '').lower()
if not urgency:
    if event == 'ALERT':
        urgency = 'now'
    elif event in ('STUCK', 'HANDOFF'):
        urgency = 'hours'
    elif event == 'FEEDBACK' and kind == 'retro':
        urgency = 'digest'
    else:
        urgency = 'hours'

if urgency not in ('now', 'hours', 'digest'):
    urgency = 'hours'

if urgency == 'now':
    channels = ['inbox', 'toast', 'push']
elif urgency == 'hours':
    channels = ['inbox', 'toast']
else:
    channels = ['inbox', 'digest']

print(json.dumps({'urgency': urgency, 'channels': channels}))
" "$EVENT_JSON"
