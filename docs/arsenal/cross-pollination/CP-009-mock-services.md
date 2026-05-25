# CP-009: Vendor mock-services → Chump CI fixture layer

**Target:** Chump CI needs offline-runnable mock servers for Anthropic, OpenAI, Stripe, Supabase so that LLM-touching and payment-touching gaps can be tested without burning real API credits or requiring network access.
**Arsenal match:** `repairman29/mock-services` — 4 production-grade Express.js mock servers, each shipping its own `Dockerfile.<service>` + healthcheck (last push 2026-01-31, commit `8ce1577`).
**Recommended route:** **(b) docker-compose pulled at CI start, Chump owns the compose file, mocks pulled from upstream as built images.**
**Status:** proposed (2026-05-23, INFRA-1841)

## The Target

Chump's offline mission (memory: `project_offline_local_llm_mission.md`) and the consumer-quality gate of the productization plan (memory: `project_productization_plan_2026-05-22.md`) both demand CI that doesn't reach over the network. Today, the following `scripts/ci/test-*.sh` scripts either reference real API endpoints, gate themselves on `ANTHROPIC_API_KEY`, or skip silently when keys are absent:

- `scripts/ci/test-auth-storm-auto-recovery.sh`
- `scripts/ci/test-cli-fleet-coord.sh`
- `scripts/ci/test-credential-lifecycle.sh`
- `scripts/ci/test-fleet-auth-check.sh`
- `scripts/ci/test-fleet-backend-auto-detect.sh`
- `scripts/ci/test-fleet-passes-api-keys.sh`
- `scripts/ci/test-multi-auth.sh`
- `scripts/ci/test-no-anthropic-smoke.sh`
- `scripts/ci/test-oauth-token-refresh.sh`
- `scripts/ci/test-orchestrate-llm-fallback.sh`
- `scripts/ci/test-pwa-secrets-flow.sh`

These tests are currently in a degraded "exists but skips" state in offline CI. They are the test AC of **INFRA-1842, 1843, 1844, 1849** (Quality Firewall substrate, per `docs/strategy/HARVEST_GROWTH_DIRECTIONS_2026-05-23.md` Direction 3).

Chump CI also needs Stripe + Supabase mocks because the PWA secrets flow (`scripts/ci/test-pwa-secrets-flow.sh`) and any future Stripe-touching billing tooling cannot be tested offline today.

## The Arsenal Match — 4 mock servers

All 4 mocks are Express.js apps with the same shape: `express + cors`, a single `PORT = process.env.MOCK_PORT || <default>` binding, a JSON `/health` route, a root `/` discovery route, and one or more service-canonical routes. Each ships a sibling `Dockerfile.<service>` (node:18-alpine, ~450B each, identical structure, `EXPOSE <port>`, `HEALTHCHECK` polling `/health`).

### Anthropic mock (`mock-anthropic.js`, 2.2KB)

- **Default port:** `4011` (override `MOCK_PORT`)
- **Endpoints:**
  - `POST /v1/messages` — returns Anthropic-shape `{id, type, role, content:[{type,text}], model:'claude-3-sonnet-20240229', stop_reason:'end_turn', usage:{input_tokens, output_tokens}}`. Static text body, no echo of prompt. 400-1200ms simulated latency.
  - `GET /health` — `{status:'healthy', service:'mock-anthropic', version, timestamp}`
  - `GET /` — discovery, lists endpoints.
- **Templated vs. dynamic:** response body is **fully static**; the `id`, `text`, `model` are hardcoded constants. Latency is randomized. Token counts are constants (input=100, output=50). Request body's `messages` array length is logged but not echoed.
- **Dockerfile:** `Dockerfile.anthropic` — node:18-alpine, `npm ci --only=production`, `EXPOSE 4011`, healthcheck against `/health`, `CMD ["node", "mock-anthropic.js"]`.
- **Configuration env vars:** `MOCK_PORT` (one knob).

### OpenAI mock (`mock-openai.js`, 3.7KB)

- **Default port:** `4010` (override `MOCK_PORT`)
- **Endpoints:**
  - `POST /v1/chat/completions` — returns `{id, object:'chat.completion', created, model:'gpt-4-turbo-preview', choices:[{index:0, message:{role:'assistant', content}, finish_reason:'stop'}], usage}`. Static text, 200-700ms latency.
  - `POST /v1/completions` — legacy completion shape, static text, 100-400ms latency.
  - `GET /v1/models` — `{object:'list', data:[{id:'gpt-4-turbo-preview',...}, {id:'gpt-3.5-turbo',...}]}`
  - `GET /health` + `GET /`
