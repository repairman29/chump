# RFC WP-1.3 — mistral.rs MCP client vs Chump tool registry

**Status:** Accepted (decision recorded)  
**Date:** 2026-04-09  
**Work package:** [HIGH_ASSURANCE_AGENT_PHASES.md](../HIGH_ASSURANCE_AGENT_PHASES.md) **WP-1.3**  
**Related:** [RFC-inference-backends.md](RFC-inference-backends.md), [RFC-wp23-mcp-sandboxscan-class.md](RFC-wp23-mcp-sandboxscan-class.md) (scanner-class MCP integrations), [TOOL_APPROVAL.md](../TOOL_APPROVAL.md), `src/tool_inventory.rs`, `src/mistralrs_provider.rs`

## Problem

The mistral.rs stack (and some adjacent Rust agent examples) can integrate **Model Context Protocol (MCP)** for **dynamic tool discovery** and invocation. Chump today registers tools **in-process** via the **`inventory`** pattern and env gates (`tool_inventory.rs` → `ToolRegistry`), with **registration-time** policy (**`CHUMP_AIR_GAP_MODE`**, allowlists, optional approvals) and **uniform** execution through **`tool_middleware`** (timeouts, circuit breaker, concurrency, audit).

The question for WP-1.3 is whether Chump should adopt **mistral.rs’s MCP client** as the **primary** or **parallel** tool-discovery path for the in-process backend.

## Current Chump architecture (baseline)

| Layer | Role |
|-------|------|
| **`tool_inventory.rs`** | Compile-time list of `ToolEntry` + `is_enabled` hooks; deterministic tool order; each tool is a Rust `Tool` implementation. |
| **Env / config** | Gates such as air-gap, feature flags, API keys — evaluated **before** a tool exists in the registry. |
| **`tool_middleware`** | Every `execute()` passes through shared limits and observability. |
| **Approvals / audit** | High-risk tools use human-in-the-loop and logging assumptions tied to **known tool names** and Chump-owned schemas. |

The **`mistralrs`** integration (`mistralrs_provider.rs`) implements **`Provider`** for **chat completions** only; it does **not** replace tool registration.

## Options considered

### Option A — Chump registry only (no mistral.rs MCP for tools)

- **Behavior:** mistral.rs remains an **inference Provider**. The model receives **OpenAI-style** tool definitions derived **only** from Chump’s registry (same as HTTP providers). No MCP client in the hot path.
- **Pros:** Single authority for policy; battle QA and pilot docs stay accurate; air-gap and approvals remain **registration-time** complete; no new network surface for “surprise” tools.
- **Cons:** Adding a capability still requires a Rust `Tool` + inventory entry (or an existing generic bridge such as `run_cli` under policy).

### Option B — mistral.rs MCP client as default tool discovery

- **Behavior:** Allow the mistral.rs stack to discover and call tools via MCP servers alongside or instead of Chump’s registry.
- **Pros:** Faster experimentation with external MCP servers; aligns with ecosystem demos.
- **Cons:** **Policy bypass risk:** tools may appear **without** passing Chump registration, air-gap, or approval wiring unless a full bridge is built. **Two registries** to reconcile (name collisions, schema drift, audit attribution). **Operational complexity** (MCP server lifecycle, auth, TLS). **Battle QA** surface explodes.

### Option C — MCP bridge (future): MCP tools wrapped as Chump `Tool`s

- **Behavior:** A dedicated adapter process or module that **imports** MCP tool metadata and exposes **only** allowlisted operations as first-class Chump tools, still executing through **`tool_middleware`** with explicit env **`CHUMP_MCP_*`** (hypothetical).
- **Pros:** Could satisfy “use MCP servers” without abandoning governance **if** mapping and allowlists are strict.
- **Cons:** Not implemented; belongs with **Phase 7** governance / **WP-7.1**-class work, not Phase 1 inference substrate.

## Decision

1. **Adopt Option A for all supported configurations** (HTTP and in-process mistral.rs). Chump’s **`tool_inventory.rs`** remains the **sole source** of which tools exist for the agent loop.
2. **Reject Option B** as a **default or undocumented side path**. No production or pilot configuration should enable mistral.rs-native MCP tool discovery without a **new RFC**, **explicit env**, **battle QA**, and **TOOL_APPROVAL** updates.
3. **Defer Option C** to a **future RFC** (candidate alignment: [HIGH_ASSURANCE_AGENT_PHASES.md](../HIGH_ASSURANCE_AGENT_PHASES.md) Phase 7 / **WP-7.1**). If pursued, acceptance must include: static or dynamic **allowlist** of MCP tool names; **audit** parity; **air-gap** behavior defined; **`battle_qa`** green; no **default-on**.

## Rationale

- **Defense / pilot:** [DEFENSE_PILOT_REPRO_KIT.md](../DEFENSE_PILOT_REPRO_KIT.md) and **§18** air-gap tooling assume **known, registered** tools. MCP discovery would undermine “registration-time” guarantees unless bridged.
- **Consistency:** HTTP providers and mistral.rs already share the same **tool list** from Chump; introducing a second discovery mechanism fractures runbooks ([INFERENCE_PROFILES.md](../INFERENCE_PROFILES.md), [OPERATIONS.md](../OPERATIONS.md)).
- **Cost / scope:** WP-1.3 is an **inference substrate** work package; full MCP governance is **cross-cutting** and belongs in the governance phase.

## Verification (WP-1.3)

- **Doc:** This RFC satisfies the **written decision** acceptance criterion.
- **Battle QA:** **Not required** for WP-1.3 closure because **no code path is enabled**. Any future **Option C** implementation must run **battle QA** before default-on (per master registry).

## Changelog

| Date | Change |
|------|--------|
| 2026-04-09 | Initial decision: Option A; B rejected default; C deferred. |
