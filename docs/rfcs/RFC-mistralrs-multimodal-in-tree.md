# RFC — mistral.rs multimodal inference in-tree (vision / media)

**Status:** Proposed (scoping — no default-on implementation yet)  
**Date:** 2026-04-12  
**Work package:** [HIGH_ASSURANCE_AGENT_PHASES.md](../HIGH_ASSURANCE_AGENT_PHASES.md) **WP-1.5** (Phase 1 — inference substrate extension)  
**Related:** [RFC-inference-backends.md](RFC-inference-backends.md), [RFC-wp13-mistralrs-mcp-tools.md](RFC-wp13-mistralrs-mcp-tools.md), [MISTRALRS_CAPABILITY_MATRIX.md](../MISTRALRS_CAPABILITY_MATRIX.md), [`src/mistralrs_provider.rs`](../../src/mistralrs_provider.rs), [INFERENCE_PROFILES.md](../INFERENCE_PROFILES.md) §2b, [DEFENSE_PILOT_REPRO_KIT.md](../DEFENSE_PILOT_REPRO_KIT.md)

## Problem

Chump’s agent loop uses **AxonerAI** `Message` (**crates.io `axonerai` 0.1** — `role` + plain string `content` only). The in-process **mistral.rs** path uses **`TextModelBuilder`** and **`RequestBuilder::add_message(TextMessageRole, &str)`** — **text-only**.

Upstream **mistral.rs 0.8.1** supports **multimodal** models via **`MultimodalModelBuilder`**, **`MultimodalMessages`**, and related types (see upstream `examples/getting_started/multimodal/`). Product surfaces (Discord attachments, PWA file uploads) can carry **images** (and eventually audio/video per model support), but those assets **never reach** the in-process model today.

## Goals

1. Allow **optional** multimodal turns when **`CHUMP_INFERENCE_BACKEND=mistralrs`** and the configured model is multimodal-capable.
2. Preserve **single tool registry** and **WP-1.3** decision (no mistral MCP client for tools).
3. Keep **HTTP providers** behavior explicit: either unchanged (text-only) or documented subset if we extend `Message` for all providers later.
4. Meet **pilot / air-gap** expectations: no new outbound fetches unless an existing approved tool path already fetched the bytes.

## Non-goals (v1 RFC scope)

- Replacing **vLLM-MLX** as default Mac production profile.
- **Audio/video** pipelines before **image** path is proven (may be a follow-on phase per upstream model table).
- **Automatic** fetching of arbitrary URLs into model context without going through existing **`read_url`** / policy (would duplicate exfil risk).

## Current architecture (baseline)

| Layer | Today |
|-------|--------|
| **AxonerAI `Message`** | `role: String`, `content: String` — crates.io **`axonerai` 0.1** in [Cargo.toml](../../Cargo.toml). |
| **Agent loop / Discord / PWA** | Text flows end-to-end; attachments may exist in Discord/PWA but are not modeled as model input. |
| **`MistralRsProvider`** | `TextModelBuilder`, text messages only. |
| **HTTP `Provider`s** | OpenAI-style JSON; typically text `content` in practice. |

## Constraints

1. **Dependency boundary:** Multimodal requires either **extending** the shared `Message` type (needs **`axonerai`** API change + release, or a patched/path dependency), **or** a **parallel** internal message type only for mistral — the latter risks forked agent-loop logic and is discouraged unless time-boxed as a spike.
2. **Model class:** `MultimodalModelBuilder` vs `TextModelBuilder` — likely **two provider implementations** or a **factory** keyed by `CHUMP_MISTRALRS_MODEL` / explicit **`CHUMP_MISTRALRS_MULTIMODAL=1`** to avoid loading the wrong pipeline.
3. **Memory / disk:** Images must be **size-capped** and **format-validated** before passing to mistral.rs (reject huge attachments; align with existing upload limits on web if any).
4. **Battle QA / CI:** Multimodal path must be **feature- or env-gated**; default CI remains text-only unless a **tiny** fixed fixture image + model is approved for a dedicated job (costly).

## Options considered

### Option A — Extend AxonerAI `Message` (preferred long-term)

- Add a structured **content** representation (e.g. `Vec<ContentPart>` with `Text` and `Image { mime, data: Vec<u8> }` or base64), with **JSON serialization** rules for HTTP providers that support vision (OpenAI-compatible `image_url` / base64).
- **Pros:** One agent-loop contract; HTTP and in-process can share the same turn history.  
- **Cons:** Requires **`axonerai`** semver bump and Chump + any forks to migrate; HTTP providers must **ignore** or **map** unknown parts safely.

### Option B — Mistral-only side struct (spike)

- Introduce `MultimodalTurn { text, images }` only on the mistral completion path; agent loop still uses string `Message` and a **separate** hook passes last user attachment — **not** full history multimodal.
- **Pros:** Fast experiment.  
- **Cons:** **Incomplete** conversation state; poor UX for multi-turn vision; high technical debt.

### Option C — Multimodal only via HTTP sidecar

- Document: use **`mistralrs serve`** or vLLM with vision + `OPENAI_API_BASE`; no in-tree change.
- **Pros:** Zero Chump multimodal code.  
- **Cons:** Does not satisfy “in-tree multimodal” backlog item.

## Recommended direction

1. **Adopt Option A** as the target architecture; schedule **implementation WP-1.5b** (or split WPs) after this RFC is **Accepted**.
2. **Phase implementation:**
   - **P1 — Contract:** Propose `axonerai` `Message` extension (or patch); version bump in Chump.
   - **P2 — In-process:** New `MultimodalModelBuilder` load path + mapping from `Message` parts → `MultimodalMessages` / upstream request types; env **`CHUMP_MISTRALRS_MULTIMODAL=1`** + model allowlist or explicit model id check.
   - **P3 — Ingress:** Discord: map attachment → bounded bytes + mime. PWA: reuse or add **`POST /api/...`** upload with auth + size cap; store ephemeral path or memory handle for the turn.
   - **P4 — HTTP providers:** For providers without vision, **concatenate** text-only or return clear error if image parts present (document in [INFERENCE_PROFILES.md](../INFERENCE_PROFILES.md)).
   - **P5 — Verification:** Battle QA scenarios + pilot note in [DEFENSE_PILOT_REPRO_KIT.md](../DEFENSE_PILOT_REPRO_KIT.md) if attachments touch regulated workflows.

## Security / governance

- **Air-gap:** Image bytes must come from **user-attached** files or **already-fetched** artifacts under tool policy — not silent URL pull into the model.
- **Approvals:** If any new “send image to model” action is classified high-risk, wire **`TOOL_APPROVAL`** / audit like other sensitive tools.
- **Logging:** Avoid logging raw base64 image bodies at **info** level; redact or hash in structured logs.

## Open questions

- Minimum **`axonerai`** version and whether to use **path** dependency until crates.io publishes multimodal `Message`.
- Which **HF model ids** are in the **supported** allowlist for v1 (e.g. one Qwen-VL + one Llava-class).
- Whether **Pixel / Mabel** scope is explicitly **out** for in-process multimodal (likely **yes** — keep [ANDROID_COMPANION.md](../ANDROID_COMPANION.md) HTTP path).

## Decision (to record when accepted)

- [ ] **Accepted** — proceed with Option A phasing; create implementation WP(s) and link from [MISTRALRS_CAPABILITY_MATRIX.md](../MISTRALRS_CAPABILITY_MATRIX.md).
- [ ] **Rejected** — stay text-only in-tree; update matrix and backlog.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-12 | Initial proposed RFC (**WP-1.5**). |
