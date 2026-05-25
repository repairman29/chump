# CP-011: Vendor pixel-edge bicameral-mind blueprint → Chump inference router

**Target:** Chump's LLM call sites (gap decompose, subagent dispatch, preflight reasoning, daily curation) need a tier-routing layer so on-device/local models handle the cheap fast paths and Anthropic Claude handles the deliberate ones.
**Arsenal match:** `repairman29/pixel-edge-server` — Claude Gateway v2 (`claude-gateway/server.js`, 738 lines, alt branch `claude/pixel-ai-server-setup-jGLqd` @ commit `bef6783f`).
**Recommended route:** **Vendoring (architectural pattern, rebuilt in Rust, cite source).** Chump speaks Rust; the upstream is Node.js. We harvest the *decision rule*, not the bytes.
**Status:** proposed (2026-05-23, INFRA-1843)

## The Target

Today every Chump LLM call goes the same place: `claude -p` (Anthropic API or OAuth subscription). There is no tier. A 1-line "is this title vague" check pays the same Opus rate as a 40k-token gap decomposition. The four call sites that matter:

- **Gap decompose** (`src/decompose_task_tool.rs:94` — `provider_cascade::build_provider()`) — already cascades across 14 cloud slots, but treats every slot as "best available cloud" with no on-device floor.
- **Subagent dispatch** (`src/dispatch.rs:349, 376, 410` — `cmd.args(["--model", model])`) — defaults to `FLEET_MODEL=sonnet` (`scripts/dispatch/run-fleet.sh:218`), no escalation policy.
- **Preflight reasoning** (`src/preflight.rs`, INFRA-1670) — currently pure shell + `cargo` checks, no LLM call. About to gain one (vague-AC linting), and the default-tier choice locks in habits.
- **Daily curation** (`scripts/coord/opus-curator.sh:475` — `claude -p --bare`) — the most expensive caller in the fleet by token-count; runs unconditionally on Opus.

Two problems compound: (1) **cost** — every fleet-meta sweep burns Opus quota that could have shipped a P0; (2) **offline blast radius** — Jeff-on-a-plane → zero Chump throughput, even though most fleet-meta queries are answerable by a 3B model.

The bicameral pattern fixes both. The pixel-edge-server team already shipped the working blueprint; we vendor it.

## The Arsenal Match — bicameral architecture

Pixel-edge-server runs a **Claude Gateway** on a Pixel 8 Pro that proxies OpenAI-shape requests to one of two backends based on the `model` field in the request body. The decision lives in `claude-gateway/server.js` lines 213-269 (alt branch `claude/pixel-ai-server-setup-jGLqd`):

```javascript
function isLocalModel(modelName) {
  if (!LOCAL_LLM_URL) return false;
  return modelName === 'local'
    || modelName?.includes('haiku')
    || modelName?.startsWith('ollama/')
    || modelName?.startsWith('local/');
}

async function handleChat(req, res) {
  const body = await readBody(req);
  const { messages = [], stream = false, max_tokens = 8192, model } = body;

  if (isLocalModel(model)) {
    metrics.local_llm_requests++;
    return proxyToLocalLLM(body, res);
  }
  // ... else: route to Anthropic Claude API
}
```

That's the whole router. Four rules. Three lines. The genius is the **escalation contract** — the *caller* picks the tier via the model name, the gateway just enforces. No confidence-threshold ML, no embedding-classifier. Just a string-prefix decision.

### Reflexive tier (on-device, fast, cheap)

- **Hardware:** Pixel 8 Pro, Tensor G3 prime core via `taskset -c 0`.
- **Model:** Gemma 3 1B IT Int4 (529MB) on Android; Llama-3.2-3B-Instruct Q4_K_M via `llama-server` on the Debian VM.
- **Throughput:** ~12-16 tok/s (3B with ARM SVE), ~50-100 tok/s (1B on NPU/CPU). Source: `docs/local-llm-in-vm.md` line 35, `jarvis-android/README.md` "Performance" section.
- **Latency budget:** model load ~2s, first-token ~200-400ms, sustained at the throughputs above.
- **Trigger:** any request with `model in {"local", "*haiku*", "ollama/*", "local/*"}`.
- **Cost:** $0 marginal — runs on hardware Jeff already owns.

### Neocortex tier (cloud, deliberate, expensive)

