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
    # CHUMP_FREE_TIER_PROVIDERS forced empty: proves the RESILIENT-376 free-tier
    # branch is INERT on Claude nodes — every verdict below is unchanged.
    out="$(CHUMP_AUTH_STATUS_CACHE="$c" CHUMP_AUTH_STATUS_FAKE_MODE="$mode" \
        CHUMP_FREE_TIER_PROVIDERS="" \
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

# ── CREDIBLE-449: failure-class distinction (rate-limit / network vs auth) ───
# Each class needs a DIFFERENT fix; collapsing them into "unknown" hides that.
check "BROKEN: api-key rate-limited (429), no oauth"  1  "RATE LIMITED"         auto    absent   rate_limited
check "BROKEN: api-key network error, no oauth"       1  "NETWORK ERROR"        auto    absent   network_error
check "rate-limit does not read as OUT OF CREDITS"    1  "RATE LIMITED"         auto    absent   rate_limited

# ── CREDIBLE-146: cache-behavior regression ─────────────────────────────────
# A stale/bad cache silently froze the fleet for days (cached BROKEN kept the
# farmer paging AUTH_DEAD while oauth was valid). These run WITHOUT --probe so
# the cache path is actually exercised.
now="$(date +%s)"

# (a) A fresh, in-TTL cached BROKEN must NOT be served — re-probe (valid oauth -> OK).
c="$(mktemp -t authcache.XXXXXX)"
printf '%s\n1\nAUTH BROKEN — no credentials found. (stale)\n' "$now" > "$c"
out="$(CHUMP_AUTH_STATUS_CACHE="$c" CHUMP_AUTH_STATUS_FAKE_MODE=auto \
    CHUMP_AUTH_STATUS_FAKE_OAUTH=valid CHUMP_AUTH_STATUS_FAKE_APIKEY=absent \
    bash "$SCRIPT" 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] && printf '%s' "$out" | grep -qF "workers can transact" \
   && ! printf '%s' "$out" | grep -qF "(cached)"; then
    echo "[test] PASS: cached-BROKEN is re-probed fresh, never served"
else
    echo "[test] FAIL: cached-BROKEN must re-probe -> OK; got exit=$rc: $out"; fail=1
fi
rm -f "$c"

# (baseline) A fresh cached-OK verdict IS still served (cache still works).
c="$(mktemp -t authcache.XXXXXX)"
printf '%s\n0\nAUTH OK — cached probe (should be served)\n' "$now" > "$c"
out="$(CHUMP_AUTH_STATUS_CACHE="$c" bash "$SCRIPT" 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] && printf '%s' "$out" | grep -qF "(cached)"; then
    echo "[test] PASS: cached-OK verdict is served from cache"
else
    echo "[test] FAIL: cached-OK should be served; got exit=$rc: $out"; fail=1
fi
rm -f "$c"

# (c) --force busts even a fresh cached-OK (re-probes; no '(cached)' marker).
c="$(mktemp -t authcache.XXXXXX)"
printf '%s\n0\nAUTH OK — cached (should be bypassed by --force)\n' "$now" > "$c"
out="$(CHUMP_AUTH_STATUS_CACHE="$c" CHUMP_AUTH_STATUS_FAKE_MODE=auto \
    CHUMP_AUTH_STATUS_FAKE_OAUTH=valid CHUMP_AUTH_STATUS_FAKE_APIKEY=absent \
    bash "$SCRIPT" --force 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] && ! printf '%s' "$out" | grep -qF "(cached)"; then
    echo "[test] PASS: --force bypasses the cache"
else
    echo "[test] FAIL: --force should re-probe (no '(cached)'); got: $out"; fail=1
fi
rm -f "$c"

# (b) A credential file newer than the cache invalidates the cached verdict.
th="$(mktemp -d)"; mkdir -p "$th/.chump"; c="$th/.chump/auth-status-cache"
printf '%s\n0\nAUTH OK — stale cached (token is newer)\n' "$((now - 10))" > "$c"
sleep 1; : > "$th/.chump/oauth-token.json"   # token mtime now newer than cache
out="$(HOME="$th" CHUMP_AUTH_STATUS_CACHE="$c" CHUMP_AUTH_STATUS_FAKE_MODE=auto \
    CHUMP_AUTH_STATUS_FAKE_OAUTH=valid CHUMP_AUTH_STATUS_FAKE_APIKEY=absent \
    bash "$SCRIPT" 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] && ! printf '%s' "$out" | grep -qF "(cached)"; then
    echo "[test] PASS: credential newer than cache invalidates it"
else
    echo "[test] FAIL: newer token should bust cache; got: $out"; fail=1
fi
rm -rf "$th"

# ── RESILIENT-376: free-tier provider auth path (both-directions blast-radius) ─
# A $0 OpenAI-compatible provider is a usable auth path with NO Anthropic
# credential (the Pixel node case). The gate MUST open on a live provider AND
# stay byte-for-byte unchanged on Claude nodes (CHUMP_FREE_TIER_PROVIDERS empty).
FT_GROQ='openai/gpt-oss-120b@https://api.groq.com/openai/v1:GROQ_API_KEY'

