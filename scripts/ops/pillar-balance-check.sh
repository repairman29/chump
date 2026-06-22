#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance analyzer + alerts.
#
# Reads state.db via 'chump gap list --status open --json', counts pickable
# gaps (P0|P1, effort xs|s|m, non-empty AC, no blocked deps) per pillar
# (EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE), then:
#   - emits kind=pillar_balance_alert     when any pillar count < FLOOR (default 2)
#   - emits kind=pillar_balance_overweight when any pillar > OVERWEIGHT_PCT% of total
#   - exits non-zero (1) if any alert fired; non-zero (2) on config error
#
# Bash 3.2 compatible: no declare -A, no mapfile, no readarray, no declare -n.
# Uses python3 for JSON parsing.
#
# Env overrides:
#   CHUMP_BIN              path to chump binary (auto-discovered if unset)
#   CHUMP_AMBIENT_LOG      path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   CHUMP_LOCK_DIR         directory for .chump-locks (default: <repo>/.chump-locks)
#   CHUMP_PILLAR_FLOOR     count below which an alert fires (default: 2)
#   CHUMP_PILLAR_OVERWEIGHT_PCT  pct above which overweight fires (default: 50)
#   CHUMP_PILLAR_BALANCE_CHECK=0  disable entirely (exit 0)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
FLOOR="${CHUMP_PILLAR_FLOOR:-2}"
OVERWEIGHT_PCT="${CHUMP_PILLAR_OVERWEIGHT_PCT:-50}"

# Bail-out override
if [[ "${CHUMP_PILLAR_BALANCE_CHECK:-1}" == "0" ]]; then
    echo "[pillar-balance-check] disabled via CHUMP_PILLAR_BALANCE_CHECK=0"
    exit 0
fi

# ── Locate chump binary ────────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -n "$CHUMP_BIN" ]] && [[ ! -x "$CHUMP_BIN" ]] && [[ ! -x "$REPO_ROOT/$CHUMP_BIN" ]]; then
    echo "WARN: \$CHUMP_BIN='$CHUMP_BIN' not executable; falling through to discovery" >&2
    CHUMP_BIN=""
fi
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/release/chump" ]]; then
        CHUMP_BIN="$CARGO_TARGET_DIR/release/chump"
    elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
        CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "ERROR: chump binary not found (set CHUMP_BIN or run cargo build)" >&2
        exit 2
    fi
fi

# ── Ensure ambient log directory exists ───────────────────────────────────────
mkdir -p "$(dirname "$AMBIENT_LOG")"

# ── Fetch gap list JSON ────────────────────────────────────────────────────────
gap_json=""
gap_json="$("$CHUMP_BIN" gap list --status open --json 2>/dev/null)" || {
    echo "ERROR: 'chump gap list --status open --json' failed" >&2
    exit 2
}

# ── Count pickable gaps per pillar via python3 ────────────────────────────────
# Pickable = P0|P1, effort xs|s|m, non-empty acceptance_criteria, empty/[] depends_on
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found — required for JSON parsing" >&2
    exit 2
fi

PY_SCRIPT="$(mktemp /tmp/pillar-balance-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" << 'PYEOF'
import sys, json

floor = int(sys.argv[1])
overweight_pct = int(sys.argv[2])
data = sys.stdin.read().strip()

if not data:
    gaps = []
else:
    parsed = json.loads(data)
    if isinstance(parsed, list):
        gaps = parsed
    elif isinstance(parsed, dict) and 'gaps' in parsed:
        gaps = parsed['gaps']
    else:
        gaps = []

PILLARS = ['EFFECTIVE', 'CREDIBLE', 'RESILIENT', 'ZERO-WASTE']
counts = {'EFFECTIVE': 0, 'CREDIBLE': 0, 'RESILIENT': 0, 'ZERO-WASTE': 0}
total = 0

for g in gaps:
    priority = g.get('priority', '')
    effort   = g.get('effort', '')
    ac       = (g.get('acceptance_criteria') or '').strip()
    deps     = (g.get('depends_on') or '[]').strip()
    title    = (g.get('title') or '').upper()

    if priority not in ('P0', 'P1'):
        continue
    if effort not in ('xs', 's', 'm'):
        continue
    if not ac:
        continue
    if deps and deps != '[]':
        continue

    total += 1
    for pillar in PILLARS:
        if pillar in title:
            counts[pillar] += 1
            break

