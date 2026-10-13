#!/usr/bin/env bash
# stalled-p0-detector.sh — RESILIENT-1582
#
# Alarm when a P0 gap has been unclaimed for > N hours, indicating potential
# priority inversion or effort-filter starve. Emits kind=p0_stalled alert so
# the next session-start digest surfaces it to the operator.
#
# Run cadence
#   Cron-friendly. Recommended every 30 min as part of ambient monitoring.
#   Idempotent: idempotent by design (emits fresh check each cycle).
#
# Bypass / tuning
#   CHUMP_STALLED_P0_DETECTOR=0 — disable entirely.
#   CHUMP_STALLED_P0_THRESHOLD_HOURS=24 — unclaimed time threshold (default 24).
#   CHUMP_STALLED_P0_AUTO_PAGE_OPERATOR=0 — if set, page operator on first find.

set -uo pipefail

if [[ "${CHUMP_STALLED_P0_DETECTOR:-1}" == "0" ]]; then
    echo "[stalled-p0] CHUMP_STALLED_P0_DETECTOR=0 — skipping" >&2
    exit 0
fi

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
THRESHOLD_HOURS="${CHUMP_STALLED_P0_THRESHOLD_HOURS:-24}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
STALLED_P0_STATE_FILE="$REPO_ROOT/.chump-locks/stalled-p0-detected.txt"

mkdir -p "$(dirname "$STALLED_P0_STATE_FILE")" "$(dirname "$AMBIENT")" 2>/dev/null || true
touch "$STALLED_P0_STATE_FILE" 2>/dev/null || true

emit_ambient() {
    local kind="$1"; shift
    local gap_id="$1"; shift
    local hours_stalled="$1"; shift
    local effort="$1"; shift
    local note="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    local payload
    payload=$(printf '{"ts":"%s","event":"ALERT","kind":"%s","source":"stalled-p0-detector","gap_id":"%s","hours_stalled":%d,"effort":"%s","note":"%s"}\n' \
        "$ts" "$kind" "$gap_id" "$hours_stalled" "$effort" "$note")
    echo "$payload" >> "$AMBIENT" 2>/dev/null || true
    echo "[stalled-p0] $payload" >&2
}

# Get current open P0 gaps with their age (in seconds since creation)
_gap_json="$(chump gap list --status open --json 2>/dev/null || echo '[]')"
if [[ -z "$_gap_json" || "$_gap_json" == "[]" ]]; then
    echo "[stalled-p0] no open gaps, skipping" >&2
    exit 0
fi

current_unix_time=$(date +%s 2>/dev/null || echo 0)
if [[ "$current_unix_time" == "0" ]]; then
    echo "[stalled-p0] failed to get current time, skipping" >&2
    exit 0
fi

# Check each P0 gap
found_stalled=0
python3 - <<'PYEOF' 2>/dev/null
import json
import sys
import os
from datetime import datetime, timedelta

repo_root = os.environ.get("REPO_ROOT", ".")
threshold_hours = int(os.environ.get("THRESHOLD_HOURS", "24"))
current_unix = int(os.environ.get("current_unix_time", "0"))
ambient_path = os.environ.get("AMBIENT", f"{repo_root}/.chump-locks/ambient.jsonl")
state_file = os.environ.get("STALLED_P0_STATE_FILE", f"{repo_root}/.chump-locks/stalled-p0-detected.txt")

try:
    gap_json = json.loads(os.environ.get("_gap_json", "[]"))
except Exception:
    print("[stalled-p0-python] failed to parse gap json", file=sys.stderr)
    sys.exit(1)

if not isinstance(gap_json, list):
    gap_json = []

threshold_seconds = threshold_hours * 3600

# Load previously seen stalled gaps to avoid duplicate emissions
seen_stalled = set()
try:
    with open(state_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                seen_stalled.add(line)
except Exception:
    pass

found_any = False
for gap in gap_json:
    if gap.get("priority", "").upper() != "P0":
        continue

    gap_id = gap.get("id", "?")
    effort = gap.get("effort", "?").lower()
    created_at = gap.get("created_at")

    if not created_at:
        continue

    age_seconds = current_unix - int(created_at)
    age_hours = age_seconds // 3600

    if age_hours >= threshold_hours:
        # P0 has been open for >= threshold. This is stalled.
        found_any = True

        # Check if we've already warned about this gap
        if gap_id not in seen_stalled:
            msg = f"P0 gap {gap_id} (effort={effort}) unclaimed for {age_hours}h, threshold={threshold_hours}h"
            print(msg, file=sys.stderr)

            # Emit to ambient
            ts = datetime.utcnow().isoformat() + "Z"
            payload = {
                "ts": ts,
                "event": "ALERT",
                "kind": "p0_stalled",
                "source": "stalled-p0-detector",
                "gap_id": gap_id,
                "hours_stalled": age_hours,
                "effort": effort,
                "threshold_hours": threshold_hours,
            }
            try:
                with open(ambient_path, 'a') as f:
                    f.write(json.dumps(payload) + '\n')
            except Exception as e:
                print(f"[stalled-p0-python] failed to write ambient: {e}", file=sys.stderr)

            # Mark as seen
            try:
                with open(state_file, 'a') as f:
                    f.write(gap_id + '\n')
            except Exception as e:
                print(f"[stalled-p0-python] failed to write state: {e}", file=sys.stderr)

if found_any:
    print("[stalled-p0-python] found stalled P0 gaps", file=sys.stderr)
else:
    print("[stalled-p0-python] no stalled P0 gaps", file=sys.stderr)

sys.exit(0 if found_any else 0)
PYEOF

exit 0
