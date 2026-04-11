# External strategic plan alignment (Chump stack)

**Purpose:** Map an external “enterprise / defense / Complex” strategy document to **what Chump actually ships**, what is **overstated in vendor-style narratives**, and **ordered work** to close gaps without collapsing research and production into one backlog.

**Related:** [ROADMAP.md](ROADMAP.md) section *Strategic evaluation alignment*; master vision [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md); defense execution [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md), [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md).

**Planning stack (read in order):**

1. [ROADMAP.md](ROADMAP.md) — what is allowed to be “next” for the product.  
2. **This file** — reality check + ordering of *themes* when a new strategy paper lands.  
3. [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) — **WP-ID** registry, acceptance, status, handoff template (§3–§4 there).

---

## Executive summary

1. **Diagnoses that match the repo:** local inference can be fragile (MLX/vLLM/Ollama); shell/launchd recovery ([`scripts/farmer-brown.sh`](../scripts/farmer-brown.sh)); Android background limits on long-lived SSH; heuristic `run_cli` risk vs obfuscation; speculative rollback does **not** reverse filesystem/API/Discord side effects ([TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md)); single-tenant vs enterprise SSO expectations.

2. **Prescriptions to decouple:**  
   - **Stabilization** (inference + ops + honest security story)  
   - **Pilot / GTM packaging** (repro, metrics, audit narrative)  
   - **Fleet transport** (outbound channel, graceful degradation)  
   - **Research** (EFE-formal policy, broader WASM for arbitrary code) — **lab-gated**, not blocking demos.

3. **Corrections vs common paper claims:**

| Claim | Reality in this repo |
|-------|----------------------|
| “No Tower / no middleware” | Tools go through **`tool_middleware`** (timeout + health); full `ServiceBuilder` extras are incremental ([RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md)). |
| “WASM will replace run_cli soon” | **`wasm_calc`**, **`wasm_text`** + WASI path exists ([WASM_TOOLS.md](WASM_TOOLS.md)); **`run_cli`** remains a host-trust surface. |
| “mistral.rs is the fix” | **HTTP remains default** (vLLM-MLX / Ollama). **Optional** in-process **`mistralrs`** backend: **`--features mistralrs-infer`**, **`CHUMP_INFERENCE_BACKEND=mistralrs`** — [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b, [RFC-inference-backends.md](rfcs/RFC-inference-backends.md). |
| “No neuromodulation / workspace” | **Shipped:** `neuromodulation`, `blackboard`, `holographic_workspace`, `belief_state`, `speculative_execution`, etc. Formal **EFE minimization** and paper-grade **HRR theory** still differ from implemented proxies ([CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md)). |

---

**Executable WPs:** [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) §3 (master table), §16 (order), §17 (when to close ROADMAP umbrella).

## Phased work order (recommended)

1. **Inference / ops** — Degraded-mode playbooks, OOM/fallback documentation, optional UX surfacing of `inference.error` from `/api/stack-status` (Cowork stack pill already reflects reachability).
2. **Defense pilot kit** — One-page repro + export + approval story ([DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md)).
3. **Fleet** — Design + spike: outbound WebSocket/MQTT vs SSH-only; Mac **paused** when sentinel absent (spec in ROADMAP item).
4. **Research / backends** — RFC and isolated experiments; no production promises until gated.

---

## North-star metrics (already in product)

Pilot framing N1–N4 and `GET /api/pilot-summary` are documented in [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) and [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md).

---

## Review cadence

Re-read this file when the external strategy doc changes materially; update [ROADMAP.md](ROADMAP.md) checkboxes when deliverables merge.
