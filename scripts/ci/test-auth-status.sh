#!/usr/bin/env bash
# Regression test for auth-status.sh (RESILIENT-086) — the fleet-auth VALIDITY check.
# Exercises the verdict logic via injected probe states (CHUMP_AUTH_STATUS_FAKE_*),
# so it runs offline + fast. The headline case is THE TRAP: a depleted credential
# winning precedence over a valid one — the thing every new agent re-discovers.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
SCRIPT="$ROOT/scripts/coord/auth-status.sh"
[[ -x "$SCRIPT" ]] || { echo "[test] FAIL: auth-status.sh not executable"; exit 1; }
[[ "$(bash -n "$SCRIPT" 2>&1)" == "" ]] || { echo "[test] FAIL: syntax error"; exit 1; }

fail=0
check() { # desc expected-exit expected-substr  mode oauth-state apikey-state
    local desc="$1" eexit="$2" esub="$3" mode="$4" oa="$5" ak="$6"
    local c out rc
    c="$(mktemp -t authcache.XXXXXX)"
    out="$(CHUMP_AUTH_STATUS_CACHE="$c" CHUMP_AUTH_STATUS_FAKE_MODE="$mode" \
        CHUMP_AUTH_STATUS_FAKE_OAUTH="$oa" CHUMP_AUTH_STATUS_FAKE_APIKEY="$ak" \
        bash "$SCRIPT" --probe 2>&1)"
    rc=$?
    rm -f "$c"
    if [[ "$rc" == "$eexit" ]] && printf '%s' "$out" | grep -qF "$esub"; then
        echo "[test] PASS: $desc (exit $rc)"
    else
        echo "[test] FAIL: $desc — want exit=$eexit substr='$esub', got exit=$rc: $out"; fail=1
    fi
}

#      desc                                       exit  substring             mode    oauth    apikey
check "oauth valid, api-key absent -> OK"            0  "workers can transact" auto    valid    absent
check "oauth absent, api-key valid -> OK"           0  "workers can transact" auto    absent   valid
check "mode=oauth, oauth valid (api-key depleted)"  0  "workers can transact" oauth   valid    depleted
# THE TRAP — depleted api-key wins precedence over a valid oauth:
check "TRAP: api-key depleted but oauth valid"      2  "TRAP"                 auto    valid    depleted
check "TRAP names the fix (retire api-key)"         2  "unsetenv ANTHROPIC_API_KEY" auto valid depleted
# Genuine outages still fail loudly with the right fix:
check "BROKEN: api-key out of credits, no oauth"    1  "OUT OF CREDITS"       auto    absent   depleted
check "BROKEN: no credentials at all"               1  "no credentials"       auto    absent   absent
check "BROKEN: both invalid"                        1  "none usable"          auto    invalid  invalid

[[ "$fail" -eq 0 ]] && echo "[test-auth-status] PASS" || { echo "[test-auth-status] FAIL"; exit 1; }