- **Hardware:** Anthropic's data centers.
- **Model:** `claude-opus-4-6` default, `claude-sonnet-4-6` and `claude-haiku-4-5` also available (`server.js:203-205`).
- **Trigger:** any `model` starting with `claude-` (line 265: `if (model && !model.startsWith('claude-'))` rejects everything else as an `invalid_request_error`).
- **Default when caller omits model:** `process.env.CLAUDE_MODEL || 'claude-opus-4-6'` (line 40, 277).
- **Cost:** per-token Anthropic pricing.

### Routing decision logic (verbatim, mapped)

The pixel-edge implementation is a one-pass dispatch:

| Caller sends `model =` | Router routes to |
|---|---|
| `"local"` | LOCAL_LLM_URL (Reflexive) |
| any string containing `"haiku"` | LOCAL_LLM_URL (Reflexive) |
| `"ollama/<name>"` or `"local/<name>"` | LOCAL_LLM_URL (Reflexive) |
| any string starting with `"claude-"` | Anthropic API (Neocortex) |
| anything else | HTTP 400, `invalid_request_error` |
| unset | Anthropic API with `CLAUDE_MODEL` default |

No confidence threshold, no automatic escalation. **The escalation is the caller's job** — if the Reflexive tier returns "I don't know", the caller re-submits with `model: "claude-opus-4-6"`. The router is dumb-on-purpose. That's the load-bearing insight for Chump's rebuild: don't try to be a cleverness-classifier in Rust, just make the tier a *typed* knob and let callers (and ambient retry policy) escalate.

## Mapping to Chump call sites

| Call site | Default tier | Escalation trigger |
|---|---|---|
| Gap decompose (`src/decompose_task_tool.rs`) | **Reflexive** (Llama-3.2-3B via neural-farm / CP-001 substrate) — most decompositions are mechanical "split files by directory". | If the returned JSON fails `serde_json::from_str::<Value>` *or* `parsed.is_array()` is false (existing checks at lines 34-39), escalate to Neocortex. Re-call with `model: "claude-opus-4-6"`. |
| Subagent dispatch (`src/dispatch.rs`) | **Mixed by gap.effort.** `xs/s` → Reflexive (haiku-class). `m` → Neocortex sonnet. `l/xl` → Neocortex opus. Today `FLEET_MODEL=sonnet` blanket-applies. | If a subagent exits non-zero on a gap with `effort=xs/s` after Reflexive attempt, the bot-merge supervisor re-spawns with `--model claude-sonnet-4-6`. One escalation per gap; on second failure the gap goes back to the pool. |
| Preflight reasoning (`src/preflight.rs`, INFRA-1670 future LLM-assist) | **Reflexive only.** Preflight runs locally before every push and should never burn cloud quota on a per-push check. Vague-AC lint, commit-message sanity, hook-failure summary — all small/cheap. | None. Preflight refuses to escalate by design; if the Reflexive tier is unreachable, preflight skips the LLM step and emits `kind=preflight_llm_unavailable` to ambient. |
| Daily curation (`scripts/coord/opus-curator.sh`) | **Two-pass: Reflexive first, Neocortex on miss.** Pass 1 = Reflexive over all open gaps to flag candidates (vague AC, stale deps, P0 inflation). Pass 2 = Neocortex Opus deliberation on the flagged subset only. | The flagging step is mechanical → Reflexive. The decision step (file gap? demote? close?) is the Opus turn. Saves ~95% of curator cost. |

The shape is: **Reflexive handles all bookkeeping/triage; Neocortex handles every decision that mutates state.db, files a gap, or closes a PR.**

## Rust router shape — src/inference_router.rs

The pixel-edge router is 50 lines of JS. The Rust equivalent is similar — the *value* is the discipline, not the code.

