#!/usr/bin/env bash
# scripts/coord/chump-capabilities.sh — INFRA-1825
#
# Read + dedup + filter-stale the CapabilityManifest files written by
# capability-publish.sh. Companion to the publish-daemon; together they
# implement the file-backed v0 of INFRA-1760 + INFRA-1120's parent gap.
#
# Usage:
#   chump-capabilities.sh list           — table of live sessions
#   chump-capabilities.sh list --json    — JSON array (machine-readable)
#   chump-capabilities.sh count          — number of live sessions
#
# "Live" = heartbeat_at within ttl_seconds (default 300) from now.
# Stale entries are excluded from output but NOT deleted (let the publisher
# rotate; a reaper hook in INFRA-1120 slice 2/4 sweeps old files).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CAP_DIR="${CHUMP_CAPABILITY_DIR:-$REPO_ROOT/.chump-locks/capabilities}"

if [[ ! -d "$CAP_DIR" ]]; then
    case "${1:-list}" in
        count) echo 0 ;;
        list)  echo "(no capabilities published yet)" ;;
        *)     echo "chump-capabilities: no $CAP_DIR" >&2; exit 1 ;;
    esac
    exit 0
fi

# Parse + dedup + filter via python3 (avoid jq dep).
collect() {
    python3 - "$CAP_DIR" <<'PYEOF'
import json
import os
import sys
import time
from datetime import datetime, timezone

cap_dir = sys.argv[1]
now = datetime.now(timezone.utc)

latest = {}  # session_id -> last manifest (by heartbeat_at)
for fname in os.listdir(cap_dir):
    if not fname.endswith(".jsonl"):
        continue
    fpath = os.path.join(cap_dir, fname)
    try:
        with open(fpath) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    m = json.loads(line)
                except Exception:
                    continue
                sid = m.get("session_id") or fname.removesuffix(".jsonl")
                hb = m.get("heartbeat_at", "")
                prev = latest.get(sid)
                if prev is None or hb > prev.get("heartbeat_at", ""):
                    latest[sid] = m
    except Exception:
        continue

live = []
stale = []
for sid, m in latest.items():
    ttl = int(m.get("ttl_seconds", 300))
    hb = m.get("heartbeat_at", "")
    try:
        # ISO 8601 → datetime; accept both with and without trailing Z.
        hb_dt = datetime.fromisoformat(hb.replace("Z", "+00:00"))
    except Exception:
        stale.append(m)
        continue
    age_s = (now - hb_dt).total_seconds()
    if age_s <= ttl:
        live.append(m)
    else:
        stale.append(m)

# Emit a JSON envelope so the caller can format.
print(json.dumps({"live": live, "stale_count": len(stale)}))
PYEOF
}

case "${1:-list}" in
    count)
        collect | python3 -c "import json, sys; d = json.load(sys.stdin); print(len(d['live']))"
        ;;
    list)
        if [[ "${2:-}" == "--json" ]]; then
            collect
        else
            collect | python3 -c "
import json, sys
d = json.load(sys.stdin)
live = d['live']
print(f'{\"session_id\":<48} {\"harness\":<12} {\"model\":<10} {\"machine\":<14} {\"skills\":<40} {\"heartbeat_at\":<20}')
print('-' * 150)
for m in sorted(live, key=lambda x: x.get('heartbeat_at', ''), reverse=True):
    skills = ','.join(m.get('skills', []))[:40] or '-'
    print(f\"{m.get('session_id','?'):<48} {m.get('harness','?'):<12} {m.get('model_tier','?'):<10} {(m.get('machine') or '-'):<14} {skills:<40} {m.get('heartbeat_at',''):<20}\")
print(f\"\\n({len(live)} live session(s); {d['stale_count']} stale excluded)\")
"
        fi
        ;;
    -h|--help)
        sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "chump-capabilities.sh: unknown command '$1' (want list|count)" >&2
        exit 2
        ;;
esac
