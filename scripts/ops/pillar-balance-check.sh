#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Reads open gaps via `chump gap list --status open --json`, counts pickable
# gaps (P0/P1, effort xs/s/m, non-TODO ACs, empty depends_on) per pillar, then:
#   • Emits kind=pillar_balance_alert   when any pillar count < 2
#   • Emits kind=pillar_balance_overweight when any pillar > 50% of total pickable
#   • Exits non-zero if any alert fired
#
# Bash 3.2 compatible (no declare -A, no mapfile, no readarray, no declare -n).
# Uses python3 for JSON parsing.
#
# Env overrides:
#   CHUMP_BIN           path to chump binary (required when not on PATH)
#   CHUMP_AMBIENT_LOG   override ambient.jsonl path
#   CHUMP_REPO          repo root (falls back to git rev-parse)
#   PILLAR_FLOOR        minimum pickable count before alert fires (default 2)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"

# Resolve chump binary: CHUMP_BIN env > cargo metadata target dir > PATH.
if [[ -z "${CHUMP_BIN:-}" ]]; then
    # Honor shared target-dir from cargo metadata (INFRA-481).
    TARGET_DIR=""
    if command -v cargo >/dev/null 2>&1; then
        TARGET_DIR="$(cargo metadata --format-version 1 --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('target_directory',''))" 2>/dev/null || true)"
    fi
    if [[ -n "$TARGET_DIR" && -x "$TARGET_DIR/debug/chump" ]]; then
        export CHUMP_BIN="$TARGET_DIR/debug/chump"
    elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
        export CHUMP_BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    elif command -v chump >/dev/null 2>&1; then
        export CHUMP_BIN="chump"
    else
        echo "[pillar-balance-check] ERROR: chump binary not found; set CHUMP_BIN" >&2
        exit 2
    fi
fi

export CHUMP_BIN

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FLOOR="${PILLAR_FLOOR:-2}"

# Ensure ambient dir exists before any >> append.
mkdir -p "$(dirname "$AMBIENT")"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    local kind="$1" pillar="$2" count="$3" extra="$4"
    # scanner-anchor: "kind":"pillar_balance_alert"
    # scanner-anchor: "kind":"pillar_balance_overweight"
    printf '{"ts":"%s","kind":"%s","source":"pillar_balance_check","pillar":"%s","count":%s%s}\n' \
        "$(_ts)" "$kind" "$pillar" "$count" "$extra" \
        >> "$AMBIENT" 2>/dev/null || true
}

# Fetch all open gaps as JSON.
GAP_JSON=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null) || {
    echo "[pillar-balance-check] ERROR: 'chump gap list --status open --json' failed" >&2
    exit 2
}

# Parse + count per pillar using python3 (Bash-3.2-safe JSON parsing).
COUNTS=$(python3 - "$FLOOR" <<'PYEOF'
import sys, json

floor = int(sys.argv[1]) if len(sys.argv) > 1 else 2
raw = sys.stdin.read().strip()

if not raw:
    data = []
else:
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = []
    # gap list --json may return {"gaps": [...], ...} when --domain all is used
    if isinstance(parsed, dict) and "gaps" in parsed:
        data = parsed["gaps"]
    elif isinstance(parsed, list):
        data = parsed
    else:
        data = []

PICKABLE_PRIORITIES = {"P0", "P1"}
PICKABLE_EFFORTS    = {"xs", "s", "m"}
PILLARS = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"]

counts = {p: 0 for p in PILLARS}
total = 0

for g in data:
    if not isinstance(g, dict):
        continue
    status   = str(g.get("status", "")).lower()
    priority = str(g.get("priority", "")).upper()
    effort   = str(g.get("effort", "")).lower()
    ac       = str(g.get("acceptance_criteria", ""))
    depends  = g.get("depends_on", "[]")

    if status != "open":
        continue
    if priority not in PICKABLE_PRIORITIES:
        continue
    if effort not in PICKABLE_EFFORTS:
        continue
    # Vague AC (empty or "TODO") is not pickable.
    ac_stripped = ac.strip()
    if not ac_stripped or ac_stripped.upper() == "TODO":
        continue
    # Blocked by deps: depends_on must be empty array (or empty string).
    if isinstance(depends, str):
        try:
            dep_list = json.loads(depends)
        except (json.JSONDecodeError, ValueError):
            dep_list = []
    elif isinstance(depends, list):
        dep_list = depends
    else:
        dep_list = []
    if dep_list:
        continue

    title_up = str(g.get("title", "")).upper()
    matched = False
    for p in PILLARS:
        if p in title_up:
            counts[p] += 1
            matched = True
            break
    if matched:
        total += 1

# Output: one line per pillar + total line
for p in PILLARS:
    print(f"{p}={counts[p]}")
print(f"TOTAL={total}")
PYEOF
)

# Parse shell-friendly lines (Bash 3.2: no assoc arrays, use positional vars).
EFF=0; CRE=0; RES=0; ZW=0; TOTAL=0

while IFS='=' read -r key val; do
    case "$key" in
        EFFECTIVE)  EFF="$val" ;;
        CREDIBLE)   CRE="$val" ;;
        RESILIENT)  RES="$val" ;;
        ZERO-WASTE) ZW="$val" ;;
        TOTAL)      TOTAL="$val" ;;
    esac
done <<EOF
$COUNTS
EOF

EFF="${EFF:-0}"
CRE="${CRE:-0}"
RES="${RES:-0}"
ZW="${ZW:-0}"
TOTAL="${TOTAL:-0}"

echo "[pillar-balance-check] pickable=${TOTAL} EFFECTIVE=${EFF} CREDIBLE=${CRE} RESILIENT=${RES} ZERO-WASTE=${ZW}"

ALERT_FIRED=0

# ── Under-floor alerts ────────────────────────────────────────────────────────
for pair in "EFFECTIVE:${EFF}" "CREDIBLE:${CRE}" "RESILIENT:${RES}" "ZERO-WASTE:${ZW}"; do
    pillar="${pair%%:*}"
    count="${pair##*:}"
    if [ "${count}" -lt "${FLOOR}" ]; then
        echo "[pillar-balance-check] ALERT: ${pillar} has ${count} pickable gap(s) (floor=${FLOOR})" >&2
        _emit "pillar_balance_alert" "$pillar" "$count" ',"floor":2'
        ALERT_FIRED=1
    fi
done

# ── Overweight alerts (> 50% of total pickable) ───────────────────────────────
if [ "${TOTAL}" -gt 0 ]; then
    for pair in "EFFECTIVE:${EFF}" "CREDIBLE:${CRE}" "RESILIENT:${RES}" "ZERO-WASTE:${ZW}"; do
        pillar="${pair%%:*}"
        count="${pair##*:}"
        # Integer percent: count*100/TOTAL
        pct=$(( count * 100 / TOTAL ))
        if [ "${pct}" -gt 50 ]; then
            echo "[pillar-balance-check] ALERT: ${pillar} is overweight at ${pct}% of pickable pool (count=${count})" >&2
            _emit "pillar_balance_overweight" "$pillar" "$count" ",\"pct\":${pct}"
            ALERT_FIRED=1
        fi
    done
fi

if [ "${ALERT_FIRED}" -eq 0 ]; then
    echo "[pillar-balance-check] ✓ Balance OK — all pillars within bounds"
fi

exit "${ALERT_FIRED}"
