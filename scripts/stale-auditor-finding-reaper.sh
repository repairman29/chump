#!/usr/bin/env bash
# stale-auditor-finding-reaper.sh — auto-close auditor-filed gaps that no human
# has engaged with in N days.
#
# Why: the nightly auditor will accumulate gaps that nobody acts on. If a
# finding has been open 30 days without movement, it is either (a) not actually
# important, or (b) the check is too noisy. Either way, closing it forces a
# decision: if the check still flags the same problem, a fresh gap will be
# filed (the strike-count clock keeps ticking — at the 5-strike threshold the
# next filing will be flagged for manual P1 escalation).
#
# Auditor-filed gaps are looked up via .chump/auditor-strikes.json, the same
# dedup index file-findings.sh writes. We treat a gap as "stale" if its
# `created_at` is older than $THRESHOLD_DAYS days (we approximate "no
# engagement" by created_at alone — chump's gap list does not yet expose
# updated_at / comment activity).
#
# Default threshold: 30 days. Override with CHUMP_AUDITOR_REAPER_DAYS.
# Default mode: --dry-run (logs what would be closed). Pass --execute to flip.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

DRY_RUN=1
THRESHOLD_DAYS="${CHUMP_AUDITOR_REAPER_DAYS:-30}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute) DRY_RUN=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --days) THRESHOLD_DAYS="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[%s] auditor-reaper: %s\n' "$(ts)" "$*"; }

STRIKES_FILE=".chump/auditor-strikes.json"
if [ ! -f "$STRIKES_FILE" ]; then
    log "no $STRIKES_FILE — nothing to reap"
    exit 0
fi

GAPS_JSON="$(mktemp)"
TMP="$(mktemp)"
trap 'rm -f "$GAPS_JSON" "$TMP"' EXIT

chump gap list --json 2>/dev/null >"$GAPS_JSON" || echo '[]' >"$GAPS_JSON"

THRESHOLD_DAYS="$THRESHOLD_DAYS" python3 - "$STRIKES_FILE" "$GAPS_JSON" >"$TMP" <<'PY'
import os, sys, json
from datetime import date, datetime
threshold = int(os.environ['THRESHOLD_DAYS'])
today = date.today()

with open(sys.argv[1]) as f:
    strikes = json.load(f)
with open(sys.argv[2]) as f:
    gaps = {g['id']: g for g in json.load(f)}

# Build the inverse: gap_id -> finding_key (so we can report which check filed it).
gap_to_key = {}
for k, e in strikes.items():
    if isinstance(e, dict):
        gid = e.get('gap_id')
        if gid:
            gap_to_key[gid] = k

for gid, key in gap_to_key.items():
    g = gaps.get(gid)
    if not g or g.get('status') != 'open':
        continue
    od = g.get('created_at') or g.get('opened_date')
    if not od:
        continue
    try:
        od_d = datetime.fromisoformat(str(od).replace('Z', '+00:00')).date()
    except Exception:
        continue
    age = (today - od_d).days
    if age >= threshold:
        title = (g.get('title') or '').replace('|', '/')
        print(f"{gid}|{age}|{key}|{title}")
PY

reaped=0
while IFS='|' read -r gap_id age key title; do
    [ -z "$gap_id" ] && continue
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY: would close $gap_id (${age}d stale, key=$key) — $title"
    else
        if chump gap ship "$gap_id" >/dev/null 2>&1; then
            log "closed $gap_id (${age}d stale)"
            reaped=$((reaped + 1))
        else
            log "WARN: failed to close $gap_id"
        fi
    fi
done <"$TMP"

log "summary: reaped=$reaped (dry_run=$DRY_RUN, threshold=${THRESHOLD_DAYS}d)"
