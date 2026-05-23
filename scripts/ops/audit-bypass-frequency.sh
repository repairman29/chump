#!/usr/bin/env bash
# scripts/ops/audit-bypass-frequency.sh — INFRA-1837
#
# Daily auditor of --no-verify and CHUMP_*_SKIP bypass usage. Pairs with
# INFRA-1872 (ci_qa_score) on the same telemetry layer:
#   - 1872 = % clean ships (rear-view aggregate)
#   - 1837 = WHO bypassed, HOW OFTEN, WHY (per-session shame loop)
#
# Read sources (last 24h):
#   .chump-locks/ambient.jsonl            kind in {audit_no_verify, preflight_bypassed}
#   .chump-locks/no-verify-audit.jsonl    if present (INFRA-1834 sidecar)
#
# Computes per-session:
#   - 24h bypass count
#   - top-3 reasons (truncated to 60 chars each, regex-extracted from reason)
#   - most-recent bypass ts
#   - 7-day moving average — flag outliers ('today=8 vs 7d-avg=2')
#
# Emits:
#   - kind=bypass_threshold_breach   if any session 24h count > CHUMP_BYPASS_DAILY_THRESHOLD (default 5)
#   - WARN broadcast --to operator-*  with the top-3 offenders table
#
# Bypass: CHUMP_AUDIT_BYPASS_FREQ=0 silently exits 0.
#
# Usage:
#   audit-bypass-frequency.sh              # daily mode: read + emit + broadcast
#   audit-bypass-frequency.sh --json       # machine-readable output, no broadcast
#   audit-bypass-frequency.sh --dry-run    # compute + log, skip broadcast + ambient emit
#   audit-bypass-frequency.sh --threshold 3
#   audit-bypass-frequency.sh --window-hours 48

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
NV_AUDIT="${CHUMP_NO_VERIFY_AUDIT:-$LOCK_DIR/no-verify-audit.jsonl}"

THRESHOLD="${CHUMP_BYPASS_DAILY_THRESHOLD:-5}"
WINDOW_HOURS=24
JSON=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --window-hours) WINDOW_HOURS="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "audit-bypass-frequency: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [[ "${CHUMP_AUDIT_BYPASS_FREQ:-1}" == "0" ]]; then
    printf '{"ts":"%s","kind":"audit_bypass_freq_bypassed","reason":"CHUMP_AUDIT_BYPASS_FREQ=0"}\n' \
        "$(now_ts)" >> "$AMBIENT_LOG" 2>/dev/null || true
    echo "[audit-bypass-frequency] bypassed via CHUMP_AUDIT_BYPASS_FREQ=0"
    exit 0
fi

# Walk the two source files via python3 — easier to do datetime math + grouping.
# Emits a JSON envelope: {by_session: {sid: {today_count, top_reasons, last_ts, week_avg}}, threshold_breaches: [...], threshold}.
compute() {
    AMBIENT_LOG="$AMBIENT_LOG" NV_AUDIT="$NV_AUDIT" \
    WINDOW_HOURS="$WINDOW_HOURS" THRESHOLD="$THRESHOLD" \
    python3 <<'PYEOF'
import json
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

ambient = os.environ["AMBIENT_LOG"]
nv_audit = os.environ["NV_AUDIT"]
window_h = int(os.environ["WINDOW_HOURS"])
threshold = int(os.environ["THRESHOLD"])

now = datetime.now(timezone.utc)
today_cutoff = now - timedelta(hours=window_h)
week_cutoff = now - timedelta(days=7)

BYPASS_KINDS = {"audit_no_verify", "preflight_bypassed"}

# session_id -> [(ts_dt, reason)]
today = defaultdict(list)
week = defaultdict(int)

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

def walk(path):
    if not os.path.isfile(path):
        return
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                k = e.get("kind", "")
                if k not in BYPASS_KINDS:
                    continue
                ts = parse_ts(e.get("ts", ""))
                if ts is None:
                    continue
                sid = e.get("session") or e.get("session_id") or "unknown"
                reason = (e.get("reason") or "").strip() or "(none)"
                if ts >= today_cutoff:
                    today[sid].append((ts, reason))
                if ts >= week_cutoff:
                    week[sid] += 1
    except Exception:
        pass

walk(ambient)
walk(nv_audit)

# Per-session rollup.
by_session = {}
breaches = []
for sid, events in today.items():
    events.sort(key=lambda x: x[0], reverse=True)
    reasons = Counter(r[:60] for _, r in events).most_common(3)
    week_count = week.get(sid, 0)
    # 7-day average = (week_count - today_count) / 6 days (excluding today).
    today_n = len(events)
    prior_n = max(0, week_count - today_n)
    week_avg = round(prior_n / 6, 1)
    by_session[sid] = {
        "today_count": today_n,
        "top_reasons": [{"reason": r, "n": n} for r, n in reasons],
        "last_ts": events[0][0].isoformat().replace("+00:00", "Z"),
        "week_avg_prior_days": week_avg,
        "outlier": today_n > max(week_avg * 2, 3),
    }
    if today_n > threshold:
        breaches.append({
            "session": sid,
            "count": today_n,
            "threshold": threshold,
            "week_avg": week_avg,
        })

print(json.dumps({
    "window_hours": window_h,
    "threshold": threshold,
    "by_session": by_session,
    "threshold_breaches": breaches,
}))
PYEOF
}

