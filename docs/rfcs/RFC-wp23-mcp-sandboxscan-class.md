# RFC / ADR WP-2.3 — MCP “SandboxScan-class” tooling: analysis and threat model

**Status:** Accepted (analysis only — **no production wrapper** in tree)  
**Date:** 2026-04-09  
**Work package:** [HIGH_ASSURANCE_AGENT_PHASES.md](../HIGH_ASSURANCE_AGENT_PHASES.md) **WP-2.3**  
**Related:** [RFC-wp13-mistralrs-mcp-tools.md](RFC-wp13-mistralrs-mcp-tools.md), [TOOL_APPROVAL.md](../TOOL_APPROVAL.md), [WASM_TOOLS.md](../WASM_TOOLS.md), `src/sandbox_tool.rs`, Phase **7** / **WP-7.1** (governance sidecar)

## 1. Purpose

External strategy and vendor materials sometimes propose **Model Context Protocol (MCP)** servers that combine:

- **Broad access** to a developer workspace (read trees, run subprocesses, call CLIs), and/or  
- **“Sandboxed”** or **isolated** execution of untrusted or semi-trusted code for **security scanning**, dependency audit, secret detection, license compliance, or similar.

This document calls that pattern **MCP SandboxScan-class** (a **class** of integrations, not a claim about any single trademarked product). It records a **threat model** and **adoption gates** so Chump does not accidentally ship an unreviewed bridge.

## 2. Definition: SandboxScan-class (operational)

An integration is in this class if **any** of the following hold:

| Signal | Example behavior |
|--------|------------------|
| **S1 — Wide read** | Tools that scan “the repo” or large directory globs beyond a single explicit path argument Chump already controls. |
| **S2 — Subprocess / VM** | Invokes compilers, linters, scanners, or containers **on behalf of the model**, outside Chump’s existing **`wasm_runner`** or **`sandbox_run`** contracts. |
| **S3 — Outbound from scanner** | The scanner or MCP server fetches **CVE feeds**, license DBs, or telemetry **over the network** while acting on workspace data. |
| **S4 — Dynamic tool surface** | Tool names, schemas, or servers appear **at runtime** without going through **`tool_inventory.rs`** registration (see [RFC-wp13](RFC-wp13-mistralrs-mcp-tools.md)). |

**Not in this class:** Pure WASI modules run via **`wasmtime`** with the current **`run_wasm_wasi`** contract ([WASM_TOOLS.md](../WASM_TOOLS.md)); **`sandbox_run`** with **`CHUMP_SANDBOX_ENABLED`** ([`src/sandbox_tool.rs`](../../src/sandbox_tool.rs)); ordinary **`run_cli`** under allowlist (host-trust tier).

## 3. Chump baseline (today)

| Control | What it gives |
|---------|----------------|
| **`tool_inventory.rs`** | Known tools only; env gates; **`CHUMP_AIR_GAP_MODE`** drops **`web_search`** / **`read_url`** at registration. |
| **`tool_middleware`** | Timeout, circuit breaker, **`CHUMP_TOOL_MAX_IN_FLIGHT`**, consistent execute path. |
| **`CHUMP_TOOLS_ASK`** | Human gate for listed tools; audit trail. |
| **`run_cli`** allow/block lists | Narrow shell commands on pilot devices. |
| **WASM tools** | Strong **default** isolation: no host dirs, no network in **`wasm_runner`**. |
| **`sandbox_run`** | Git worktree + bounded command; opt-in; separate trust story from WASM. |

Nothing above implements a **generic MCP client** that proxies arbitrary MCP servers into the agent loop.

## 4. Threat model (STRIDE-oriented)

| Threat | Mechanism | Chump impact if unguarded MCP bridge existed |
|--------|-----------|-----------------------------------------------|
| **Spoofing** | Attacker-run MCP server impersonates a trusted scanner. | Model trusts tool metadata and results; user thinks Chump “vetted” the server. |
| **Tampering** | Compromised MCP server returns **false negatives** (hide malware) or **false positives** (block work). | Wrong security conclusions; wasted triage; possible denial of service. |
| **Repudiation** | Calls not logged with same rigor as native tools. | Forensics gap vs **`tool_approval_audit`** / existing logs. |
| **Information disclosure** | Server exfiltrates repo contents, env, or tokens over MCP transport or side channels. | Violates air-gap narrative and sponsor data-handling expectations. |
| **Denial of service** | Scanner or MCP loop runs heavy jobs; many concurrent tools. | GPU/CPU/RAM exhaustion; overlaps **`tool_middleware`** limits but may spawn **external** processes outside those caps unless explicitly accounted for. |
| **Elevation of privilege** | MCP tool asks OS to run with broader rights than **`run_cli`** allowlist would allow. | Bypass pilot **tier-4** constraints if routed outside **`CliTool`** policy. |

**Additional agent-specific risks**

- **Tool-result injection:** Large or maliciously crafted scanner output steers the model (prompt injection via tool channel).  
- **Dependency supply chain:** MCP server binary or Node/Python shim is updated without operator review.  
- **Air-gap violation:** S3 network from scanner while operator believed **`CHUMP_AIR_GAP_MODE`** covered “all tools.”

## 5. Options (strategic)

| Option | Summary | Verdict for Chump today |
|--------|---------|-------------------------|
| **A — Status quo** | No MCP SandboxScan bridge; use **`run_cli`** / **`sandbox_run`** / WASM for bounded operations. | **Default.** Matches [RFC-wp13](RFC-wp13-mistralrs-mcp-tools.md) and pilot docs. |
| **B — Sidecar MCP client (governed)** | Separate process speaks MCP; exposes **only** fixed, allowlisted tools into Chump via explicit Rust **`Tool`** shims + same middleware. | **Future**; overlaps **Phase 7** / **WP-7.1** (policy sidecar vs in-process). Requires security checklist before any adopt. |
| **C — In-process generic MCP** | Link an MCP SDK inside **`chump`** and register discovered tools dynamically. | **Rejected** for production without a full program-level decision: breaks registration-time air-gap story and audit naming. |

## 6. Decision and gates

1. **No production MCP SandboxScan-class wrapper** ships in this repository until **all** of the following are satisfied in a **follow-on RFC** (may combine with **WP-7.1**):

   - Explicit **allowlisted** MCP servers and tool names; no ambient discovery.  
   - **Air-gap** behavior defined (fail closed or offline mode) and documented in [DEFENSE_PILOT_REPRO_KIT.md](../DEFENSE_PILOT_REPRO_KIT.md) / [OPERATIONS.md](../OPERATIONS.md).  
   - **Audit** parity with native tools (who invoked, what args, outcome).  
   - **Resource limits** for subprocess/network spawned **outside** `tool_middleware`’s current scope.  
   - **Security review** (internal or sponsor) recorded in the RFC’s changelog.

2. **WP-2.3** is satisfied by **this document** (analysis + threat model). **Implementation** is explicitly **out of scope** for WP-2.3.

3. Pilots who need “scanning” today should use **tier-4** **`run_cli`** with a **tight allowlist**, or **`sandbox_run`** where appropriate, and document the command in their runbook—not an unscoped MCP attachment.

## 7. Changelog

| Date | Change |
|------|--------|
| 2026-04-09 | Initial RFC/ADR; class definition; STRIDE table; options A–C; production gates. |
