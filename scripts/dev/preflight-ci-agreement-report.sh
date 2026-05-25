#!/usr/bin/env bash
# preflight-ci-agreement-report.sh — INFRA-1927: weekly rollup of local-preflight
# vs CI agreement rate.
#
# Scans .chump-locks/ambient.jsonl for the last 7 days, joins
# kind=preflight_ci_agreement + kind=preflight_ci_agreement_resolved events by sha,
# and prints a summary:
#   {total_pushes, both_pass_count, both_fail_count,
#    local_pass_ci_fail_count, local_fail_ci_pass_count, agreement_pct}
#
# Usage:
#   scripts/dev/preflight-ci-agreement-report.sh          # text output
#   scripts/dev/preflight-ci-agreement-report.sh --json   # JSON output
#   scripts/dev/preflight-ci-agreement-report.sh --days N # window (default 7)
#
# Env:
#   CHUMP_AMBIENT_LOG  — override ambient path (default .chump-locks/ambient.jsonl)
#
# Exit codes:
#   0 — success (even if 0 events — zero events is valid baseline)
#   1 — error (ambient log missing, python3 missing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
JSON_MODE=0
DAYS=7

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   JSON_MODE=1; shift ;;
        --days)   DAYS="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,20p' "$0"
            exit 0 ;;
        *)
            echo "preflight-ci-agreement-report.sh: unknown arg: $1" >&2
            exit 1 ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "preflight-ci-agreement-report.sh: python3 required" >&2
    exit 1
fi

if [[ ! -f "$AMBIENT_LOG" ]]; then
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"total_pushes":0,"both_pass_count":0,"both_fail_count":0,"local_pass_ci_fail_count":0,"local_fail_ci_pass_count":0,"agreement_pct":null,"note":"ambient log not found"}\n'
    else
        echo "preflight-ci-agreement-report: no ambient log at $AMBIENT_LOG (0 events)"
    fi
    exit 0
fi

REPORT="$(AMBIENT_LOG="$AMBIENT_LOG" DAYS="$DAYS" JSON_MODE="$JSON_MODE" python3 - <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

ambient_path = os.environ["AMBIENT_LOG"]
days = int(os.environ.get("DAYS", "7"))
json_mode = os.environ.get("JSON_MODE", "0") == "1"

cutoff = datetime.now(timezone.utc) - timedelta(days=days)

# Read ambient.jsonl.
pending = {}    # sha -> preflight_pass (bool)
resolved = {}   # sha -> {ci_pass, mismatch}

try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            kind = obj.get("kind", "")
            ts_str = obj.get("ts", "")
            try:
                ts = datetime.fromisoformat(ts_str.rstrip("Z")).replace(tzinfo=timezone.utc)
                if ts < cutoff:
                    continue
            except Exception:
                continue  # keep if ts unparseable (be lenient)
            sha = obj.get("sha", "")
            if not sha:
                continue
            if kind == "preflight_ci_agreement":
                pp = obj.get("preflight_pass", False)
                if isinstance(pp, str):
                    pp = pp.lower() == "true"
                pending[sha] = pp
            elif kind == "preflight_ci_agreement_resolved":
                cp = obj.get("ci_pass", False)
                if isinstance(cp, str):
                    cp = cp.lower() == "true"
                mm = obj.get("mismatch", False)
                if isinstance(mm, str):
                    mm = mm.lower() == "true"
                resolved[sha] = {"ci_pass": cp, "mismatch": mm}
except Exception as e:
    if json_mode:
        print(json.dumps({"error": str(e)}))
    else:
        print(f"preflight-ci-agreement-report: error reading ambient log: {e}", file=sys.stderr)
    sys.exit(1)

# Join by sha: only count shas that appear in BOTH events.
joined_shas = set(pending.keys()) & set(resolved.keys())
total_pushes = len(joined_shas)
both_pass_count = 0
both_fail_count = 0
local_pass_ci_fail_count = 0
local_fail_ci_pass_count = 0

for sha in joined_shas:
    pf_pass = pending[sha]
    ci_pass = resolved[sha]["ci_pass"]
    if pf_pass and ci_pass:
        both_pass_count += 1
    elif not pf_pass and not ci_pass:
        both_fail_count += 1
    elif pf_pass and not ci_pass:
        local_pass_ci_fail_count += 1
    else:
        local_fail_ci_pass_count += 1

if total_pushes > 0:
    agreement_pct = round(100.0 * (both_pass_count + both_fail_count) / total_pushes, 1)
else:
    agreement_pct = None

unresolved_count = len(set(pending.keys()) - set(resolved.keys()))

if json_mode:
    out = {
        "total_pushes": total_pushes,
        "both_pass_count": both_pass_count,
        "both_fail_count": both_fail_count,
        "local_pass_ci_fail_count": local_pass_ci_fail_count,
        "local_fail_ci_pass_count": local_fail_ci_pass_count,
        "agreement_pct": agreement_pct,
        "unresolved_count": unresolved_count,
        "window_days": days,
    }
    print(json.dumps(out))
else:
    print(f"Preflight↔CI Agreement Report  (last {days} days)")
    print(f"  Total resolved pushes  : {total_pushes}")
    print(f"  Both pass              : {both_pass_count}")
    print(f"  Both fail              : {both_fail_count}")
    print(f"  Local pass, CI fail    : {local_pass_ci_fail_count}  (preflight overconfident)")
    print(f"  Local fail, CI pass    : {local_fail_ci_pass_count}  (preflight overcautious)")
    if agreement_pct is not None:
        print(f"  Agreement              : {agreement_pct}%  (target ≥ 95%)")
        if agreement_pct < 95.0:
            print(f"  WARNING: agreement below 95% — preflight needs calibration")
    else:
        print(f"  Agreement              : N/A (no resolved events yet)")
    if unresolved_count > 0:
        print(f"  Pending (CI not yet complete): {unresolved_count}")
PYEOF
)"

printf '%s\n' "$REPORT"
