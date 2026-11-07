#!/usr/bin/env bash
# RESILIENT-1603: fleet-unit-failed-heal.sh restarts a failed unit once, files a gap on the second run.
set -uo pipefail
R="$(git rev-parse --show-toplevel)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/sc" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$SC_LOG"
[[ "$1" == list-units ]] && echo "chump-stuck.service loaded failed failed x"
exit 0
SH
cat > "$T/gap" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GAP_LOG"
SH
chmod +x "$T/sc" "$T/gap"
export SC_LOG="$T/sc.log" GAP_LOG="$T/gap.log" CHUMP_UNIT_HEAL_SYSTEMCTL="$T/sc" CHUMP_UNIT_HEAL_GAP_CMD="$T/gap" CHUMP_UNIT_HEAL_STATE_DIR="$T/state"
bash "$R/scripts/coord/fleet-unit-failed-heal.sh"
grep -q "restart chump-stuck.service" "$SC_LOG" || { echo "FAIL: no restart"; exit 1; }
[[ ! -s "$GAP_LOG" ]] || { echo "FAIL: gap filed on first failure"; exit 1; }
bash "$R/scripts/coord/fleet-unit-failed-heal.sh"
grep -q "chump-stuck.service" "$GAP_LOG" || { echo "FAIL: no gap on second failure"; exit 1; }
bash "$R/scripts/coord/fleet-unit-failed-heal.sh"
[[ "$(wc -l < "$GAP_LOG")" == 1 ]] || { echo "FAIL: gap refiled"; exit 1; }
echo "PASS"