- **Templated vs. dynamic:** `created` is `Date.now()` per request; everything else is static. No prompt echo.
- **Dockerfile:** `Dockerfile.openai` — identical pattern, `EXPOSE 4010`, `CMD ["node", "mock-openai.js"]`.
- **Configuration env vars:** `MOCK_PORT`.

### Stripe mock (`mock-stripe.js`, 4.3KB)

- **Default port:** `4013` (override `MOCK_PORT`)
- **Endpoints:**
  - `POST /v1/payment_intents` — creates `pi_mock_<ts>` with status `succeeded` (every payment auto-succeeds). Stores in in-memory `mockPayments`.
  - `GET /v1/payment_intents/:id` — fetches stored intent or 404s with Stripe-shape error.
  - `POST /v1/customers` — creates `cus_mock_<ts>`, stores in `mockCustomers`.
  - `GET /v1/customers/:id` — fetches stored customer or 404s.
  - `POST /v1/payment_methods` — creates `pm_mock_<ts>` with Visa default card (`last4: '4242'`).
  - `POST /v1/webhooks` — acks any payload with `{received:true}`.
  - `GET /health` (with `mock_data: {payments, customers}` counters) + `GET /`
- **Templated vs. dynamic:** IDs use `Date.now()` so per-request unique; in-memory store persists for the container's lifetime. Request fields (amount, email, metadata) are echoed back into the response. **No HMAC signature verification on webhooks** (production Stripe webhooks sign — Chump tests that do signature work cannot use this mock as-is).
- **Dockerfile:** `Dockerfile.stripe` — `EXPOSE 4013`, `CMD ["node", "mock-stripe.js"]`.
- **Configuration env vars:** `MOCK_PORT`.

### Supabase mock (`mock-supabase.js`, 3.4KB)

- **Default port:** `4012` (override `MOCK_PORT`)
- **Endpoints:**
  - `POST /auth/v1/signup` — creates `user_<ts>`, returns Supabase-shape `{access_token:'mock_access_token_123', token_type:'bearer', expires_in:3600, refresh_token, user}`. Tokens are constant strings (not JWTs).
  - `POST /auth/v1/signin` — looks up by email; returns same shape or 400.
  - `GET /rest/v1/:table` — returns in-memory array for table.
  - `POST /rest/v1/:table` — appends `{id:'item_<ts>', ...body, created_at}` to in-memory array.
  - `GET /health` (with per-table counters) + `GET /`
- **Templated vs. dynamic:** auth tokens are **hardcoded constants** (no JWT decode possible). Tables are in-memory `{users, sessions, characters, games}` plus any new table you POST to. **No RLS enforcement, no SQL operators (`eq.`, `gt.`, etc.) parsed from the query string** — table reads return everything.
- **Dockerfile:** `Dockerfile.supabase` — `EXPOSE 4012`, `CMD ["node", "mock-supabase.js"]`.
- **Configuration env vars:** `MOCK_PORT`.

### Shared package surface (`package.json`)

`smugglers-mock-services@1.0.0`, MIT, deps are `express ^4.18.2` + `cors ^2.8.5`. No native compiles, no postinstall scripts. Total dep closure is ~50 packages, ~5MB install. All 4 mocks share one `node_modules`.

## Vendoring decision: **(b) docker-compose, mocks pulled as images**

| Approach | Pros | Cons | Verdict |
|---|---|---|---|
| **(a) git submodule under `tests/fixtures/mock-services`** | Mocks live in-tree; no Docker required for grep/edit; pin to one commit | Submodules require `--recurse-submodules` discipline; every dev clone fetches the JS; we'd ship someone else's `package.json` inside ours; node_modules install adds 30-60s to first-run CI | Reject — node_modules + git submodule UX cost outweighs benefit |
| **(b) docker-compose pulled at CI start; Chump owns the compose, mocks pulled from upstream as built images** | Zero in-tree source; one `docker-compose.yml` is the contract; images are pre-built once (cache); test scripts only see `http://localhost:<port>`; offline-runnable after first pull (Docker layer cache); upstream stays the source of truth | Requires Docker daemon on dev machine; first pull needs network (mitigated by registry caching); the upstream repo is private (`repairman29/mock-services`) — we'd need to publish images to a registry Chump CI can pull from | **RECOMMEND** |
| **(c) extract as standalone `chump-mock-services` crate that ships its own Docker images** | Chump fully owns source; can add JWT-signing Supabase, HMAC-signing Stripe later; aligns with Rust-first guidance (META-064) | High up-front rewrite cost (~2-3 days to port 4 JS files to Rust + Docker); deviates from the cheap path; the source is so small (~14KB total JS) that "ownership" is a paper-thin benefit until we need a feature the JS doesn't have | Reject for now — file as **follow-up** if/when we hit a missing feature (e.g. HMAC verification, JWT decode) |

