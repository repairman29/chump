---
doc_tag: canonical
owner_gap: DOC-023
last_audited: 2026-05-08
---

# Chump as a Platform — External Consumer Guide

This directory documents how external projects consume Chump as a dependency and coordination layer.

**First reader:** Surety Robotics, Reeve team.

## Quick Navigation

| Document | Purpose |
|----------|---------|
| [onboarding.md](onboarding.md) | Getting started: bootstrap, environment setup, first integration test |
| [mcp-config-catalog.md](mcp-config-catalog.md) | MCP server configuration, discovery, and deployment |
| [integration-patterns.md](integration-patterns.md) | Vendored scripts vs `CHUMP_SCRIPTS` env, when to use each |
| [state-db-semantics.md](state-db-semantics.md) | Per-repository state.db schema, migration, multi-repo coordination |
| [two-registry-architecture.md](two-registry-architecture.md) | Gaps + missions: two-registry coordination model, query semantics |
| [failure-recovery.md](failure-recovery.md) | Common failure modes, diagnostics, recovery procedures |

## Scope

These docs assume:
- You have a Rust or Python project that can invoke Chump CLI or embed the coordination layer
- You want to use Chump's fleet coordination, agent state, or gap registry without adopting the full Chump codebase
- You are integrating with Chump in production or pre-production (not just experimentation)

## Architecture Overview

```
┌─────────────────────┐
│  Your Project       │
│  (Surety, etc.)     │
└──────────┬──────────┘
           │
           ├─→ Chump CLI (scripts/chump-*)
           ├─→ Chump SDK (crate exports)
           └─→ Coordination DB (state.db + ambient.jsonl)
           
┌─────────────────────┐
│  Chump Runtime      │
│  (local or fleet)   │
└─────────────────────┘
```

### Key Integration Points

1. **Gap Registry:** Query open gaps by domain, priority, or status; claim work atomically
2. **State DB:** Shared coordination primitives (leases, missions, fork state)
3. **MCP Servers:** Agent communication, tool use, sandboxed execution
4. **Ambient Stream:** Real-time event log for cross-agent coordination

## Before You Start

Read [onboarding.md](onboarding.md) first — it walks the bootstrap sequence and validates your environment.

For architecture deep-dive, see main project docs: [`docs/README.md`](../README.md) (Chump North Star, coordination model, Rust patterns).

---

*Last updated: 2026-05-08. For updates or questions, file a gap in your Chump instance with domain=INFRA.*
