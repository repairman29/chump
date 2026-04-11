# RFC WP-7.1 — Agent governance toolkit–class policy: sidecar vs in-process

**Status:** Accepted (recommend **defer adopt**; no integration in tree)  
**Date:** 2026-04-09  
**Work package:** [HIGH_ASSURANCE_AGENT_PHASES.md](../HIGH_ASSURANCE_AGENT_PHASES.md) **WP-7.1**  
**Related:** [RFC-wp23-mcp-sandboxscan-class.md](RFC-wp23-mcp-sandboxscan-class.md), [RFC-wp13-mistralrs-mcp-tools.md](RFC-wp13-mistralrs-mcp-tools.md), [TOOL_APPROVAL.md](../TOOL_APPROVAL.md)

## Problem

Vendor and research “**Agent Governance Toolkit**”-class products propose **central policy** (what tools/models may run, audit, redaction) sometimes delivered as a **sidecar** or **control plane** separate from the agent runtime. Chump today implements governance **in-process**: **`tool_inventory.rs`** (registration), **`tool_middleware`** (timeout, circuit, concurrency, rate limit), **`CHUMP_TOOLS_ASK`**, **`CHUMP_AIR_GAP_MODE`**, SQLite audit tables, and **`GET /health`** introspection.

## Options

| Option | Description | Fit for Chump today |
|--------|-------------|---------------------|
| **A — In-process (status quo)** | Policy and execution share the **`chump`** binary; config via env + SQLite. | **Shipped.** Lowest integration cost; matches single-binary pilot story. |
| **B — Policy sidecar** | Separate service holds policy; agent calls it for **decide / log** before tool execution. | **Future.** Adds network hop, availability coupling, and identity between processes. Useful if **multiple** agents must share **one** policy store or if sponsor mandates separation of duties. |
| **C — Hosted governance SaaS** | Cloud policy plane with agents as clients. | **Out of scope** for default Chump posture (self-hosted, air-gap friendly). |

## Recommendation

1. **Keep Option A** as the **default** for Chump and Mabel-style deployments. Document limits honestly: **same trust domain** as the OS user running `chump`; policy bypass requires host compromise or misconfiguration, not a missing sidecar call.

2. **Option B** is **not adopted** until a **sponsor requirement** is explicit (e.g. separate ISSO-owned policy service). If adopted later, scope a **narrow API**: allow/deny + audit id per tool invocation; **no** dynamic tool discovery without [RFC-wp13](RFC-wp13-mistralrs-mcp-tools.md) gates.

3. **WP-7.2** (minimal integration) remains **blocked** until Option B is chosen **and** a security checklist is written; no code in this RFC.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-09 | Initial RFC; recommend defer sidecar adopt. |