for p in PILLARS:
    print("PILLAR:{}:{}".format(p, counts[p]))
print("TOTAL:{}".format(total))
PYEOF

read_counts="$(printf '%s' "$gap_json" | python3 "$PY_SCRIPT" "$FLOOR" "$OVERWEIGHT_PCT")"

# ── Parse python3 output (Bash 3.2 — no declare -A) ──────────────────────────
cnt_EFFECTIVE=0
cnt_CREDIBLE=0
cnt_RESILIENT=0
cnt_ZW=0
total_pickable=0

while IFS= read -r line; do
    case "$line" in
        PILLAR:EFFECTIVE:*)  cnt_EFFECTIVE="${line##PILLAR:EFFECTIVE:}" ;;
        PILLAR:CREDIBLE:*)   cnt_CREDIBLE="${line##PILLAR:CREDIBLE:}" ;;
        PILLAR:RESILIENT:*)  cnt_RESILIENT="${line##PILLAR:RESILIENT:}" ;;
        PILLAR:ZERO-WASTE:*) cnt_ZW="${line##PILLAR:ZERO-WASTE:}" ;;
        TOTAL:*)             total_pickable="${line##TOTAL:}" ;;
    esac
done << COUNTS_EOF
$read_counts
COUNTS_EOF

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ALERTS_FIRED=0

# Helper: append JSON event to ambient.jsonl
emit_event() {
    printf '%s\n' "$1" >> "$AMBIENT_LOG"
}

# ── Under-floor alerts (any pillar < FLOOR) ───────────────────────────────────
for entry in "EFFECTIVE:$cnt_EFFECTIVE" "CREDIBLE:$cnt_CREDIBLE" "RESILIENT:$cnt_RESILIENT" "ZERO-WASTE:$cnt_ZW"; do
    pillar="${entry%%:*}"
    cnt="${entry##*:}"
    if [[ "${cnt:-0}" -lt "$FLOOR" ]]; then
        emit_event "{\"ts\":\"$TS\",\"kind\":\"pillar_balance_alert\",\"pillar\":\"$pillar\",\"count\":${cnt:-0},\"floor\":$FLOOR,\"total_pickable\":${total_pickable:-0}}"
        echo "ALERT: pillar $pillar underweight — count=${cnt:-0} (floor=$FLOOR)" >&2
        ALERTS_FIRED=1
    fi
done

# ── Overweight alerts (any pillar > OVERWEIGHT_PCT% of total) ─────────────────
if [[ "${total_pickable:-0}" -gt 0 ]]; then
    for entry in "EFFECTIVE:$cnt_EFFECTIVE" "CREDIBLE:$cnt_CREDIBLE" "RESILIENT:$cnt_RESILIENT" "ZERO-WASTE:$cnt_ZW"; do
        pillar="${entry%%:*}"
        cnt="${entry##*:}"
        pct=$(( ${cnt:-0} * 100 / total_pickable ))
        if [[ "$pct" -gt "$OVERWEIGHT_PCT" ]]; then
            emit_event "{\"ts\":\"$TS\",\"kind\":\"pillar_balance_overweight\",\"pillar\":\"$pillar\",\"count\":${cnt:-0},\"pct\":$pct,\"total_pickable\":${total_pickable:-0}}"
            echo "ALERT: pillar $pillar overweight — ${pct}% of ${total_pickable} pickable (threshold=${OVERWEIGHT_PCT}%)" >&2
            ALERTS_FIRED=1
        fi
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "Pillar balance: EFFECTIVE=${cnt_EFFECTIVE:-0} CREDIBLE=${cnt_CREDIBLE:-0} RESILIENT=${cnt_RESILIENT:-0} ZERO-WASTE=${cnt_ZW:-0}  (of ${total_pickable:-0} pickable)"
if [[ "$ALERTS_FIRED" -eq 0 ]]; then
    echo "  OK: all pillars within balance thresholds (floor=$FLOOR, overweight>${OVERWEIGHT_PCT}%)"
fi

exit "$ALERTS_FIRED"