**Rationale for (b):** the upstream code is tiny (4 JS files, ~14KB) and has been stable since January 2026 — there is no maintenance burn to inherit and no feature we need that it doesn't already provide. The `Dockerfile.<service>` pattern is already correct; healthcheck + EXPOSE + alpine is what we'd write ourselves. Treating each mock as an immutable image lets us version-pin (`mock-services-anthropic:sha-8ce1577`) and rebuild only when the upstream commit changes. Crucially, this matches Direction 3 of the harvest growth doc: **wrap, don't rewrite**.

**Image publishing:** since the upstream repo is private, Step 0 of the harvest is to either (i) fork it public under `repairman29/chump-mock-services` and let GitHub Actions push to GHCR, or (ii) build images locally in `scripts/ci/build-mock-images.sh` from a one-off shallow clone at the pinned SHA. (i) is the right long-term answer; (ii) is acceptable for the smoke-test AC of INFRA-1841 and unblocks INFRA-1842/1843/1844/1849 without waiting on registry setup.

## Chump CI integration design

### Env-var injection pattern

Add to `scripts/ci/lib/mock-services-env.sh` (sourced by any test that wants to redirect API calls):

```bash
# Source this to redirect all upstream API calls to local mocks.
# Only valid inside docker-compose -f tests/fixtures/mock-services/docker-compose.yml up.

# Anthropic — anthropic-sdk and chump's worker.sh honor ANTHROPIC_BASE_URL.
export ANTHROPIC_BASE_URL="http://localhost:4011"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-ant-mock-key-for-tests}"

# OpenAI — openai-python and litellm honor OPENAI_BASE_URL / OPENAI_API_BASE.
export OPENAI_BASE_URL="http://localhost:4010"
export OPENAI_API_BASE="http://localhost:4010"
export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-mock-key-for-tests}"

# Stripe — stripe-node honors STRIPE_API_BASE (less standardized; some clients need patching).
export STRIPE_API_BASE="http://localhost:4013"
export STRIPE_SECRET_KEY="${STRIPE_SECRET_KEY:-sk_test_mock}"

# Supabase — supabase-js honors SUPABASE_URL.
export SUPABASE_URL="http://localhost:4012"
export SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-mock_anon_key}"
```

### How existing tests adopt

A test that currently gates on `[ -n "$ANTHROPIC_API_KEY" ] || { echo skipping; exit 0; }` becomes:

```bash
# Top of scripts/ci/test-fleet-auth-check.sh (and siblings)
if [ "${CHUMP_USE_MOCK_SERVICES:-0}" = "1" ]; then
  source "$(dirname "$0")/lib/mock-services-env.sh"
fi
# ... existing test body unchanged: it sees a working ANTHROPIC_API_KEY + reachable endpoint ...
```

CI workflow sets `CHUMP_USE_MOCK_SERVICES=1` after `docker-compose up` completes. Local devs running tests outside docker leave it unset and tests continue to gate on real keys as today. The migration is **opt-in per test**, not a flag day — INFRA-1842/1843/1844/1849 each adopt the source line as part of their own AC.

**Caveat: anthropic-sdk-python and the Rust worker.** Confirm both honor `ANTHROPIC_BASE_URL`. The Python SDK has supported `base_url` since 0.21.0. The chump Rust worker constructs URLs internally — INFRA-1842 should audit `src/worker/` for hardcoded `api.anthropic.com` and replace with `std::env::var("ANTHROPIC_BASE_URL").unwrap_or("https://api.anthropic.com".into())`.

## Smoke test spec — `scripts/ci/test-mock-services.sh`

Exits 0 in <30s on a warm Docker cache; <90s cold pull. Spins all 4, hits each canonical endpoint, asserts response shape, tears down.

