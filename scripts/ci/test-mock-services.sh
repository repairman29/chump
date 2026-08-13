#!/usr/bin/env bash
# test-mock-services.sh — INFRA-1841 (CP-009)
#
# Vendored from repairman29/mock-services at commit
# 8ce1577686a23b0b51391d6926cdf846e5a23c3f, brought in via CP-009.
#
# Smoke test for the 4 vendored mock servers (Anthropic, OpenAI, Stripe,
# Supabase) under tests/fixtures/mock-services: build each image, run it,
# wait for /health, hit the canonical endpoint, assert response shape, tear
# down. SKIPs cleanly (exit 0) when docker is unavailable — this test must
# never false-fail a host without Docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/mock-services"
NET="chump-mock-services-smoke"

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not on PATH"
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker daemon not reachable"
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not on PATH"
    exit 0
fi

declare -a SERVICES=(openai anthropic supabase stripe)
declare -A PORTS=([openai]=4010 [anthropic]=4011 [supabase]=4012 [stripe]=4013)

cleanup() {
    for svc in "${SERVICES[@]}"; do
        docker rm -f "chump-mock-${svc}-smoke" >/dev/null 2>&1 || true
    done
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start=$(date +%s)

docker network create "$NET" >/dev/null 2>&1 || true

for svc in "${SERVICES[@]}"; do
    port="${PORTS[$svc]}"
    docker build -q -t "chump-mock-${svc}:smoke" -f "$FIXTURE_DIR/Dockerfile.${svc}" "$FIXTURE_DIR" >/dev/null
    docker run -d --rm \
        --name "chump-mock-${svc}-smoke" \
        --network "$NET" \
        -p "${port}:${port}" \
        "chump-mock-${svc}:smoke" >/dev/null
done

for svc in "${SERVICES[@]}"; do
    port="${PORTS[$svc]}"
    ok=0
    for _ in $(seq 1 60); do
        if curl -fsS "http://localhost:${port}/health" >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 0.5
    done
    [ "$ok" = 1 ] || { echo "FAIL: mock-${svc} on ${port} never became healthy"; exit 1; }
done

# Anthropic — POST /v1/messages must return {role:"assistant", content:[{type:"text"}]}
ANT=$(curl -fsS -X POST "http://localhost:${PORTS[anthropic]}/v1/messages" \
    -H "content-type: application/json" \
    -d '{"model":"claude-3-sonnet-20240229","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}')
echo "$ANT" | jq -e '.role=="assistant" and (.content[0].type=="text")' >/dev/null \
    || { echo "FAIL: anthropic shape"; exit 1; }

# OpenAI — POST /v1/chat/completions must return {choices:[{message:{role:"assistant"}}]}
OAI=$(curl -fsS -X POST "http://localhost:${PORTS[openai]}/v1/chat/completions" \
    -H "content-type: application/json" \
    -d '{"model":"gpt-4-turbo-preview","messages":[{"role":"user","content":"hi"}]}')
echo "$OAI" | jq -e '.choices[0].message.role=="assistant"' >/dev/null \
    || { echo "FAIL: openai shape"; exit 1; }

# Stripe — POST /v1/payment_intents must return status:"succeeded"
STR=$(curl -fsS -X POST "http://localhost:${PORTS[stripe]}/v1/payment_intents" \
    -H "content-type: application/json" \
    -d '{"amount":100,"currency":"usd"}')
echo "$STR" | jq -e '.status=="succeeded" and (.id | startswith("pi_mock_"))' >/dev/null \
    || { echo "FAIL: stripe shape"; exit 1; }

# Supabase — POST /auth/v1/signup must return {access_token, user:{email}}
SUP=$(curl -fsS -X POST "http://localhost:${PORTS[supabase]}/auth/v1/signup" \
    -H "content-type: application/json" \
    -d '{"email":"smoke@test.local","password":"x"}')
echo "$SUP" | jq -e '.access_token and .user.email=="smoke@test.local"' >/dev/null \
    || { echo "FAIL: supabase shape"; exit 1; }

elapsed=$(( $(date +%s) - start ))
echo "OK — 4/4 mock services healthy + shape-correct (${elapsed}s)"
