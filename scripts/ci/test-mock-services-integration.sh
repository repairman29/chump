#!/usr/bin/env bash
# test-mock-services-integration.sh — INFRA-1841 (CP-009)
#
# Demonstrates the CHUMP_USE_MOCK_SERVICES=1 opt-in pattern documented in
# docs/arsenal/cross-pollination/CP-009-mock-services.md: source
# scripts/ci/lib/mock-services-env.sh, then make what would normally be a
# real Anthropic/OpenAI API call and hit the local mock instead. Other
# scripts/ci/test-*.sh that currently gate on real credentials adopt this
# same 3-line pattern (see CP-009 "How existing tests adopt").
#
# SKIPs cleanly (exit 0) when docker is unavailable/unreachable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/mock-services"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker not available"
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not on PATH"
    exit 0
fi

cleanup() {
    docker rm -f chump-mock-anthropic-integ chump-mock-openai-integ >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -q -t chump-mock-anthropic:integ -f "$FIXTURE_DIR/Dockerfile.anthropic" "$FIXTURE_DIR" >/dev/null
docker build -q -t chump-mock-openai:integ -f "$FIXTURE_DIR/Dockerfile.openai" "$FIXTURE_DIR" >/dev/null
docker run -d --rm --name chump-mock-anthropic-integ -p 4011:4011 chump-mock-anthropic:integ >/dev/null
docker run -d --rm --name chump-mock-openai-integ -p 4010:4010 chump-mock-openai:integ >/dev/null

for port in 4010 4011; do
    for _ in $(seq 1 60); do
        curl -fsS "http://localhost:${port}/health" >/dev/null 2>&1 && break
        sleep 0.5
    done
done

# ── This is the pattern any scripts/ci/test-*.sh adopts ─────────────────────
export CHUMP_USE_MOCK_SERVICES=1
if [ "${CHUMP_USE_MOCK_SERVICES:-0}" = "1" ]; then
    # shellcheck source=scripts/ci/lib/mock-services-env.sh
    source "$SCRIPT_DIR/lib/mock-services-env.sh"
fi
# ── existing test body, unchanged — it just sees a working ANTHROPIC_API_KEY
#    and ANTHROPIC_BASE_URL pointed at a reachable endpoint ──────────────────

[ "$ANTHROPIC_BASE_URL" = "http://localhost:4011" ] || { echo "FAIL: ANTHROPIC_BASE_URL not redirected"; exit 1; }
[ "$OPENAI_BASE_URL" = "http://localhost:4010" ] || { echo "FAIL: OPENAI_BASE_URL not redirected"; exit 1; }

ANT=$(curl -fsS -X POST "${ANTHROPIC_BASE_URL}/v1/messages" \
    -H "content-type: application/json" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -d '{"model":"claude-3-sonnet-20240229","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}')
echo "$ANT" | jq -e '.role=="assistant"' >/dev/null || { echo "FAIL: anthropic call via env-injected base URL"; exit 1; }

OAI=$(curl -fsS -X POST "${OPENAI_BASE_URL}/v1/chat/completions" \
    -H "content-type: application/json" \
    -H "authorization: Bearer ${OPENAI_API_KEY}" \
    -d '{"model":"gpt-4-turbo-preview","messages":[{"role":"user","content":"hi"}]}')
echo "$OAI" | jq -e '.choices[0].message.role=="assistant"' >/dev/null || { echo "FAIL: openai call via env-injected base URL"; exit 1; }

echo "OK — Anthropic + OpenAI mocks invoked transparently via CHUMP_USE_MOCK_SERVICES=1"
