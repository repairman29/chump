#!/usr/bin/env bash
# check-aging-open-gaps.sh — find gaps with status:open + opened_date older than
# the threshold. Default 30 days; override with CHUMP_AGING_GAPS_DAYS.
#
# Output one finding per stale gap. The auditor does not auto-close — that's
# what stale-auditor-finding-reaper.sh handles for *auditor-filed* gaps. This
# check raises operator awareness on gaps the human team forgot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"
THRESHOLD_DAYS="${CHUMP_AGING_GAPS_DAYS:-30}"
log "scanning for open gaps older than ${THRESHOLD_DAYS} days..."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

GAPS_JSON="$(mktemp)"
trap 'rm -f "$TMP" "$GAPS_JSON"' EXIT
all_gaps_json >"$GAPS_JSON"

THRESHOLD_DAYS="$THRESHOLD_DAYS" python3 - "$GAPS_JSON" >"$TMP" <<'PY'
import os, sys, json
from datetime import date, datetime
threshold = int(os.environ['THRESHOLD_DAYS'])
today = date.today()
with open(sys.argv[1]) as f:
    gaps = json.load(f)
for g in gaps:
    if g.get('status') != 'open':
        continue
    # Auditor-filed gaps carry AUDITOR_KEY= in description; the reaper handles them.
    desc = g.get('description') or ''
    if 'AUDITOR_KEY=' in desc:
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
        gid = g.get('id', '?')
        prio = g.get('priority', 'P2')
        print(f"{gid}|{age}|{prio}")
PY

while IFS='|' read -r gap_id age prio; do
    [ -z "$gap_id" ] && continue
    key="AGING_OPEN_GAP::${gap_id}"
    title="Aging open gap: $gap_id (${age}d)"
    desc="Gap \`$gap_id\` has been \`status: open\` for ${age} days at priority \`${prio}\`. Either it should be re-prioritised, broken into smaller gaps, or closed as won't-do. Acceptance criteria: gap is closed, its priority is explicitly re-affirmed via \`chump gap set $gap_id --priority …\` (resets clock), or it is split into smaller pieces."
    # Auditor's nag prio mirrors the gap's own — don't escalate to P1 just because it aged.
    nag_prio="P2"
    emit_finding "aging-open-gaps" "$key" "$title" "$desc" "INFRA" "$nag_prio" "xs" "[\"$gap_id\"]"
done <"$TMP"

log "aging-open-gaps done."
