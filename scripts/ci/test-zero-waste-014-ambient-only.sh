#!/usr/bin/env bash
# ZERO-WASTE-014: stuck-pr-filer and quartermaster emit ambient events and do
# NOT call `chump gap reserve` unless CHUMP_NOISE_GAP_FILING=1.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
# 1. stuck-pr-filer: source file_stuck_gap with a chump stub that logs reserves.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TMP/chump.log"
echo INFRA-9999
STUB
chmod +x "$TMP/bin/chump"
fn=$(awk '/^file_stuck_gap\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/scripts/ops/stuck-pr-filer.sh")
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
PATH="$TMP/bin:$PATH" bash -c "
DRY_RUN=0; FILED=0; NOISE_GAP_FILING=0; info(){ :; }; warn(){ :; }; dry(){ :; }
$fn
file_stuck_gap 123 'CI red for 90m' 'sum' 'det' CI-RED
"
if grep -q reserve "$TMP/chump.log" 2>/dev/null; then echo "FAIL: stuck-pr-filer filed a gap"; fail=1; else echo "PASS: stuck-pr-filer filed no gap"; fi
if grep -q '"kind":"stuck_pr"' "$TMP/ambient.jsonl"; then echo "PASS: stuck_pr ambient emitted"; else echo "FAIL: no stuck_pr event"; fail=1; fi
# 2. static guards: shepherd and quartermaster gate gap filing on the flag.
grep -q 'kind":"ci_failure"' "$REPO/scripts/coord/pr-shepherd-daemon.sh" && echo "PASS: shepherd emits ci_failure" || { echo "FAIL: shepherd"; fail=1; }
grep -c 'CHUMP_NOISE_GAP_FILING' "$REPO/scripts/coord/quartermaster-audit-loop.sh" | awk '$1>=2{ok=1} END{exit !ok}' && echo "PASS: quartermaster gated" || { echo "FAIL: quartermaster"; fail=1; }
exit $fail
