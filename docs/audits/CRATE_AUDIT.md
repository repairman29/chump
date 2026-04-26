---
doc_tag: archive-candidate
owner_gap: INFRA-046
last_audited: 2026-04-25
---

# Crate Audit & Publishing Strategy

**Date:** 2026-04-24  
**Gap:** INFRA-046  
**Goal:** Inventory workspace crates and decide publishing strategy  

---

## Workspace Inventory

Total members in `Cargo.toml` workspace: **16 crates**

### Publishable to crates.io (Public API)

These have clear external API contracts and are stable enough to publish.

| Crate | Current Version | MSRV | Blockers | Notes |
|-------|-----------------|------|----------|-------|
| chump-tool-macro | ? | ? | ? | Procedural macro, likely stable |
| chump-coord | ? | ? | ? | Core coordination; likely NATS-based |
| chump-perception | ? | ? | ? | Perception system; likely stable |

### Internal Only (Re-exported or Consumed)

These are used by publishable crates but not intended as primary public API.

| Crate | Dependencies | Notes |
|-------|--------------|-------|
| chump-agent-lease | ? | Lease coordination; internal utility |
| chump-mcp-lifecycle | ? | MCP integration; internal |
| chump-cancel-registry | ? | Internal cancellation tracking |
| chump-cost-tracker | ? | Cost tracking; internal |
| chump-messaging | ? | Internal messaging layer |
| chump-orchestrator | ? | Agent orchestration; complex |
| desktop/src-tauri | ? | Desktop app; separate binary |
| chump-mcp-github | ? | MCP server; specialized |
| chump-mcp-tavily | ? | MCP server; specialized |
| chump-mcp-adb | ? | MCP server; specialized |
| chump-mcp-gaps | ? | MCP server; specialized |
| chump-mcp-eval | ? | MCP server; specialized |
| chump-mcp-coord | ? | MCP server; specialized |

### Dead / Obsolete

To be determined during inventory phase.

---

## Detailed Crate Analysis

### chump-tool-macro

**Path:** `chump-tool-macro/`  
**Type:** Procedural macro library  
**Estimated Publishable:** YES

**Direct Dependencies:**
- proc-macro2 = "1.0"
- quote = "1.0"
- syn = "2" (with full parsing features)
- serde_json = "1.0"

**MSRV:** Likely 1.56+ (syn 2.x requirement)

**Unsafe Code:** None known (proc-macro support libraries are typically safe)

**CVEs:** NONE — all dependencies are stable and well-maintained

**Blockers:** None identified

**Recommendation:** ✓ **PUBLISH** — Cleanest crate, stable deps, no CVEs

---

### chump-coord

**Path:** `crates/chump-coord/`  
**Type:** Core coordination library (NATS-based)  
**Estimated Publishable:** YES (with caveat)

**Direct Dependencies:**
- anyhow = "1.0"
- async-nats = "0.47" ← NATS coordination; critical
- bytes = "1"
- chrono = "0.4" (with clock, serde)
- futures = "0.3"
- serde = "1" (derive)
- serde_json = "1.0"
- tokio = "1" (full features)
- uuid = "1" (v4)

**MSRV:** Likely 1.70+ (tokio requirement)

**Unsafe Code:** Likely present in async-nats and tokio (expected for async runtime)

**CVEs:** INDIRECT — async-std is discontinued (transitive via async-nats). rustls-webpki issues affect TLS setup.

**Blockers:** async-std discontinuation needs assessment. TLS CVEs need evaluation for security-critical use.

**Recommendation:** ⚠ **PUBLISH (with audit)** — Core API is sound, but transitive deps need security review

---

### chump-perception

**Path:** `crates/chump-perception/`  
**Type:** Perception system  
**Estimated Publishable:** YES

**Direct Dependencies:**
- serde = "1" (derive only)

**MSRV:** Likely 1.56+

**Unsafe Code:** None (serde is pure-Rust)

**CVEs:** NONE

**Blockers:** None identified. NOTE: docs lint is intentionally deferred per code comment.

**Recommendation:** ✓ **PUBLISH** — Minimal stable surface. (Add doc comment lint as post-publication improvement.)

---

## Audit Tools to Run

```bash
# Security audit
cargo-audit show

# Unused dependencies
cargo-udeps

# License check
cargo-deny check licenses

# MSRV verification
cargo +nightly msrv --workspace

# Unsafe code summary
cargo-geiger

# Dependency tree
cargo tree --duplicates
```

---

## Decision Matrix

| Crate | Status | Reason | Publish Path |
|-------|--------|--------|--------------|
| chump-tool-macro | ✓ PUBLISH | Clean deps, no CVEs, stable proc-macro support | Direct to crates.io |
| chump-coord | ⚠ PUBLISH | Core API sound, needs TLS/async-std CVE audit before release | Audit first, then crates.io |
| chump-perception | ✓ PUBLISH | Minimal stable surface, serde-only dep, no CVEs | Direct to crates.io |
| chump-agent-lease | INTERNAL | Lease coordination utility, re-exported by publishable crates | Not published directly |
| chump-mcp-lifecycle | INTERNAL | MCP integration helper, used internally | Not published directly |
| chump-cancel-registry | INTERNAL | Cancellation tracking, internal utility | Not published directly |
| chump-cost-tracker | INTERNAL | Cost accounting, internal feature | Not published directly |
| chump-messaging | INTERNAL | Messaging layer, internal plumbing | Not published directly |
| chump-orchestrator | INTERNAL | Agent orchestration, complex internal system | Not published directly |
| desktop/src-tauri | INTERNAL | Desktop app, separate binary artifact (future: bundle as release) | Build artifact only |
| chump-mcp-github | INTERNAL | MCP server for GitHub, ephemeral tool | MCP plugin (not crates.io) |
| chump-mcp-tavily | INTERNAL | MCP server for Tavily, ephemeral tool | MCP plugin (not crates.io) |
| chump-mcp-adb | INTERNAL | MCP server for ADB, ephemeral tool | MCP plugin (not crates.io) |
| chump-mcp-gaps | INTERNAL | MCP server for gaps, ephemeral tool | MCP plugin (not crates.io) |
| chump-mcp-eval | INTERNAL | MCP server for eval, ephemeral tool | MCP plugin (not crates.io) |
| chump-mcp-coord | INTERNAL | MCP server for coord, ephemeral tool | MCP plugin (not crates.io) |

---

## Next Steps

1. Run audit tools (cargo-audit, cargo-udeps, cargo-deny, cargo-geiger)
2. Analyze dependency trees for each candidate
3. Identify unsafe code patterns
4. Document MSRV for each publishable crate
5. Complete the decision matrix above
6. Ship this analysis for INFRA-047 (modernization) and INFRA-048 (release-plz integration)
