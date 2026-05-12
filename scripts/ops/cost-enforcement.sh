#!/usr/bin/env bash
# cost-enforcement.sh — INFRA-877
#
# Evaluates daily spend vs CHUMP_DAILY_BUDGET_USD and:
#   - Emits kind=cost_quota_warning  when spend ≥ 80% of daily budget
#   - Emits kind=cost_quota_exceeded when spend ≥ 100% of daily budget
#   - Exits 1 when budget is exceeded (for use as a spawn gate)
#
# Usage:
#   cost-enforcement.sh [--dry-run] [--json]
#
# Options:
#   --dry-run   Print results, do NOT emit to ambient.jsonl or exit 1
#   --json      Output JSON summary to stdout
#
# Environment:
#   REPO_ROOT                Repo root (default: auto-detected)
#   CHUMP_DAILY_BUDGET_USD   Daily budget in USD (default: 5.00)
#   CHUMP_AMBIENT_LOG        Path to ambient.jsonl
#   DRY_RUN                  If "1", suppress writes and non-zero exits

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
BUDGET_USD="${CHUMP_DAILY_BUDGET_USD:-5.00}"
DRY_RUN="${DRY_RUN:-0}"
JSON_OUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --json)    JSON_OUT=1; shift ;;
        --budget)  BUDGET_USD="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

# ── Compute today's spend from session_end events ─────────────────────────────
SPEND_JSON=$(python3 - <<PYEOF
import json, os, sys
from datetime import datetime, timezone

amb_path = "$AMB"
budget   = float("$BUDGET_USD")

now       = datetime.now(timezone.utc)
today_str = now.strftime("%Y-%m-%d")  # e.g. "2026-05-12"
today_start_unix = int(now.timestamp()) - (int(now.timestamp()) % 86400)

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.rstrip("Z")).replace(tzinfo=timezone.utc)
    except Exception:
        return None

total_spend = 0.0
sessions_today = 0

if os.path.exists(amb_path):
    with open(amb_path) as f:
        for line in f:
            line = line.strip()
            if not line or "session_end" not in line:
                continue
            try:
                ev = json.loads(line)
                if ev.get("kind") != "session_end":
                    continue
                ts = parse_ts(ev.get("ts", ""))
                if not ts:
                    continue
                # Only today's events (UTC)
                if ts.strftime("%Y-%m-%d") != today_str:
                    continue
                cost = float(ev.get("cost_usd", 0) or ev.get("total_cost_usd", 0) or 0)
                total_spend += cost
                sessions_today += 1
            except Exception:
                pass

budget_used_pct = (total_spend / budget * 100.0) if budget > 0 else 0.0
status = "ok"
if total_spend >= budget:
    status = "exceeded"
elif total_spend >= budget * 0.80:
    status = "warning"

print(json.dumps({
    "today_spend_usd":  round(total_spend, 6),
    "budget_usd":       budget,
    "budget_used_pct":  round(budget_used_pct, 2),
    "sessions_today":   sessions_today,
    "status":           status,
    "date_utc":         today_str,
}))
PYEOF
)

if [[ -z "$SPEND_JSON" ]]; then
    echo "Error: failed to compute spend" >&2
    exit 1
fi

SPEND_USD=$(echo "$SPEND_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['today_spend_usd'])")
PCT=$(echo "$SPEND_JSON"       | python3 -c "import json,sys; print(json.load(sys.stdin)['budget_used_pct'])")
STATUS=$(echo "$SPEND_JSON"    | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")

# ── Emit events ───────────────────────────────────────────────────────────────
_emit() {
    local json="$1"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would emit: $json" >&2
    else
        mkdir -p "$(dirname "$AMB")"
        printf '%s\n' "$json" >> "$AMB"
    fi
}

TS="$(_ts)"

if [[ "$STATUS" == "exceeded" ]]; then
    _emit "{\"ts\":\"$TS\",\"kind\":\"cost_quota_exceeded\",\"cost_so_far_usd\":$SPEND_USD,\"limit_usd\":$BUDGET_USD,\"budget_used_pct\":$PCT,\"host\":\"$HOST\"}"
    echo "QUOTA EXCEEDED: \$${SPEND_USD} of \$${BUDGET_USD} daily budget (${PCT}%)" >&2
elif [[ "$STATUS" == "warning" ]]; then
    _emit "{\"ts\":\"$TS\",\"kind\":\"cost_quota_warning\",\"cost_so_far_usd\":$SPEND_USD,\"limit_usd\":$BUDGET_USD,\"budget_used_pct\":$PCT,\"host\":\"$HOST\"}"
    echo "QUOTA WARNING: \$${SPEND_USD} of \$${BUDGET_USD} daily budget (${PCT}%)" >&2
fi

# ── JSON output ───────────────────────────────────────────────────────────────
if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s\n' "$SPEND_JSON"
else
    echo "budget_used_pct=${PCT}%  spend=\$${SPEND_USD}  limit=\$${BUDGET_USD}  status=${STATUS}"
fi

# ── Exit non-zero when budget exceeded (spawn gate) ───────────────────────────
if [[ "$STATUS" == "exceeded" && "$DRY_RUN" -eq 0 ]]; then
    exit 1
fi
