# CP-001: Harvest neural-farm as Chump's local-LLM gateway

**Target repo:** `repairman29/chump` (this repo)
**Arsenal match:** `repairman29/neural-farm` — "Local Neural Farm: MacBook + iPhone + Pixel, one API for Cursor (LiteLLM + InferrLM)"
**Recommended route:** Microservice (Route 2)
**Status:** proposed (Harvester v0, 2026-05-23)

## The Target

Chump's offline + local-LLM mission (see memory: `project_offline_local_llm_mission.md`) needs
a stable local inference layer. Today the chump worker calls Anthropic via `ANTHROPIC_API_KEY`
or `CLAUDE_CODE_OAUTH_TOKEN`. There is no first-class path that routes a request to a local
model running on a sibling device (MacBook → Pixel for ARM-optimized models, MacBook → iPhone
for on-device CoreML, etc.).

When the dogfood scenario is "Jeff on a plane with no Anthropic access", chump should still
make forward progress against P2/P3 gaps using a local model. That requires:

- A unified inference endpoint (so chump only needs one URL).
- Cross-device routing (so the right model serves the right call).
- Graceful fallback when a device is offline (so an iPhone reboot doesn't break the fleet).

## The Arsenal Match

`repairman29/neural-farm` (Python, last pushed 2026-02-28) is already this primitive:

- **One API for Cursor** — meaning a single endpoint that proxies to multiple model homes.
- **LiteLLM + InferrLM** — LiteLLM gives OpenAI-compat shape over many backends; InferrLM is
  the routing brain.
- **MacBook + iPhone + Pixel** — proven to span three device classes already.

If neural-farm already speaks OpenAI-shape, chump's existing `claude -p` worker subprocess
can be swapped to that endpoint with no protocol rewrite (the model returns plain completions;
chump's parser doesn't care which backend served them, as long as Anthropic-shape JSON or a
known transform comes back).

## The Bridge Strategy

### Step 1 — survey neural-farm's current state
```bash
cd ~/Projects
gh repo clone repairman29/neural-farm
cd neural-farm
# Check what endpoints it exposes and what auth it expects.
grep -rEn 'route|endpoint|@app\.|FastAPI|Flask' --include='*.py' | head
# Check last commit; if > 6 months old, the survey blocks the harvest.
git log -1 --format='%ai %s'
```

### Step 2 — pin chump to neural-farm as a microservice
In `~/.chump/env.local` (or wherever the worker reads env from):
```bash
# Local mode: route chump's model calls through neural-farm
CHUMP_INFERENCE_ENDPOINT=http://localhost:<neural-farm-port>/v1
CHUMP_INFERENCE_MODE=openai-compat
CHUMP_AUTH_MODE=local  # new mode, opts out of API key + OAUTH
```

### Step 3 — add a fallback chain in `chump fleet doctor`
```bash
# Pseudocode for the precedence chain:
# 1. If ANTHROPIC_API_KEY valid → Anthropic
# 2. Else if CLAUDE_CODE_OAUTH_TOKEN valid → Anthropic (subscription)
# 3. Else if CHUMP_INFERENCE_ENDPOINT reachable → neural-farm
# 4. Else exit 2 with "no inference path available"
```
The `fleet_auth_fallback` ambient event (already defined in CLAUDE.md auth section) extends
naturally to a third tier.

### Step 4 — file the integration gap
`chump gap reserve --domain INFRA --title "EFFECTIVE: route worker inference through neural-farm when offline"`
with acceptance criteria:
- `CHUMP_INFERENCE_MODE=openai-compat` is documented in `docs/agents/HARNESS_CONTRACT.md`
- `chump fleet doctor` exits 0 when only neural-farm is reachable
- One worker successfully ships a P2 gap with `CHUMP_AUTH_MODE=local`
- `kind=fleet_auth_fallback` event emitted with `to=local`

## Lineage / Risk

- **Risk: neural-farm is dormant.** Last push 2026-02-28 means ~3 months stale. Step 1 may
  reveal the survey blocks the harvest. If so, the alternative is **Route 1 (Dependency)** —
  extract the InferrLM router into a small Rust crate `chump-inference-routing` and ship
  natively, skipping the Python service.
- **Risk: protocol drift.** If chump's worker assumes Anthropic-shape JSON in places, the
  shim has to translate. The blast radius is bounded to one file (`src/worker/inference.rs`
  or similar; locate via `grep -rn 'anthropic\|messages\.create' src/`).
- **Risk: dual-source-of-truth.** If chump *also* keeps a direct-Anthropic path, drift can
  emerge. Mitigation: keep Anthropic primary, neural-farm fallback. Don't dual-route on the
  same call.
- **Re-harvest cadence:** review at next major chump release. If neural-farm goes dark for
  > 90 days, flip to Route 1 (Dependency).

## What this brief does *not* do

It does not write Rust code, it does not modify `src/`, and it does not commit. It maps the
opportunity. Execution lives in the gap it proposes.
