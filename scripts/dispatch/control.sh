#!/usr/bin/env bash
# control.sh — INFRA-203: live status pane for the fleet.
#
# Spawned by run-fleet.sh as pane 0. Cheap, read-only loop showing:
#   • ambient.jsonl tail (last 10 events)
#   • PR queue depth (`gh pr list` count)
#   • per-agent current gap (parsed from .chump-locks/*.json)
#
# Refreshes every REFRESH_S seconds (default 5). Ctrl-C exits the pane only.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FLEET_SESSION="${FLEET_SESSION:-chump-fleet}"
FLEET_SIZE="${FLEET_SIZE:-?}"
REFRESH_S="${REFRESH_S:-5}"

cd "$REPO_ROOT"

trap 'echo; echo "[control] bye."; exit 0' INT TERM

while :; do
    clear
    printf '\033[1mchump fleet — session=%s  size=%s  refresh=%ss\033[0m\n' \
        "$FLEET_SESSION" "$FLEET_SIZE" "$REFRESH_S"
    printf '%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo

    # PR queue depth
    echo "── PRs (open, head=chump/*) ─────────────────────────────────"
    if command -v gh >/dev/null 2>&1; then
        gh pr list --state open --search 'head:chump/' \
            --json number,title,headRefName,statusCheckRollup \
            --template '{{range .}}#{{.number}}  {{.headRefName}}  {{.title}}{{"\n"}}{{end}}' \
            2>/dev/null | head -10 || echo "  (gh pr list failed)"
    else
        echo "  (gh CLI not on PATH)"
    fi
    echo

    # Active leases
    echo "── Active leases (.chump-locks/*.json) ──────────────────────"
    leases=$(ls "$REPO_ROOT/.chump-locks/"*.json 2>/dev/null || true)
    if [ -z "$leases" ]; then
        echo "  (none)"
    else
        for f in $leases; do
            python3 -c "
import json,sys,os
try: d=json.load(open('$f'))
except Exception: sys.exit(0)
gid = d.get('gap_id') or (d.get('pending_new_gap') or {}).get('id') or '?'
sid = d.get('session_id','?')
exp = d.get('expires_at','?')
print(f'  {gid:18s}  session={sid[:30]:30s}  expires={exp}')
" 2>/dev/null
        done
    fi
    echo

    # Ambient tail
    echo "── Ambient stream (last 10) ─────────────────────────────────"
    if [ -f "$REPO_ROOT/.chump-locks/ambient.jsonl" ]; then
        tail -10 "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null \
            | python3 -c "
import json,sys
for line in sys.stdin:
    try: e=json.loads(line)
    except Exception: continue
    ts = (e.get('ts') or '')[:19]
    kind = e.get('kind','?')
    sid = (e.get('session_id') or '')[:24]
    extra = ''
    for k in ('gap','path','sha','msg'):
        if e.get(k):
            extra = f' {k}={e[k]}'
            break
    print(f'  {ts}  {kind:14s}  {sid:24s}{extra}')
" 2>/dev/null
    else
        echo "  (no ambient stream yet)"
    fi
    echo

    sleep "$REFRESH_S"
done