```bash
#!/usr/bin/env bash
# Vendored from repairman29/mock-services at commit 8ce1577686a23b0b51391d6926cdf846e5a23c3f (CP-009)
set -euo pipefail
TRAP_CMD=""
COMPOSE_FILE="tests/fixtures/mock-services/docker-compose.yml"

cleanup() { docker-compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1. Spin
docker-compose -f "$COMPOSE_FILE" up -d --quiet-pull
# 2. Wait for all 4 health checks (max 20s)
for port in 4010 4011 4012 4013; do
  for i in {1..40}; do
    curl -fsS "http://localhost:$port/health" >/dev/null 2>&1 && break
    sleep 0.5
    [ "$i" = 40 ] && { echo "FAIL: mock on $port never became healthy"; exit 1; }
  done
done

# 3. Hit canonical endpoints, assert shape
# 3a. Anthropic — POST /v1/messages must return {role:"assistant", content:[{type:"text"}]}
ANT=$(curl -fsS -X POST http://localhost:4011/v1/messages \
  -H "content-type: application/json" \
  -d '{"model":"claude-3-sonnet-20240229","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}')
echo "$ANT" | jq -e '.role=="assistant" and (.content[0].type=="text")' >/dev/null || { echo "FAIL anthropic shape"; exit 1; }

# 3b. OpenAI — POST /v1/chat/completions must return {choices:[{message:{role:"assistant"}}]}
OAI=$(curl -fsS -X POST http://localhost:4010/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"gpt-4-turbo-preview","messages":[{"role":"user","content":"hi"}]}')
echo "$OAI" | jq -e '.choices[0].message.role=="assistant"' >/dev/null || { echo "FAIL openai shape"; exit 1; }

# 3c. Stripe — POST /v1/payment_intents must return status:"succeeded"
STR=$(curl -fsS -X POST http://localhost:4013/v1/payment_intents \
  -H "content-type: application/json" \
  -d '{"amount":100,"currency":"usd"}')
echo "$STR" | jq -e '.status=="succeeded" and (.id | startswith("pi_mock_"))' >/dev/null || { echo "FAIL stripe shape"; exit 1; }

# 3d. Supabase — POST /auth/v1/signup must return {access_token, user:{email}}
SUP=$(curl -fsS -X POST http://localhost:4012/auth/v1/signup \
  -H "content-type: application/json" \
  -d '{"email":"smoke@test.local","password":"x"}')
echo "$SUP" | jq -e '.access_token and .user.email=="smoke@test.local"' >/dev/null || { echo "FAIL supabase shape"; exit 1; }

echo "OK — 4/4 mock services healthy + shape-correct"
```

The accompanying `tests/fixtures/mock-services/docker-compose.yml` is a 4-service file, each pinning to `ghcr.io/repairman29/mock-services-<service>:sha-8ce1577` (or a local-build tag during the (ii) bootstrap), publishing `400X:400X`, with `healthcheck` mirroring the upstream Dockerfile's pattern.

## Vendoring lineage

Any file in Chump that copies, references, or re-implements upstream behavior gets a top-of-file comment:

```
// Vendored from repairman29/mock-services at commit 8ce1577686a23b0b51391d6926cdf846e5a23c3f,
// original path <e.g. mock-anthropic.js>, brought in via CP-009.
```

For `tests/fixtures/mock-services/docker-compose.yml` and `scripts/ci/test-mock-services.sh`, the lineage line goes in the file header. For images published to GHCR, the upstream SHA goes in the image tag (`sha-8ce1577`) — that *is* the lineage marker.

## Lineage / Risk

- **Upstream dormant since 2026-01-31** (~4 months at filing time). The repo description still says "Smuggler RPG enterprise platform" — it's not built for Chump. Risk: if upstream pivots or archives, our pinned SHA still works (Docker images are immutable), but we lose the ability to upstream fixes. Mitigation: fork to `repairman29/chump-mock-services` as part of (i) above; Chump becomes the maintainer.
- **Mock fidelity gaps.**
  - Anthropic: response body is fully static — tests that assert "my prompt influenced the answer" will fail. Mitigation: file INFRA-NEW to add deterministic prompt-echo as a feature; until then, restrict mock to round-trip / auth / rate-limit / token-counting tests.
  - OpenAI: same static-body limitation; no streaming SSE support (real OpenAI is SSE-streamed). Tests that depend on streaming chunks must continue to gate on a real key.
  - Stripe: **no webhook signature verification.** Tests that exercise HMAC signing on incoming webhooks must use a different fixture. Also no idempotency-key dedup.
  - Supabase: **tokens are constant strings, not JWTs.** Any test that decodes the `access_token` as a JWT will explode. RLS is not enforced; SQL operator parsing not implemented.
- **License: MIT** on the upstream `package.json` but the README says "Proprietary" and the repo's GitHub license field is `Other`. The MIT in `package.json` is the controlling text under the SPDX convention, but resolve the inconsistency before publishing the fork (likely a copy-paste artifact in README).
- **Re-harvest cadence:** review at the next major Chump release. If upstream goes >180 days without a commit, lock in (c) and own the source.

## What this brief does *not* do

It does not modify `scripts/ci/`, does not add the `tests/fixtures/mock-services/` directory, does not publish images, does not commit. It maps the harvest. Execution lives in INFRA-1841 AC #3–7 (wiring), INFRA-1842/1843/1844/1849 (per-test adoption), and follow-up INFRA gaps for HMAC-Stripe and JWT-Supabase if those become needed.
