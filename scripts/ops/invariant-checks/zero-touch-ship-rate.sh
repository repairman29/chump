#!/usr/bin/env bash
# scripts/ops/invariant-checks/zero-touch-ship-rate.sh — RESILIENT-1105
#
# Invariant probe for the invariant-guard (RESILIENT-1104). Prints ONE token on
# stdout: the current autonomous (zero-touch) PR ship rate as a PERCENT (e.g.
# "12.5"), or the literal "NA" when the metric cannot be computed right now
# (offline, no gh, no merged PRs). "NA" makes the guard SKIP — it must never
# false-page just because the network was down.
#
# This is a thin wrapper over the canonical metric source
# (scripts/dispatch/autonomous-ship-rate.sh, CREDIBLE-047) — mine-before-build:
# the rate, the baseline (12.5%), and the fleet-identity classification already
# live there. We only re-shape its JSON `autonomous_rate` (0.0-1.0) into the
# percent the registry's floor threshold (12.5) is expressed in.
#
# Test hook: CHUMP_INVARIANT_SHIP_RATE_OVERRIDE=<number|NA> short-circuits the
# live call so the guard's compare/emit/page path can be exercised hermetically
# (this is how the regression-injection validation drives 12.5 -> 0.0).
set -uo pipefail

if [[ -n "${CHUMP_INVARIANT_SHIP_RATE_OVERRIDE:-}" ]]; then
    printf '%s\n' "$CHUMP_INVARIANT_SHIP_RATE_OVERRIDE"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ASR="$REPO_ROOT/scripts/dispatch/autonomous-ship-rate.sh"

if [[ ! -x "$ASR" && ! -f "$ASR" ]]; then
    echo "NA"; exit 0
fi

# --dry-run: never let the probe mutate the metrics file (the guard reads, it
# does not sample). --json: one machine row we can parse for autonomous_rate.
row="$(bash "$ASR" --json --dry-run 2>/dev/null || true)"
if [[ -z "$row" ]]; then
    echo "NA"; exit 0
fi

pct="$(printf '%s' "$row" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get("autonomous_rate", None)
    ff = d.get("fleet_filed", 0)
    # No fleet-filed PRs in the window means the rate is undefined, not 0% —
    # emit NA so the guard skips rather than pages a meaningless floor breach.
    if r is None or ff in (0, "0"):
        print("NA")
    else:
        print(f"{float(r) * 100:.1f}")
except Exception:
    print("NA")
' 2>/dev/null || echo NA)"

printf '%s\n' "${pct:-NA}"
