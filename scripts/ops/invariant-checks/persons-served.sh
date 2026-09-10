#!/usr/bin/env bash
# scripts/ops/invariant-checks/persons-served.sh — RESILIENT-1105
#
# Invariant probe for the invariant-guard (RESILIENT-1104): how many real people
# the fleet's output is currently serving — the ribbon metric the whole factory
# points at (the commercial/served-humans endpoint, per the factory-as-digital-
# twin vision). Prints ONE token: the count, or "NA" to SKIP.
#
# ── PLACEHOLDER ───────────────────────────────────────────────────────────────
# There is no persons-served telemetry wired yet, so this probe returns "NA"
# (the guard SKIPs — a placeholder floor must never page). It is registered NOW,
# at severity=warn, so the SLOT exists in the Ratchet the day the number becomes
# measurable: wire the real accessor here, and the floor starts guarding served-
# humans with zero guard/registry change. This is deliberate — the point of the
# Ratchet is that the metric that matters most already has its guard-rail bolted
# down and waiting, not bolted on after the first regression.
#
# Test hook: CHUMP_INVARIANT_PERSONS_SERVED_OVERRIDE=<number|NA>.
set -uo pipefail

if [[ -n "${CHUMP_INVARIANT_PERSONS_SERVED_OVERRIDE:-}" ]]; then
    printf '%s\n' "$CHUMP_INVARIANT_PERSONS_SERVED_OVERRIDE"
    exit 0
fi

echo "NA"