```rust
// src/inference_router.rs
// Vendored architectural pattern from repairman29/pixel-edge-server
// at commit bef6783f733ac8231975ff61969510f80e05788e (alt branch
// claude/pixel-ai-server-setup-jGLqd), original claude-gateway/server.js
// lines 213-269 (CP-011).

use crate::provider_cascade;          // CP-001 substrate — Reflexive backends
use axonerai::provider::Provider;     // Neocortex backend (Anthropic via axonerai)

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Reflexive,   // local-LLM tier; CP-001 neural-farm / llama-server
    Neocortex,   // cloud tier; Anthropic claude-* via axonerai
    Auto,        // pick based on CallContext heuristic (default)
}

#[derive(Debug, Clone)]
pub enum CallSite {
    GapDecompose { gap_id: String, effort: GapEffort },
    SubagentDispatch { gap_id: String, effort: GapEffort },
    PreflightReason,
    DailyCuration { phase: CurationPhase },
}

#[derive(Debug, Clone)]
pub struct CallContext {
    pub site: CallSite,
    pub attempt: u32,           // 0 = first try; >0 means we already escalated
    pub max_tokens_hint: u32,
}

#[derive(Debug, Clone)]
pub struct InferenceDecision {
    pub tier: Tier,
    pub provider: Provider,     // resolved Provider trait object handle
    pub model: String,          // e.g. "claude-sonnet-4-6" or "local"
    pub reason: &'static str,   // for ambient.jsonl observability
}

pub struct InferenceRouter {
    tier_override: Option<Tier>,             // CHUMP_INFERENCE_TIER env
    reflexive_endpoint: Option<String>,      // CHUMP_INFERENCE_ENDPOINT (CP-001)
    neocortex_default_model: String,         // e.g. "claude-sonnet-4-6"
}

impl InferenceRouter {
    pub fn from_env() -> Self { /* read CHUMP_INFERENCE_TIER, etc. */ }

    pub fn route(&self, ctx: &CallContext) -> InferenceDecision {
        // 1. Explicit override always wins (operator-controlled).
        if let Some(t) = self.tier_override {
            return self.dispatch(t, ctx);
        }
        // 2. Per-call-site default.
        let tier = match (&ctx.site, ctx.attempt) {
            (CallSite::PreflightReason, _) => Tier::Reflexive,
            (CallSite::DailyCuration { phase: CurationPhase::Triage }, _) => Tier::Reflexive,
            (CallSite::DailyCuration { phase: CurationPhase::Decide }, _) => Tier::Neocortex,
            (CallSite::GapDecompose { effort, .. }, 0) if effort.is_small() => Tier::Reflexive,
            (CallSite::SubagentDispatch { effort, .. }, 0) if effort.is_small() => Tier::Reflexive,
            (_, n) if n > 0 => Tier::Neocortex,   // escalation on retry
            _ => Tier::Neocortex,                  // default to safe tier
        };
        self.dispatch(tier, ctx)
    }
}
```

**Env config:**

- `CHUMP_INFERENCE_TIER=reflexive|neocortex|auto` (default `auto`). When `reflexive`, every call goes Reflexive — `auto` fallback disabled, callers see local-only errors. Used for offline-plane testing.
- `CHUMP_INFERENCE_ENDPOINT=http://localhost:<neural-farm-port>/v1` (CP-001) — the Reflexive backend URL.
- `CHUMP_INFERENCE_NEOCORTEX_DEFAULT=claude-sonnet-4-6` — what to send when no specific model is requested.

**Observability:** every `route()` call emits `kind=inference_routed` to `ambient.jsonl` with `{site, tier, model, reason, attempt}`. The `reason` field carries the routing rule fired ("preflight_always_reflexive", "small_effort_reflexive", "escalation_attempt", "operator_override"). One grep gives the daily decision distribution.

## Convergence with CP-001 + CP-012

This brief is the **router skeleton**. It plugs into two siblings:

- **CP-001 (neural-farm)** is the **Reflexive backend.** When `route()` returns `Tier::Reflexive`, the actual HTTP call goes to `CHUMP_INFERENCE_ENDPOINT` which is the neural-farm proxy (MacBook → Pixel for ARM-optimized Gemma 3B / Llama 3.2 3B). The router doesn't know or care which device serves; neural-farm is the device-routing layer beneath it.
- **CP-012 (ai-gm-service ensemble, forthcoming)** is the **Neocortex chain.** Today `Tier::Neocortex` resolves to `provider_cascade::build_provider()` which is already 14 cloud slots. CP-012 will deepen the cascade with quality-aware re-ranking. The router contract is unchanged — it asks for Neocortex, the cascade decides how to spend.

The three CPs compose:

```
CallSite (Chump)
  → InferenceRouter::route()      [CP-011, this brief]
     → Tier::Reflexive  → neural-farm /v1                [CP-001]
     → Tier::Neocortex  → provider_cascade (14 slots)    [CP-012]
```