REPORT="$(compute)"

if [[ "$JSON" -eq 1 ]]; then
    echo "$REPORT"
    exit 0
fi

# Plain output + side effects (broadcast + emit).
BREACH_COUNT=$(python3 -c "
import json, sys
d = json.loads('''$REPORT''')
print(len(d['threshold_breaches']))
")

# Emit a bypass_threshold_breach event per breaching session.
if [[ "$DRY_RUN" -eq 0 && "$BREACH_COUNT" -gt 0 ]]; then
    python3 -c "
import json
d = json.loads('''$REPORT''')
ts = '$(now_ts)'
for b in d['threshold_breaches']:
    line = json.dumps({
        'ts': ts, 'kind': 'bypass_threshold_breach',
        'session': b['session'], 'count': b['count'],
        'threshold': b['threshold'], 'week_avg': b['week_avg'],
    }, separators=(',', ':'))
    print(line)
" >> "$AMBIENT_LOG" 2>/dev/null || true
fi

# Pretty-print + broadcast top 3 offenders.
SUMMARY=$(python3 -c "
import json
d = json.loads('''$REPORT''')
rows = sorted(d['by_session'].items(), key=lambda kv: kv[1]['today_count'], reverse=True)[:3]
if not rows:
    print('(no bypasses in window)')
else:
    out = []
    for sid, r in rows:
        reasons = ', '.join(f\"{x['reason']}({x['n']})\" for x in r['top_reasons']) or '-'
        outlier = ' OUTLIER' if r['outlier'] else ''
        out.append(f\"{sid[:48]}  today={r['today_count']} avg7d={r['week_avg_prior_days']}{outlier}  reasons=[{reasons}]\")
    print(chr(10).join(out))
")

cat <<EOM
[audit-bypass-frequency] window=${WINDOW_HOURS}h threshold=${THRESHOLD} breaches=${BREACH_COUNT}
$SUMMARY
EOM

if [[ "$DRY_RUN" -eq 0 ]]; then
    # Broadcast to operator-* if any breach OR any non-zero today_count.
    HAS_ACTIVITY=$(python3 -c "
import json
d = json.loads('''$REPORT''')
print(1 if d['by_session'] else 0)
")
    if [[ "$HAS_ACTIVITY" -eq 1 ]]; then
        bash "$REPO_ROOT/scripts/coord/broadcast.sh" WARN \
            --reason "[audit-bypass-frequency] daily report (${WINDOW_HOURS}h window, threshold ${THRESHOLD}): ${BREACH_COUNT} session(s) breached. Top: $(echo "$SUMMARY" | head -3 | tr '\n' ' | ')" \
            2>/dev/null || true
    fi
fi

# Exit non-zero only on breach so cron can alert via launchctl monitoring.
if (( BREACH_COUNT > 0 )); then exit 1; fi
exit 0
