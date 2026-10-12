#!/usr/bin/env bash
# RESILIENT-1573: smoke test for no-ship-loop-detector.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
A="$T/a.jsonl"
for i in 1 2 3 4 5 6; do echo "{\"event\":\"cycle_end\",\"ts\":\"2026-10-12T0$i:00:00Z\",\"gap_id\":\"X-1\",\"kind\":\"unverified_ship\"}" >> "$A"; done
for i in 1 2 3 4 5 6; do echo "{\"event\":\"cycle_end\",\"ts\":\"2026-10-12T0$i:00:00Z\",\"gap_id\":\"Y-1\",\"kind\":\"failed\"}" >> "$A"; done
echo '{"event":"cycle_end","ts":"2026-10-12T07:00:00Z","gap_id":"Y-1","kind":"shipped"}' >> "$A"
printf '#!/bin/bash\necho "$@" >> %s/chump.log\n' "$T" > "$T/chump"; chmod +x "$T/chump"
run() { CHUMP_AMBIENT_PATH="$A" CHUMP_NO_SHIP_LOOP_STATE_FILE="$T/s.json" CHUMP_NO_SHIP_LOOP_CHUMP_CMD="$T/chump" CHUMP_CRASH_LOOP_SYSTEMCTL=/nonexistent bash "$ROOT/scripts/coord/no-ship-loop-detector.sh" 2>/dev/null; }
run; run
[[ "$(grep -c 'gap set X-1 --status blocked' "$T/chump.log")" == 1 ]] || { echo FAIL block-once; exit 1; }
grep -q 'gap set Y-1' "$T/chump.log" && { echo FAIL shipped-gap-blocked; exit 1; }
[[ "$(grep -c 'gap reserve' "$T/chump.log")" == 1 ]] || { echo FAIL file-once; exit 1; }
echo '{"event":"cycle_end","ts":"2026-10-12T09:00:00Z","gap_id":"X-1","kind":"failed"}' >> "$A"
run
[[ "$(grep -c 'gap set X-1 --status blocked' "$T/chump.log")" == 2 ]] || { echo FAIL reblock; exit 1; }
[[ "$(grep -c 'gap reserve' "$T/chump.log")" == 1 ]] || { echo FAIL refile; exit 1; }
echo "PASS"
