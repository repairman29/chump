#!/usr/bin/env bash
# RESILIENT-270: guard the Discord → Telegram fallback chain in
# notify-operator.sh. Discord is the verified default (RESILIENT-263); this
# asserts that a CONFIGURED-but-FAILED Discord send (a) is itself recorded to
# ambient.jsonl rather than silently dropped, and (b) falls through to the
# Telegram rung when it is configured. Uses a fake `curl` on PATH so the test
# never touches the real network or real credentials.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-270: Discord -> Telegram fallback chain ==="

LIB="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
[[ -f "$LIB" ]] && ok "notify-operator.sh exists" || { bad "notify-operator.sh missing"; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1; }

FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$FAKEBIN"' EXIT

# mode: "discord_ok" | "discord_fail_telegram_ok" | "discord_fail_telegram_fail"
_make_fake_curl() {
    local mode="$1"
    cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *discord.com* ]]; then
    if [[ "\$args" == *"/channels"* && "\$args" != *"/messages"* ]]; then
        echo '{"id":"chan1"}'
    elif [[ "$mode" == "discord_ok" ]]; then
        echo -n "200"
    else
        echo -n "500"
    fi
elif [[ "\$args" == *telegram.org* ]]; then
    if [[ "$mode" == "discord_fail_telegram_ok" ]]; then
        echo -n "200"
    else
        echo -n "404"
    fi
fi
SH
    chmod +x "$FAKEBIN/curl"
}

_run_deliver() {
    local mode="$1" tg_configured="$2" log
    _make_fake_curl "$mode"
    log="$(mktemp)"
    PATH="$FAKEBIN:$PATH" bash -c "
        export CHUMP_AMBIENT_LOG='$log'
        export DISCORD_TOKEN=fake-discord-token
        export CHUMP_READY_DM_USER_ID=1
        if [[ '$tg_configured' == '1' ]]; then
            export TELEGRAM_BOT_TOKEN=fake-telegram-token
            export TELEGRAM_CHAT_ID=999
        else
            unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
        fi
        source '$LIB' 2>/dev/null
        _notify_deliver 'fallback probe message'
        echo RC=\$?
    " 2>/dev/null
    cat "$log"
    rm -f "$log"
}

# 1. Discord succeeds: no fallback attempted, no failure events emitted.
out="$(_run_deliver discord_ok 1)"
if grep -q "RC=0" <<<"$out" && ! grep -q "notify_discord_failed" <<<"$out"; then
    ok "Discord success delivers with no fallback events"
else
    bad "Discord-success path emitted unexpected events: [$out]"
fi

# 2. Discord fails, Telegram unconfigured: failure recorded, rung-unavailable
#    recorded, caller sees failure (rc != 0) — nothing must silently succeed.
out="$(_run_deliver discord_fail_telegram_fail 0)"
if grep -q "notify_discord_failed" <<<"$out" && grep -q "notify_fallback_unavailable" <<<"$out" && ! grep -q "RC=0" <<<"$out"; then
    ok "Discord failure with no fallback configured is recorded and NOT silently OK"
else
    bad "unconfigured-fallback path emitted [$out] — expected notify_discord_failed + notify_fallback_unavailable + nonzero rc"
fi

# 3. Discord fails, Telegram configured and succeeds: fallback delivers,
#    caller sees success, and the Discord failure is still on record (AC7 —
#    "the operator must be able to see that Discord was down").
out="$(_run_deliver discord_fail_telegram_ok 1)"
if grep -q "notify_discord_failed" <<<"$out" && grep -q "notify_fallback_delivered" <<<"$out" && grep -q "RC=0" <<<"$out"; then
    ok "Telegram fallback delivers after Discord fails, Discord failure stays on record"
else
    bad "fallback-delivered path emitted [$out] — expected notify_discord_failed + notify_fallback_delivered + rc=0"
fi

# 4. Both rungs fail: both failures recorded, caller sees failure.
out="$(_run_deliver discord_fail_telegram_fail 1)"
if grep -q "notify_discord_failed" <<<"$out" && grep -q "notify_fallback_failed" <<<"$out" && ! grep -q "RC=0" <<<"$out"; then
    ok "both rungs failing is recorded on both and surfaces as a failure"
else
    bad "both-fail path emitted [$out] — expected notify_discord_failed + notify_fallback_failed + nonzero rc"
fi

# 5. The Telegram bot token is never printed, same non-negotiable as Discord's.
if grep -nE '(echo|printf|say)[^|]*\$\{?(tg_token|TELEGRAM_BOT_TOKEN)' "$LIB" | grep -qv 'redacted'; then
    bad "notify-operator may print the Telegram token"
else
    ok "Telegram token is never echoed"
fi

# 6. Selection is config (env/.env), not a cargo feature — grep the lib for
#    any feature-gate reference; there must be none.
if grep -qE 'cfg\(feature|--features' "$LIB"; then
    bad "notify-operator.sh references a cargo feature — the default must be config-only (AC5)"
else
    ok "fallback selection has no cargo-feature dependency"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
echo "PASS"
