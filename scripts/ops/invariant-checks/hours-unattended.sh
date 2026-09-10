#!/usr/bin/env bash
# scripts/ops/invariant-checks/hours-unattended.sh — RESILIENT-1105
#
# Invariant probe for the invariant-guard (RESILIENT-1104): how many hours the
# fleet can currently run UNATTENDED before it stalls (the durability gauge).
# Prints ONE token: the measured hours-before-stall, or "NA" to SKIP.
#
# ── STUB, PENDING PR #4589 ────────────────────────────────────────────────────
# The durability gauge that measures hours-unattended-before-stall is PR #4589,
# which is NOT merged as of RESILIENT-1105. Rather than block the whole Ratchet
# on it, this probe is a CLEARLY-MARKED STUB: it returns "NA" (the guard SKIPs,
# never pages) UNTIL either (a) #4589 lands and writes the gauge file this probe
# reads, or (b) the test/override hook supplies a value.
#
# When #4589 merges: point CHUMP_DURABILITY_GAUGE_FILE at its emitted JSON (or
# replace the read below with the gauge's real accessor) and DELETE the stub
# banner. The registry row + floor threshold are already wired, so the invariant
# goes live the moment this probe returns a real number — no guard change needed.
#
# Test hook: CHUMP_INVARIANT_HOURS_UNATTENDED_OVERRIDE=<number|NA>.
set -uo pipefail

if [[ -n "${CHUMP_INVARIANT_HOURS_UNATTENDED_OVERRIDE:-}" ]]; then
    printf '%s\n' "$CHUMP_INVARIANT_HOURS_UNATTENDED_OVERRIDE"
    exit 0
fi

# Best-effort: if #4589's gauge file already exists on this node, read it.
GAUGE_FILE="${CHUMP_DURABILITY_GAUGE_FILE:-$HOME/.chump/metrics/durability-gauge.json}"
if [[ -f "$GAUGE_FILE" ]]; then
    hours="$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    h = d.get("hours_unattended_before_stall", d.get("hours_unattended", None))
    print(f"{float(h):.1f}" if h is not None else "NA")
except Exception:
    print("NA")
' "$GAUGE_FILE" 2>/dev/null || echo NA)"
    printf '%s\n' "${hours:-NA}"
    exit 0
fi

# No gauge yet (PR #4589 unmerged) → skip, do not page.
echo "NA"
