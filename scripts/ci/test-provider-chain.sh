#!/usr/bin/env bash
# test-provider-chain.sh — INFRA-1844 (CP-012: vendored ai-gm-service ensemble)
#
# Smoke test for `chump provider-chain simulate` and the
# `src/inference_provider.rs` ProviderChain executor. Drives the real
# chain/retry/fallback code path against a scripted client (mock-services,
# CP-009, has no failure-injection knobs, so scenario control lives in the
# `testing::ScenarioClient` the binary ships with) and asserts both the
# `Result` and the `kind=provider_fallback` / `provider_chain_exhausted`
# ambient events it emits.
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

CHUMP="${CHUMP_BIN:-}"
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    CHUMP="$REPO_ROOT/target/release/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    echo "FATAL: chump binary not built; run 'cargo build --bin chump' first"
    exit 2
fi

echo "=== INFRA-1844 chump provider-chain smoke test ==="
echo

# Isolate ambient.jsonl: point CHUMP_REPO at a scratch dir so this test
# never touches the real repo's .chump-locks/ambient.jsonl.
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
export CHUMP_REPO="$TMPDIR_BASE"
AMBIENT="$TMPDIR_BASE/.chump-locks/ambient.jsonl"

run_scenario() {
    local scenario="$1"
    "$CHUMP" provider-chain simulate --chain anthropic,openai --scenario "$scenario" --json
}

# Happy path — first provider succeeds, no fallback emitted.
OUT=$(run_scenario happy)
if echo "$OUT" | jq -e '.ok == true and .provider == "anthropic"' >/dev/null; then
    ok "happy path resolves on anthropic"
else
    fail "happy path: unexpected output: $OUT"
fi

# Auth fail — immediate fallback to openai.
OUT=$(run_scenario auth_fail)
if echo "$OUT" | jq -e '.ok == true and .provider == "openai"' >/dev/null; then
    ok "auth_fail falls back to openai"
else
    fail "auth_fail: unexpected output: $OUT"
fi
if grep -q '"kind":"provider_fallback".*"reason":"auth_failed"' "$AMBIENT"; then
    ok "auth_fail emits provider_fallback{reason=auth_failed}"
else
    fail "auth_fail: no provider_fallback{reason=auth_failed} in ambient stream"
fi

# Rate-limit exhausted (Retry-After beyond ceiling) — falls back.
OUT=$(run_scenario rate_limit_exhausted)
if echo "$OUT" | jq -e '.ok == true and .provider == "openai"' >/dev/null; then
    ok "rate_limit_exhausted falls back to openai"
else
    fail "rate_limit_exhausted: unexpected output: $OUT"
fi
if grep -q '"reason":"rate_limit_exhausted"' "$AMBIENT"; then
    ok "rate_limit_exhausted emits provider_fallback{reason=rate_limit_exhausted}"
else
    fail "rate_limit_exhausted: missing ambient event"
fi

# Persistent 5xx — retries exhausted, falls back.
OUT=$(run_scenario transient_5xx)
if echo "$OUT" | jq -e '.ok == true and .provider == "openai"' >/dev/null; then
    ok "transient_5xx falls back to openai"
else
    fail "transient_5xx: unexpected output: $OUT"
fi
if grep -q '"reason":"5xx_persistent"' "$AMBIENT"; then
    ok "transient_5xx emits provider_fallback{reason=5xx_persistent}"
else
    fail "transient_5xx: missing ambient event"
fi

# Timeout — falls back.
OUT=$(run_scenario timeout)
if echo "$OUT" | jq -e '.ok == true and .provider == "openai"' >/dev/null; then
    ok "timeout falls back to openai"
else
    fail "timeout: unexpected output: $OUT"
fi
if grep -q '"reason":"timeout"' "$AMBIENT"; then
    ok "timeout emits provider_fallback{reason=timeout}"
else
    fail "timeout: missing ambient event"
fi

# Content refusal (200 but empty/refused) — falls back.
OUT=$(run_scenario content_refusal)
if echo "$OUT" | jq -e '.ok == true and .provider == "openai"' >/dev/null; then
    ok "content_refusal falls back to openai"
else
    fail "content_refusal: unexpected output: $OUT"
fi
if grep -q '"reason":"content_refusal"' "$AMBIENT"; then
    ok "content_refusal emits provider_fallback{reason=content_refusal}"
else
    fail "content_refusal: missing ambient event"
fi

# Invalid prompt — fatal, no fallback, non-zero exit.
set +e
OUT=$(run_scenario invalid_prompt)
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && echo "$OUT" | jq -e '.ok == false and .error == "invalid_prompt"' >/dev/null; then
    ok "invalid_prompt is fatal (no fallback, non-zero exit)"
else
    fail "invalid_prompt: expected fatal non-zero exit, got rc=$RC out=$OUT"
fi

# Chain exhausted — every provider fails, chain-level exhaustion emitted.
set +e
OUT=$(run_scenario chain_exhausted)
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && echo "$OUT" | jq -e '.ok == false and .error == "all_providers_failed" and .attempts == 2' >/dev/null; then
    ok "chain_exhausted returns AllProvidersFailed{attempts=2}"
else
    fail "chain_exhausted: unexpected result rc=$RC out=$OUT"
fi
if grep -q '"kind":"provider_chain_exhausted"' "$AMBIENT"; then
    ok "chain_exhausted emits provider_chain_exhausted"
else
    fail "chain_exhausted: missing provider_chain_exhausted event"
fi

# Unknown provider name in the chain — dropped, not fatal.
OUT=$(CHUMP_PROVIDER_CHAIN=anthropic,bogus,openai "$CHUMP" provider-chain simulate \
    --chain anthropic,bogus,openai --scenario happy --json)
if echo "$OUT" | jq -e '.ok == true' >/dev/null; then
    ok "unknown provider name in chain does not break execution"
else
    fail "unknown provider name: unexpected output: $OUT"
fi
if grep -q '"kind":"provider_chain_unknown".*"name":"bogus"' "$AMBIENT"; then
    ok "unknown provider name emits provider_chain_unknown"
else
    fail "unknown provider name: missing provider_chain_unknown event"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "PASS: provider-chain smoke test"
