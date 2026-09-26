#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902 (CREDIBLE: pillar balance analysis + alerts)
#
# Reads open gaps via `chump gap list --status open --json`, buckets each
# pillar-tagged gap (title prefix EFFECTIVE:/CREDIBLE:/RESILIENT:/ZERO-WASTE:,
# case-insensitive) into "pickable" (P0/P1, effort xs/s/m, has real acceptance
# criteria, no open blocking deps) vs. not, and emits ambient alerts when a
# pillar is starved (< floor) or overweight (> 50% of the pickable pool).
#
# Bash-3.2 compatible on purpose (macOS ships Bash 3.2; this script must not
# use declare -A / declare -n / mapfile / readarray) — the counting itself is
# delegated to python3 so no associative arrays are needed in bash at all.
#
# Usage:
#   scripts/ops/pillar-balance-check.sh [--json]
#   CHUMP_BIN=/path/to/chump scripts/ops/pillar-balance-check.sh
#   CHUMP_AMBIENT_LOG=/path/to/ambient.jsonl scripts/ops/pillar-balance-check.sh
#
# Exit code: non-zero if any alert (starved or overweight) fired.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WANT_JSON=0
for arg in "$@"; do
    case "$arg" in
        --json) WANT_JSON=1 ;;
    esac
done

# Honor CHUMP_BIN (tests pass a fixture binary explicitly); else PATH chump.
CHUMP_BIN="${CHUMP_BIN:-chump}"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")"

FLOOR=2

GAP_JSON="$("$CHUMP_BIN" gap list --status open --json 2>/dev/null)"
if [[ -z "$GAP_JSON" ]]; then
    echo "pillar-balance-check: no output from '$CHUMP_BIN gap list --status open --json'" >&2
    exit 2
fi

GAP_JSON_FILE="$(mktemp)"
trap 'rm -f "$GAP_JSON_FILE"' EXIT
printf '%s' "$GAP_JSON" > "$GAP_JSON_FILE"

# NOTE: the gap JSON is passed as a file argument, not piped — piping it
# would collide with the heredoc below, which already occupies stdin to
# deliver the python script source itself.
RESULT="$(python3 - "$FLOOR" "$GAP_JSON_FILE" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

floor = int(sys.argv[1])
with open(sys.argv[2]) as f:
    raw = f.read()

try:
    # Some callers' `chump gap list` emits informational lines before the
    # JSON array (e.g. staleness warnings) — find the first '[' and parse
    # from there so this stays robust to banner noise on stdout.
    start = raw.index("[")
    gaps = json.loads(raw[start:])
except (ValueError, json.JSONDecodeError):
    gaps = []

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]


def classify(title):
    up = (title or "").upper()
    for p in PILLARS:
        if up.startswith(p + ":"):
            return p
    return None


def has_real_ac(gap):
    ac = gap.get("acceptance_criteria") or ""
    if isinstance(ac, list):
        text = " ".join(str(x) for x in ac)
    else:
        text = str(ac)
    text = text.strip()
    if not text or text in ("[]", "\"\"", "null"):
        return False
    if "TODO" in text.upper():
        return False
    return True


def has_blocked_deps(gap):
    deps = gap.get("depends_on") or ""
    if isinstance(deps, str):
        deps = deps.strip()
        if not deps or deps in ("[]", "null"):
            return False
        try:
            parsed = json.loads(deps)
        except (ValueError, json.JSONDecodeError):
            return bool(deps)
        deps = parsed
    return bool(deps)


def is_pickable(gap):
    if gap.get("priority") not in ("P0", "P1"):
        return False
    if gap.get("effort") not in ("xs", "s", "m"):
        return False
    if not has_real_ac(gap):
        return False
    if has_blocked_deps(gap):
        return False
    return True


counts = {p: 0 for p in PILLARS}
for gap in gaps:
    pillar = classify(gap.get("title", ""))
    if pillar is None:
        continue
    if is_pickable(gap):
        counts[pillar] += 1

total = sum(counts.values())
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

alerts = []
for p in PILLARS:
    c = counts[p]
    if c < floor:
        alerts.append({
            "ts": ts,
            "kind": "pillar_balance_alert",
            "pillar": p,
            "count": c,
            "floor": floor,
        })
    if total > 0 and c > total * 0.5:
        pct = round((c / total) * 100)
        alerts.append({
            "ts": ts,
            "kind": "pillar_balance_overweight",
            "pillar": p,
            "count": c,
            "pct": pct,
        })

out = {
    "ts": ts,
    "total_pickable": total,
    "counts": counts,
    "alerts": alerts,
}
print(json.dumps(out))
PYEOF
)"

if [[ -z "$RESULT" ]]; then
    echo "pillar-balance-check: failed to compute pillar counts (python3 error)" >&2
    exit 2
fi

ALERT_COUNT="$(printf '%s' "$RESULT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['alerts']))")"

# Append each alert as its own ambient.jsonl line.
printf '%s' "$RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data['alerts']:
    print(json.dumps(a))
" >> "$AMBIENT"

if [[ "$WANT_JSON" -eq 1 ]]; then
    printf '%s\n' "$RESULT"
else
    printf '%s' "$RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('=== pillar-balance-check ===')
print('total pickable: %d' % data['total_pickable'])
for pillar, count in data['counts'].items():
    print('  %-12s %d' % (pillar, count))
if data['alerts']:
    print()
    print('ALERTS:')
    for a in data['alerts']:
        if a['kind'] == 'pillar_balance_alert':
            print('  STARVED: %s count=%d floor=%d' % (a['pillar'], a['count'], a['floor']))
        else:
            print('  OVERWEIGHT: %s count=%d pct=%d%%' % (a['pillar'], a['count'], a['pct']))
else:
    print()
    print('No alerts — pillars balanced.')
"
fi

if [[ "$ALERT_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
