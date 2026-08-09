#!/usr/bin/env bash
# RESILIENT-266: guard the Discord gateway daemon's install + liveness.
#
# WHAT THIS IS GUARDING AGAINST, stated plainly so nobody weakens it later:
# ~/.chump/operator-recall.toml has said `enabled = true` since 2026-05-08 with
# ZERO processes running, against a stale pidfile pointing at PID 2407. Nobody
# noticed for three months, because nothing checked. PR #3510 was destroyed
# while that channel was nominally "enabled".
#
# So these assertions are about the properties that make a daemon HONEST —
# it refuses to double-start, it detects its own absence, and its alarm does
# not travel through the thing being alarmed about.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Strip comments and blank lines before asserting. Learned the hard way on the
# first run of this very file: two assertions failed because the scripts
# mention `pgrep -c` and `StartInterval` in comments WARNING AGAINST them. A
# grep-based structural test that reads comments as code is the same defect
# class as CREDIBLE-237's path-pinned gates — it fails on prose, not behaviour.
code() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }

echo "=== RESILIENT-266: discord gateway daemon ==="

RUN="$REPO_ROOT/scripts/coord/discord-gateway-run.sh"
LIVE="$REPO_ROOT/scripts/coord/discord-gateway-liveness.sh"
INSTALL="$REPO_ROOT/scripts/setup/install-discord-gateway.sh"

for f in "$RUN" "$LIVE" "$INSTALL"; do
    [[ -f "$f" ]] && ok "exists: ${f#"$REPO_ROOT"/}" || bad "missing: ${f#"$REPO_ROOT"/}"
done

# 1. THE ALARM MUST NOT DEPEND ON THE THING IT CHECKS. If liveness ever routes
#    through the gateway, it goes quiet exactly when it matters.
if grep -q "notify-operator.sh" "$LIVE"; then
    ok "liveness alarms via notify-operator (REST, needs no gateway)"
else
    bad "liveness does not use the REST alarm path — it may go silent when the gateway dies"
fi

# 2. Duplicate instances make Chump reply to EVERY message twice, and the
#    symptom reads like a model bug rather than an ops mistake.
if grep -q "PIDFILE" "$RUN" && grep -q "kill -0" "$RUN"; then
    ok "runner refuses a second instance and validates the PID is alive"
else
    bad "no live-PID duplicate guard — two gateways will double-reply to everything"
fi

# 3. A stale pidfile must never be treated as 'running'. That exact confusion
#    is what made operator-recall look healthy for three months.
if grep -q "clearing stale pidfile" "$RUN"; then
    ok "stale pidfile is cleared, not trusted"
else
    bad "stale pidfile may be mistaken for a live process"
fi

# 4. macOS BSD pgrep has no -c, and `pgrep -c ... || echo 0` turns the error
#    into a FALSE ZERO — which would report the gateway down while it runs.
if code "$LIVE" | grep -q "pgrep -c"; then
    bad "liveness uses pgrep -c (no such flag on BSD/macOS — yields a false zero)"
else
    ok "liveness counts without pgrep -c"
fi

# 5. KeepAlive, not StartInterval — this is a long-running gateway.
#    Assert on the actual plist KEYS, not loose words. The first version of this
#    check matched "StartInterval" inside the plist's own XML comment
#    ("KeepAlive, not StartInterval"), which code() does not strip because it
#    only removes shell comments. Twice in one file, prose read as code.
if grep -q "<key>KeepAlive</key>" "$INSTALL" && ! grep -q "<key>StartInterval</key>" "$INSTALL"; then
    ok "plist uses KeepAlive (long-running), not StartInterval"
else
    bad "plist should use KeepAlive for a long-running gateway"
fi

# 6. Installing a daemon that cannot possibly work is the failure this gap is
#    about. The installer must verify the feature is actually compiled in.
if grep -q -- '--discord' "$INSTALL" && grep -q "not compiled in" "$INSTALL"; then
    ok "installer verifies the discord feature is compiled into the binary"
else
    bad "installer may install a daemon whose binary lacks the discord feature"
fi

# 7. Liveness must return non-zero when no gateway is running — behavioural,
#    not structural. Right now nothing is running, so it must report DOWN.
if bash "$LIVE" --quiet >/dev/null 2>&1; then
    # Exit 0 means it found a gateway. Only valid if one is genuinely running.
    n="$(pgrep -f 'chump.*--discord|chump-discord-gateway' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${n:-0}" -gt 0 ]]; then
        ok "liveness reports UP and a gateway is genuinely running (${n})"
    else
        bad "liveness reported UP with no gateway process — false green"
    fi
else
    ok "liveness returns non-zero when no gateway is running"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
echo "PASS"
