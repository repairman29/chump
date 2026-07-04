#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Reads open gaps via 'chump gap list --status open --json', counts pickable
# (P0|P1 xs|s|m, no TODO ACs, no blocked deps) gaps per pillar
# (EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE), and emits alerts to ambient.jsonl.
#
# Exit: 0 = no alerts; 1 = one or more alerts fired.
#
# Bash 3.2 compatible (macOS /bin/bash) — no declare -A/-n, mapfile, readarray.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── resolve chump binary ───────────────────────────────────────────────────
if [ -n "${CHUMP_BIN:-}" ]; then
    BIN="$CHUMP_BIN"
elif [ -n "${CARGO_TARGET_DIR:-}" ]; then
    BIN="$CARGO_TARGET_DIR/debug/chump"
else
    # cargo metadata fallback: shared target dir (INFRA-481)
    META_BIN=""
    if command -v cargo >/dev/null 2>&1; then
        META_BIN="$(cargo metadata --no-deps --format-version 1 --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || true)"
    fi
    if [ -n "$META_BIN" ] && [ -x "$META_BIN/debug/chump" ]; then
        BIN="$META_BIN/debug/chump"
    elif command -v chump >/dev/null 2>&1; then
        BIN="$(command -v chump)"
    else
        echo "pillar-balance-check: chump binary not found (set CHUMP_BIN)" >&2
        exit 1
    fi
fi

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FLOOR=2

# mkdir -p before any >> AMBIENT write (AC requirement — .chump-locks/ may not exist)
mkdir -p "$(dirname "$AMBIENT")"

# ── fetch open gaps ────────────────────────────────────────────────────────
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

if ! "$BIN" gap list --status open --json >"$TMP_JSON" 2>/dev/null; then
    echo "pillar-balance-check: 'chump gap list --status open --json' failed" >&2
    exit 1
fi

# ── count pickable per pillar and emit alerts via python3 ─────────────────
python3 - "$TMP_JSON" "$AMBIENT" "$FLOOR" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

gap_file   = sys.argv[1]
ambient    = sys.argv[2]
floor      = int(sys.argv[3])

with open(gap_file) as f:
    raw = json.load(f)

# gap list --json may return a plain array or a {gaps: [...]} object
if isinstance(raw, dict) and "gaps" in raw:
    gaps = raw["gaps"]
elif isinstance(raw, list):
    gaps = raw
else:
    gaps = []

PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]
PICKABLE_PRIORITIES = {"P0", "P1"}
PICKABLE_EFFORTS    = {"xs", "s", "m"}

def is_vague_ac(ac):
    if not ac or not ac.strip():
        return True
    up = ac.strip().upper()
    return up in ("TODO", "TBD", "<FILL IN>", "[]", "[[]]")

def get_pillar(gap):
    # 1. Domain field (most authoritative — gap ID prefix)
    dom = (gap.get("domain") or "").upper()
    if dom in PILLARS:
        return dom
    # 2. Gap ID prefix (e.g. EFFECTIVE-123 → EFFECTIVE)
    gid = (gap.get("id") or "").split("-")[0].upper()
    if gid in PILLARS:
        return gid
    # 3. Title prefix (e.g. "EFFECTIVE: some title")
    title = gap.get("title") or ""
    for p in PILLARS:
        if title.upper().startswith(p + ":") or title.upper().startswith(p + " "):
            return p
    return None

def has_blocked_deps(gap, status_by_id):
    raw = gap.get("depends_on") or "[]"
    if raw in ("[]", "", "null"):
        return False
    try:
        deps = json.loads(raw)
        if isinstance(deps, list):
            for dep in deps:
                if isinstance(dep, str) and dep:
                    st = status_by_id.get(dep)
                    if st is not None and st != "done":
                        return True
    except (json.JSONDecodeError, TypeError, ValueError):
        pass
    return False

status_by_id = {g.get("id", ""): g.get("status", "") for g in gaps}
counts = {p: 0 for p in PILLARS}
total_pickable = 0

for gap in gaps:
    if gap.get("status") != "open":
        continue
    if gap.get("priority") not in PICKABLE_PRIORITIES:
        continue
    if gap.get("effort") not in PICKABLE_EFFORTS:
        continue
    if is_vague_ac(gap.get("acceptance_criteria") or ""):
        continue
    if has_blocked_deps(gap, status_by_id):
        continue
    pillar = get_pillar(gap)
    if pillar is None:
        continue
    counts[pillar] += 1
    total_pickable += 1

ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
alerts_fired = 0

# ── underweight alert (count < floor) ────────────────────────────────────
for pillar in PILLARS:
    count = counts[pillar]
    if count < floor:
        event = {
            "ts":     ts,
            "kind":   "pillar_balance_alert",
            "pillar": pillar,
            "count":  count,
            "floor":  floor,
        }
        with open(ambient, "a") as af:
            af.write(json.dumps(event) + "\n")
        print(f"ALERT: pillar {pillar} has {count} pickable gaps (floor={floor})",
              file=sys.stderr)
        alerts_fired += 1

# ── overweight alert (count > 50% of total) ───────────────────────────────
if total_pickable > 0:
    for pillar in PILLARS:
        count = counts[pillar]
        pct = (count * 100) // total_pickable
        if pct > 50:
            event = {
                "ts":     ts,
                "kind":   "pillar_balance_overweight",
                "pillar": pillar,
                "count":  count,
                "pct":    pct,
            }
            with open(ambient, "a") as af:
                af.write(json.dumps(event) + "\n")
            print(f"ALERT: pillar {pillar} overweight: {count}/{total_pickable} = {pct}%",
                  file=sys.stderr)
            alerts_fired += 1

# ── human summary (stdout) ────────────────────────────────────────────────
print(f"Pillar balance (pickable P0|P1 xs|s|m): total={total_pickable}")
for p in PILLARS:
    count = counts[p]
    if total_pickable > 0:
        pct = (count * 100) // total_pickable
        pct_str = f" ({pct}%)"
    else:
        pct_str = ""
    marker = " [UNDERWEIGHT]" if count < floor else ""
    if total_pickable > 0 and (count * 100) // total_pickable > 50:
        marker += " [OVERWEIGHT]"
    print(f"  {p:<12} {count}{pct_str}{marker}")

sys.exit(1 if alerts_fired > 0 else 0)
PYEOF
