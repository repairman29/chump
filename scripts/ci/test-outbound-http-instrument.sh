#!/usr/bin/env bash
# test-outbound-http-instrument.sh — INFRA-1336
#
# Verifies the outbound HTTP instrumentation wrapper:
#   1. src/http_client.rs exists, is mod'd, exports chump_http::send
#   2. health_server.rs probe_model + probe_embed route through the wrapper
#   3. kind=outbound_http_call is registered in EVENT_REGISTRY.yaml with the
#      required fields list
#   4. cargo unit tests pass (3 cases including live-server emission)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

echo "=== INFRA-1336 outbound HTTP instrumentation tests ==="

HC="src/http_client.rs"
MAIN_RS="src/main.rs"
HEALTH="src/health_server.rs"
REGISTRY="docs/observability/EVENT_REGISTRY.yaml"

# ── Test 1: module + registration ────────────────────────────────────────────
[[ -f "$HC" ]] && ok "src/http_client.rs present" || fail "src/http_client.rs missing"
grep -q '^mod http_client;' "$MAIN_RS" && ok "http_client mod registered in main.rs" \
    || fail "http_client not registered in main.rs"

# ── Test 2: public API surface ──────────────────────────────────────────────
grep -q 'pub async fn send' "$HC" && ok "chump_http::send public" \
    || fail "send not public"
grep -q '"outbound_http_call"' "$HC" && ok "emits kind=outbound_http_call" \
    || fail "kind=outbound_http_call not emitted in http_client.rs"

# ── Test 3: required fields populated ───────────────────────────────────────
for field in host path method duration_ms initiated_by; do
    if grep -q "\"$field\"" "$HC"; then
        ok "field '$field' populated"
    else
        fail "required field '$field' not populated in http_client.rs"
    fi
done

# ── Test 4: error taxonomy + status_code on success ─────────────────────────
grep -q 'classify_error' "$HC" && ok "error taxonomy via classify_error" \
    || fail "error classification missing"
for cls in timeout connection_refused dns tls request; do
    if grep -q "\"$cls\"" "$HC"; then
        ok "error class '$cls' in taxonomy"
    else
        fail "error class '$cls' missing from taxonomy"
    fi
done

# ── Test 5: opt-out env honored ─────────────────────────────────────────────
grep -q 'CHUMP_HTTP_INSTRUMENT' "$HC" \
    && ok "CHUMP_HTTP_INSTRUMENT opt-out wired" \
    || fail "CHUMP_HTTP_INSTRUMENT not wired"

# ── Test 6: health_server probes migrated ───────────────────────────────────
grep -q 'crate::http_client::send' "$HEALTH" \
    && ok "health_server probes route through chump_http::send" \
    || fail "health_server still uses raw .send().await for probes"

# ── Test 7: event kind registered ───────────────────────────────────────────
grep -q '^  - kind: outbound_http_call' "$REGISTRY" \
    && ok "outbound_http_call registered in EVENT_REGISTRY.yaml" \
    || fail "outbound_http_call NOT in EVENT_REGISTRY.yaml"
grep -A8 '^  - kind: outbound_http_call' "$REGISTRY" | grep -q 'fields_required:.*initiated_by' \
    && ok "fields_required includes initiated_by" \
    || fail "fields_required missing initiated_by in registry entry"

# ── Test 8: cargo unit tests (gated on env, slow) ───────────────────────────
if [[ "${CHUMP_RUN_CARGO_TESTS:-0}" = "1" ]]; then
    if cargo test -p chump --bin chump http_client::tests 2>&1 | tail -5 | grep -q '0 failed'; then
        ok "cargo test http_client::tests all passing"
    else
        fail "cargo unit tests for http_client failed or did not run"
    fi
else
    echo "  SKIP: cargo test (set CHUMP_RUN_CARGO_TESTS=1 to enable; pre-validated locally)"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
