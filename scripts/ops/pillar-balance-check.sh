#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Reads state.db via 'chump gap list --status open --json', counts pickable
# gaps per pillar (EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE), and
# emits ambient events when the fleet is imbalanced.
#
# Pickable = P0|P1, effort xs|s, non-empty AC, depends_on empty or [].
#
# Emits:
#   kind=pillar_balance_alert       — pillar count < FLOOR (default 2)
#   kind=pillar_balance_overweight  — pillar count > 50% of total pickable
#
# Exit: non-zero if any alert fired, 0 if balanced.
#
# Bash-3.2 compatible (no declare -A/-n, no mapfile/readarray).
#
# Usage:
#   pillar-balance-check.sh              # check + emit ambient events
#   pillar-balance-check.sh --json       # machine-readable output
#   pillar-balance-check.sh --dry-run    # compute + print, skip ambient emit
#   pillar-balance-check.sh --floor N    # override underfloor threshold (default 2)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

JSON=0
DRY_RUN=0
FLOOR="${CHUMP_PILLAR_FLOOR:-2}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --floor)   FLOOR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "pillar-balance-check: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Find chump binary (INFRA-481: honour cargo metadata target_directory) ──
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    TARGET_DIR="$(cargo metadata --no-deps --format-version=1 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null \
        || echo "$REPO_ROOT/target")"
    if [[ -x "$TARGET_DIR/release/chump" ]]; then
        CHUMP_BIN="$TARGET_DIR/release/chump"
    elif [[ -x "$TARGET_DIR/debug/chump" ]]; then
        CHUMP_BIN="$TARGET_DIR/debug/chump"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "pillar-balance-check: chump binary not found" >&2
        exit 1
    fi
fi

# ── Get open gaps as JSON ─────────────────────────────────────────────────
GAP_JSON="$("$CHUMP_BIN" gap list --status open --json 2>/dev/null)" || {
    echo "pillar-balance-check: chump gap list --json failed" >&2
    exit 1
}

# ── Ensure ambient log directory exists (INFRA-902 blocker #2) ───────────
mkdir -p "$(dirname "$AMBIENT_LOG")"

# ── Count per-pillar using python3 (Bash-3.2 compatible workaround) ──────
# Pass JSON via env var to avoid heredoc + herestring conflict.
RESULT="$(GAP_JSON="$GAP_JSON" FLOOR="$FLOOR" python3 -c '
import json, os, sys

floor = int(os.environ.get("FLOOR", "2"))
gaps = json.loads(os.environ["GAP_JSON"])

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]

counts = {p: 0 for p in PILLARS}
counts["OTHER"] = 0
total = 0

for g in gaps:
    if g.get("priority") not in ("P0", "P1"):
        continue
    if g.get("effort") not in ("xs", "s"):
        continue
    ac = g.get("acceptance_criteria", "").strip()
    if not ac or ac in ("[]", ""):
        continue
    deps_raw = g.get("depends_on", "[]")
    try:
        dep_list = json.loads(deps_raw) if isinstance(deps_raw, str) else deps_raw
    except Exception:
        dep_list = []
    if dep_list:
        continue

    total += 1
    title_up = g.get("title", "").upper()
    assigned = False
    for p in PILLARS:
        if p in title_up:
            counts[p] += 1
            assigned = True
            break
    if not assigned:
        counts["OTHER"] += 1

alerts = []
for p in PILLARS:
    n = counts[p]
    if n < floor:
        alerts.append({"type": "underfloor", "pillar": p, "count": n, "floor": floor})
    if total > 0 and n * 2 > total:
        pct = int(n * 100 // total)
        alerts.append({"type": "overweight", "pillar": p, "count": n, "pct": pct, "total": total})

print(json.dumps({
    "total": total,
    "counts": counts,
    "alerts": alerts,
    "floor": floor,
}, separators=(",", ":")))
')"

# ── Parse alert count ─────────────────────────────────────────────────────
ALERT_COUNT="$(echo "$RESULT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["alerts"]))')"

# ── Output ────────────────────────────────────────────────────────────────
if [[ "$JSON" -eq 1 ]]; then
    echo "$RESULT"
else
    echo "$RESULT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("[pillar-balance-check] pickable=%d" % d["total"])
for p in ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]:
    print("  %s: %d" % (p, d["counts"][p]))
print("  OTHER: %d" % d["counts"]["OTHER"])
if not d["alerts"]:
    print("OK balance")
else:
    for a in d["alerts"]:
        if a["type"] == "underfloor":
            print("ALERT underfloor: %s count=%d floor=%d" % (a["pillar"], a["count"], a["floor"]))
        elif a["type"] == "overweight":
            print("ALERT overweight: %s count=%d pct=%d%% total=%d" % (a["pillar"], a["count"], a["pct"], a["total"]))
'
fi

# ── Emit ambient events ───────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 && "$ALERT_COUNT" -gt 0 ]]; then
    TS="$(now_ts)"
    echo "$RESULT" | TS="$TS" AMBIENT_LOG="$AMBIENT_LOG" python3 -c '
import json, sys, os

d = json.load(sys.stdin)
ts = os.environ.get("TS", "")
ambient = os.environ.get("AMBIENT_LOG", "")

for a in d["alerts"]:
    if a["type"] == "underfloor":
        ev = json.dumps({
            "ts": ts,
            "kind": "pillar_balance_alert",
            "pillar": a["pillar"],
            "count": a["count"],
            "floor": a["floor"],
        }, separators=(",", ":"))
    elif a["type"] == "overweight":
        ev = json.dumps({
            "ts": ts,
            "kind": "pillar_balance_overweight",
            "pillar": a["pillar"],
            "count": a["count"],
            "pct": a["pct"],
            "total": a["total"],
        }, separators=(",", ":"))
    else:
        continue
    if ambient:
        try:
            open(ambient, "a").write(ev + "\n")
        except Exception:
            print(ev)
    else:
        print(ev)
' 2>/dev/null || true
fi

# ── Exit non-zero if any alert fired ─────────────────────────────────────
if [[ "$ALERT_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
