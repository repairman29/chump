# Next-Gen Competitive Intelligence — 2026 Agent Ecosystem Review

> **Generated:** 2026-04-15 | **Scope:** 20 open-source projects across 5 tiers | **Purpose:** Identify adoptable patterns to harden Chump's core and extend its moats.

## Executive Summary

The 2026 autonomous agent ecosystem has bifurcated: **Python dominates mass-market agents** (Hermes at 89.8K stars), while **Rust, Go, and C++ are consolidating the execution/security layer**. Chump's positioning — local-first Rust monolith with synthetic consciousness — is validated as unique. No project in the review has anything comparable to Chump's cognitive architecture (surprisal, neuromod, beliefs).

**Three convergent trends demand action:**
1. **Encrypted + Auditable** is becoming table stakes (IronClaw, OpenCoordex both ship sqlcipher + audit chains)
2. **Self-improvement is converging on SKILL.md + evolutionary loops** (Hermes, AutoEvolve, GEPA)
3. **Distributed inference mesh** is emerging for commodity hardware (Exo, llama.cpp RPC, Petals)

## Projects Reviewed

| # | Project | Stars | Lang | Tier | Verdict |
|---|---------|-------|------|------|---------|
| 1 | Capsule | ~50 | Rust | Arch Peer | **ADOPT** fuel metering |
| 2 | AutoAgents | ~30 | Rust | Arch Peer | **LEARN** multi-crate workspace |
| 3 | Rig | ~5K | Rust | Arch Peer | **LEARN** OTel GenAI conventions |
| 4 | IronClaw | ~100 | Rust | Arch Peer | **ADOPT** sqlcipher + leak scanning |
| 5 | OpenCoordex | 2 | Rust | Arch Peer | **ADOPT** tamper-evident audit chain |
| 6 | GEPA | Research | Python | Self-Improving | **ADOPT** ASI formalization |
| 7 | Hermes Agent | 89.8K | Python | Self-Improving | **ADOPT** doctor + SKILL.md |
| 8 | AutoEvolve | 11 | Python | Self-Improving | **ADOPT** Bradley-Terry + skill mutation |
| 9 | AgentMesh | 5 | Go | Security/WASM | **LEARN** COW checkpoints, circuit breakers |
| 10 | ClamBot | 11 | Python | Security/WASM | **ADOPT** clam caching, SSRF, secrets |
| 11 | AgentGuard | Various | Various | Security/WASM | **ADOPT** PII redaction |
| 12 | Compozy | — | — | Orchestration | **SKIP** (no OSS repo) |
| 13 | Pipecat | ~12K | Python | Orchestration | **LEARN** message bus for fleet |
| 14 | ruflo | — | — | Orchestration | **SKIP** (research only) |
| 15 | go-agent | ~100 | Go | Orchestration | **ADOPT** MMR diversity |
| 16 | oh-my-pi | — | Rust | Edge/Context | **LEARN** type-state guardrails |
| 17 | EdgeAI SDK | ~200 | C++ | Edge/Context | **LEARN** confirms local-first |
| 18 | rqlite | ~16K | Go | Edge/Context | **LEARN** distributed SQLite (fleet) |
| 19 | SGLang | ~20K | Python | Edge/Context | **LEARN** RadixAttention profile |
| 20 | Mohini | — | Rust | Edge/Context | **LEARN** (repo 404'd) |

## Adoption Sprints

### Sprint A: Defense Trinity (P0)

| ID | Pattern | Source | Target | Effort |
|----|---------|--------|--------|--------|
| A1 | Encrypted-at-rest SQLite (`sqlcipher`) | IronClaw, OpenCoordex | `db_pool.rs` | Medium |
| A2 | WASM fuel metering (in-process wasmtime) | Capsule | `wasm_runner.rs` | Medium |
| A3 | Tamper-evident audit chain (SHA-256) | OpenCoordex | `tool_middleware.rs` | Small |

**Why first:** "Encrypted + Auditable + Typed" is a defense story no Python agent can tell. Compounds into massive positioning advantage for federal/enterprise and privacy-conscious individual users.

### Sprint B: Self-Improvement Loop (P1)

| ID | Pattern | Source | Target | Effort |
|----|---------|--------|--------|--------|
| B1 | Bradley-Terry ratings for skill variants | AutoEvolve | New `src/ratings.rs` | Small |
| B2 | Skill mutation + evolution loop | AutoEvolve, GEPA | `skills.rs` | Medium |
| B3 | SKILL.md standard format | Hermes, AutoEvolve | `skills.rs` | Small |
| B4 | Clam-style skill result caching | ClamBot | `skills.rs` | Small |

**Why next:** Chump has the *infrastructure* (skills.rs, battle_qa, surprise tracker) but not the *loop*. Bradley-Terry + skill mutation closes the gap. SKILL.md enables cross-agent interop.

### Sprint C: Security Hardening (P1)

| ID | Pattern | Source | Target | Effort |
|----|---------|--------|--------|--------|
| C1 | Leak scanning in tool output | IronClaw, AgentGuard | `tool_middleware.rs` | Small |
| C2 | SSRF protection (private IP blocking) | ClamBot | `tool_middleware.rs` | Small |
| C3 | Host-boundary secret pinning | ClamBot | `tool_middleware.rs` | Small |
| C4 | MMR diversity in memory retrieval | go-agent | `memory_graph.rs` | Small |

### Sprint D: Observability + UX (P2)

| ID | Pattern | Source | Target | Effort |
|----|---------|--------|--------|--------|
| D1 | OTel GenAI semantic conventions | Rig, AgentMesh | `tracing_init.rs` | Small |
| D2 | ASI formalization for reflection | GEPA | New `src/reflection.rs` | Medium |
| D3 | `chump doctor` self-diagnosis | Hermes | New CLI command | Small |
| D4 | SGLang as inference profile option | SGLang | `docs/INFERENCE_PROFILES.md` | Small |

## Competitive Positioning

### Where Chump is unique (invest)
- **Consciousness framework** — real-time surprisal, neuromod, belief states. Nothing else has it.
- **Memory graph** — PPR + FTS5 + embedding RRF. Most sophisticated retrieval in the review.
- **Defense/sovereignty** — Rust + encrypted + audited + air-gapped. Federal-ready.

### Where Chump must catch up (table stakes)
- **Encrypted SQLite** — IronClaw and OpenCoordex both ship it.
- **Fuel metering** — Capsule has in-process wasmtime fuel. Chump's WASM is CLI-spawned.
- **Skill evolution** — Hermes and AutoEvolve iterate skills; Chump doesn't yet.

### Hermes competitive note
Hermes (89.8K stars) validates Chump's feature checklist (skills, cron, memory) but Chump differentiates on *how*: typed, audited, encrypted, cognitive. See `docs/HERMES_COMPETITIVE_ROADMAP.md` for detailed gap analysis. Key updates since last review: ACP adapter, multi-platform messaging (6 channels), RL training via tinker-atropos, Skills Hub at agentskills.io, Homebrew packaging.

## Future: Distributed Inference Mesh

**Vision:** Chump for anyone who owns hardware. Devices aggregate into a LAN mesh for distributed inference — split a 13B model across 4 old laptops with 4GB RAM each. Farm grows as devices are added.

**Enablers from review:** rqlite (#18) for shared state, Pipecat message bus (#13) for coordination, Exo/llama.cpp RPC for tensor splitting. Chump's `provider_cascade.rs`, air-gap mode, and heartbeat already map to mesh roles.

**Execution path:** Harden single-node (Sprints A-D) → Exo/llama.cpp RPC inference profile → rqlite shared state → `chump farm` CLI.

---

*See `docs/COMPETITIVE_DEEP_DIVE.md` for the broader strategic framework and build-vs-copy playbook.*
