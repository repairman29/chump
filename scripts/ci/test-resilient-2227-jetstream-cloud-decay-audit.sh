#!/usr/bin/env bash
# RESILIENT-2227: decay audit must flag JetStream-off, CLOUD-stream-missing and
# fleet-recorder-dark, and pass cleanly when all three are healthy.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT="$ROOT/scripts/ops/jetstream-cloud-decay-audit.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# Stub nats CLI: behavior driven by STUB_JS (on|off) and STUB_STREAM (yes|no).
cat > "$T/nats" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"account info"*) [ "${STUB_JS:-on}" = off ] && { echo "JetStream Account Information: not enabled"; exit 0; }; echo "JetStream Account Information: Memory: 0 B"; exit 0 ;;
  *"stream info"*) [ "${STUB_STREAM:-yes}" = yes ] && exit 0 || exit 1 ;;
esac
exit 0
S
chmod +x "$T/nats"
export CHUMP_DECAY_NATS_BIN="$T/nats" CHUMP_AMBIENT_LOG="$T/ambient.jsonl"

run() { STUB_JS="$1" STUB_STREAM="$2" CHUMP_DECAY_RECORDER_ACTIVE_CMD="$3" bash "$AUDIT" >"$T/out" 2>&1; echo $?; }

[ "$(run on yes true)" = 0 ] && ok "healthy -> exit 0" || bad "healthy should exit 0"
[ ! -s "$T/ambient.jsonl" ] && ok "healthy emits nothing" || bad "healthy emitted ambient"

[ "$(run off yes true)" = 1 ] && grep -q jetstream_off "$T/ambient.jsonl" && ok "JetStream off flagged" || bad "JetStream off not flagged"
: > "$T/ambient.jsonl"
[ "$(run on no true)" = 1 ] && grep -q cloud_stream_missing "$T/ambient.jsonl" && ok "CLOUD stream missing flagged" || bad "CLOUD missing not flagged"
: > "$T/ambient.jsonl"
[ "$(run on yes false)" = 1 ] && grep -q fleet_recorder_dark "$T/ambient.jsonl" && ok "recorder dark flagged" || bad "recorder dark not flagged"

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
