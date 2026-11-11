#!/usr/bin/env bash
# RESILIENT-270: transport fallback chain. Uses a stub curl (offline, hermetic);
# real-send proof per rung is recorded in docs/process/OPERATOR_TRANSPORTS.md.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# Stub curl: discord opens channel + posts; behaviour driven by env.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *discord.com* ]]; then
  [[ "${STUB_DISCORD:-ok}" == "down" ]] && { printf '000'; exit 7; }
  if [[ "$args" == *users/@me/channels* ]]; then printf '{"id":"123"}'; else printf '200'; fi
  exit 0
fi
if [[ "$args" == *api.telegram.org* ]]; then
  echo telegram >> "$STUB_LOG"; printf '%s' "${STUB_TG_CODE:-200}"; exit 0
fi
exit 1
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" STUB_LOG="$T/calls"
export CHUMP_AMBIENT_LOG="$T/ambient.jsonl" CHUMP_OPERATOR_AUTOPOST_DM=1
export DISCORD_TOKEN=x CHUMP_READY_DM_USER_ID=1 TELEGRAM_BOT_TOKEN=y TELEGRAM_CHAT_ID=2
export CHUMP_NOTIFY_KIND=discord_command_reply CHUMP_NOTIFY_RATE_CEILING=999 CHUMP_NOTIFY_RATE_LOG="$T/rate.log"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/coord/lib/notify-operator.sh"

echo "=== RESILIENT-270: transport fallback ==="

: > "$T/calls"; : > "$CHUMP_AMBIENT_LOG"
STUB_DISCORD=ok notify_operator "hello" 2>/dev/null
[[ ! -s "$T/calls" ]] && ok "discord healthy -> telegram not used" || bad "telegram used despite discord ok"

: > "$T/calls"; : > "$CHUMP_AMBIENT_LOG"
STUB_DISCORD=down notify_operator "hello"; rc=$?
[[ $rc -eq 0 ]] && ok "discord down -> delivered via telegram (rc 0)" || bad "fallback failed rc=$rc"
grep -q '"kind":"operator_transport_failed".*"transport":"discord"' "$CHUMP_AMBIENT_LOG" \
  && ok "discord failure recorded in ambient" || bad "discord failure NOT recorded"
grep -q 'operator_transport_fellthrough' "$CHUMP_AMBIENT_LOG" \
  && ok "fellthrough event recorded" || bad "no fellthrough event"

: > "$CHUMP_AMBIENT_LOG"
STUB_DISCORD=down STUB_TG_CODE=500 notify_operator "hello"; rc=$?
[[ $rc -eq 1 ]] && ok "all rungs fail -> rc 1" || bad "expected rc 1 got $rc"
grep -q 'operator_transport_exhausted' "$CHUMP_AMBIENT_LOG" \
  && ok "exhausted event recorded" || bad "no exhausted event"

: > "$T/calls"
CHUMP_NOTIFY_TRANSPORTS=telegram notify_operator "hello" 2>/dev/null
[[ -s "$T/calls" ]] && ok "CHUMP_NOTIFY_TRANSPORTS selects transport at runtime" || bad "config order ignored"

unset DISCORD_TOKEN TELEGRAM_BOT_TOKEN
CHUMP_HOME="$T/none" notify_operator "hello" 2>/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "nothing configured -> silent no-op rc 0" || bad "unconfigured rc=$rc"

echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