ft() { # desc expected-exit expected-substr  providers key-value fake-http fake-oauth fake-apikey
    local desc="$1" eexit="$2" esub="$3" prov="$4" keyval="$5" http="$6" oa="$7" ak="$8"
    local c out rc
    c="$(mktemp -t authcache.XXXXXX)"
    out="$(CHUMP_AUTH_STATUS_CACHE="$c" \
        CHUMP_FREE_TIER_PROVIDERS="$prov" GROQ_API_KEY="$keyval" \
        CHUMP_AUTH_STATUS_FAKE_FREETIER_HTTP="$http" \
        CHUMP_AUTH_STATUS_FAKE_MODE=auto \
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

#    desc                                                  exit substr                 providers   key      http oauth   apikey
# (b) DIRECTION 1 — live free-tier provider → GREEN even with a broken/absent claude:
ft  "free-tier live provider -> GREEN (no anthropic)"        0  "free-tier provider live" "$FT_GROQ" "gsk_x"  200  invalid absent
ft  "free-tier GREEN even with NO anthropic creds at all"    0  "no Anthropic token"      "$FT_GROQ" "gsk_x"  200  absent  absent
# (a) DIRECTION 2 — CHUMP_FREE_TIER_PROVIDERS empty → branch inert, RED unchanged
#     (even though a fake 200 is injected, the empty guard means it never runs):
ft  "empty free-tier + broken claude -> still RED"           1  "no credentials"          ""         ""       200  absent  absent
# Guard corner cases (never a wrong-GREEN):
ft  "provider configured but DOWN (non-200) -> falls through" 1 "none usable"             "$FT_GROQ" "gsk_x"  503  invalid invalid
ft  "provider entry present but KEY_ENV empty -> skip -> RED" 1  "no credentials"          "$FT_GROQ" ""       200  absent  absent

# ── CREDIBLE-449: real status-code + body classification (not just injected
#    state) — exercises the actual curl response parsing in auth-status.sh via
#    a fake `curl` shim on PATH, so it proves AC #1/#2 (parses HTTP status +
#    error body, distinguishes credit-exhaustion / invalid-key / rate-limit /
#    network-error) rather than only the downstream verdict logic.
FAKEBIN="$(mktemp -d)"
cat > "$FAKEBIN/curl" <<'CURLSHIM'
#!/usr/bin/env bash
# Minimal fake of: curl -s -o "$_tmp" -w '%{http_code}' <url> -H ... -d ... [error]
out=""; code="${FAKE_CURL_HTTP_CODE:-200}"; body="${FAKE_CURL_BODY:-}"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-o" ]]; then out="${args[$((i+1))]}"; fi
done
if [[ "$code" == "000" ]]; then
    exit 7   # curl's own "couldn't connect" exit code -> auth-status.sh || echo 000
fi
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
CURLSHIM
chmod +x "$FAKEBIN/curl"

rawcheck() { # desc expected-apikey-substr-in-msg  http-code  body
    local desc="$1" esub="$2" code="$3" body="$4"
    local c out rc
    c="$(mktemp -t authcache.XXXXXX)"
    out="$(PATH="$FAKEBIN:$PATH" FAKE_CURL_HTTP_CODE="$code" FAKE_CURL_BODY="$body" \
        CHUMP_AUTH_STATUS_CACHE="$c" CHUMP_FREE_TIER_PROVIDERS="" \
        CHUMP_AUTH_STATUS_FAKE_MODE=api-key CHUMP_AUTH_STATUS_FAKE_OAUTH=absent \
        ANTHROPIC_API_KEY="sk-ant-fake-test-key" \
        bash "$SCRIPT" --probe 2>&1)"
    rc=$?
    rm -f "$c"
    if printf '%s' "$out" | grep -qF "$esub"; then
        echo "[test] PASS: $desc (exit $rc)"
    else
        echo "[test] FAIL: $desc — want substr='$esub', got exit=$rc: $out"; fail=1
    fi
}

#         desc                                           expected-substr    http  body
rawcheck "200 -> valid, workers can transact"             "workers can transact" 200 ''
rawcheck "400 + credit balance body -> OUT OF CREDITS"    "OUT OF CREDITS"        400 '{"error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API"}}'
rawcheck "400 without credit-balance body -> treated valid" "workers can transact" 400 '{"error":{"type":"invalid_request_error","message":"max_tokens must be positive"}}'
rawcheck "401 -> invalid key, none usable"                "none usable"           401 '{"error":{"type":"authentication_error","message":"invalid x-api-key"}}'
rawcheck "403 -> invalid key, none usable"                "none usable"           403 '{"error":{"type":"permission_error"}}'
rawcheck "429 -> RATE LIMITED, not confused with credits" "RATE LIMITED"          429 '{"error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}'
rawcheck "network failure (curl can't connect) -> NETWORK ERROR" "NETWORK ERROR" 000 ''

rm -rf "$FAKEBIN"

[[ "$fail" -eq 0 ]] && echo "[test-auth-status] PASS" || { echo "[test-auth-status] FAIL"; exit 1; }