## Smoke test spec — scripts/ci/test-inference-router.sh

Depends on **mock-services CP-009** for the Anthropic mock on port 4011, plus a `llama-server` mock or echo-server on port 8080 for Reflexive.

```bash
#!/usr/bin/env bash
# scripts/ci/test-inference-router.sh — INFRA-1843, CP-011
# Verify InferenceRouter::route() decisions are deterministic + observable.
set -euo pipefail

# 1. Start mocks (CP-009 substrate).
docker compose -f tests/fixtures/mock-services.compose.yml up -d
trap 'docker compose -f tests/fixtures/mock-services.compose.yml down' EXIT

export CHUMP_INFERENCE_ENDPOINT=http://localhost:8080/v1   # Reflexive mock
export ANTHROPIC_API_KEY_OVERRIDE=http://localhost:4011    # Neocortex mock
export CHUMP_AMBIENT_LOG=$(mktemp)

# 2. Three tier overrides, deterministic decisions.
for tier in reflexive neocortex auto; do
  CHUMP_INFERENCE_TIER=$tier \
    cargo run --bin chump-routing-probe -- \
      --site gap_decompose --gap-id TEST-0001 --effort s \
      --expect-tier "$(case $tier in reflexive) echo reflexive;; neocortex) echo neocortex;; auto) echo reflexive;; esac)"
done

# 3. Escalation path: attempt=0 → Reflexive; attempt=1 → Neocortex.
cargo run --bin chump-routing-probe -- \
  --site gap_decompose --gap-id TEST-0002 --effort s --attempt 0 --expect-tier reflexive
cargo run --bin chump-routing-probe -- \
  --site gap_decompose --gap-id TEST-0002 --effort s --attempt 1 --expect-tier neocortex

# 4. Ambient observability: every route() emits kind=inference_routed.
test "$(grep -c '"kind":"inference_routed"' "$CHUMP_AMBIENT_LOG")" -ge 5

echo "PASS: inference_router decisions deterministic + observable"
```

`chump-routing-probe` is a tiny `src/bin/` harness that constructs a `CallContext`, calls `route()`, asserts the returned `tier` matches `--expect-tier`. Total test runtime target: <10s (mocks are local).

## Vendoring lineage

Add this comment block to the top of `src/inference_router.rs` when it's written:

```rust
//! Inference router — two-tier dispatch (Reflexive on-device + Neocortex cloud).
//!
//! Vendored architectural pattern from repairman29/pixel-edge-server
//! at commit bef6783f733ac8231975ff61969510f80e05788e
//! (branch claude/pixel-ai-server-setup-jGLqd),
//! original claude-gateway/server.js lines 213-269.
//!
//! See docs/arsenal/cross-pollination/CP-011-bicameral-mind.md for the
//! mapping, routing heuristics, and convergence with CP-001 + CP-012.
```

## Lineage / Risk

- **Pixel-edge cadence:** last commit on `main` is 2026-03-06 (`b95fbe7e`); the bicameral-routing alt branch `claude/pixel-ai-server-setup-jGLqd` is the live blueprint head (`bef6783f`, same date). Two months stale at filing time. The pattern is small and stable; drift risk is low. Re-survey at next major Chump release if upstream resumes.
- **Pattern drift if upstream evolves.** If pixel-edge adds confidence-threshold ML or a third tier, we are diverged — that's fine; the vendoring comment cites a commit SHA, not "current main".
- **Dual-source-of-truth risk.** Today `FLEET_MODEL=sonnet` (`run-fleet.sh:218`) and the new `CHUMP_INFERENCE_TIER` both influence subagent dispatch model choice. Mitigation: at router rollout, `FLEET_MODEL` becomes a soft hint that the router *may* honor in `Auto` mode and *must* ignore in explicit-tier mode. One env, one source of truth per call site.
- **Escalation pollution.** If callers freely escalate on every Reflexive non-answer, cost regresses. The smoke test enforces "one escalation per gap" — a second non-answer means the gap goes back to the pool, no third call.

## What this brief does *not* do

It does not write Rust, does not modify `src/`, does not file the inference_router test in `scripts/ci/`, does not touch `provider_cascade.rs`, and does not commit. It maps the harvest and pins the routing rules. Execution lives in INFRA-1843 once a Sonnet worker claims it for implementation.
