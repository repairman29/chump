---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Chump Product Roadmap

Chump is developed against **four engineering pillars**—every milestone and task in `.chump/state.db` is graded on how measurably it advances them:

1. **Credible** — Verification over self-report: every shipped claim is backed by deterministic tests, base-vs-head regression proofs (`chump external verify-merge`), and machine-checkable receipts.
2. **Effective** — Real developer outcomes: faster multi-agent delivery on real repositories across macOS, Linux, and Windows without merge stomps.
3. **Resilient** — Self-healing supervision: crashed workers lose their leases automatically, OAuth tokens refresh ahead of expiry, and upstream HTTP `429`/`5xx` errors fail over across up to 40 model slots.
4. **Zero-Waste** — Bounded compute and token spend: sub-2ms Rust pre-commit guards, RAM-aware `CARGO_BUILD_JOBS` caps, disk-floor gates, and `$0` local Ollama/vLLM offload.

---

## Week 1 — Universal v1.0 Rust Control Plane & Packaging ✅ SHIPPED

**Outcome.** Developers on macOS, Linux, and Windows can install prebuilt `chump`, `chumpd`, and `chump-ship` binaries in under 60 seconds and coordinate parallel coding agents with zero bash, `tmux`, or Unix-socket dependencies.

**Implementing gaps:**
- **INFRA-8655** P0 — Universal 4-lane `~/.chump/config.toml` routing, OAuth auto-discovery, and multi-turn tool-call reliability
- **INFRA-8656** P0 — Cross-platform release builds (`aarch64`/`x86_64` macOS, Linux, Windows) and Homebrew tap (`repairman29/homebrew-chump`)
- **INFRA-8657** P1 — Automated `CAPABILITIES_REGISTRY.json` sync guard, release workflow hardening, and Apache-2.0 / AGPL-3.0 crate licensing audit

---

## Week 2 — Sovereign Operator Cockpit & Public Documentation Suite 🏗️ ACTIVE

**Outcome.** External teams get a clean, privacy-audited v1.0 documentation suite (`/docs/` quickstart + `/reference/` allowlisted search), interactive browser simulators, and a live local `/v2/` cockpit.

**Implementing gaps:**
- **PRODUCT-375** P1 — Allowlist-only MkDocs `/reference/` architecture, modernized multi-OS operator guides, quiet non-Discord CLI startup, and automated public-doc privacy CI gates

---

## Week 3 — Multi-Repo Outward Verification & Workspace Policies

**Outcome.** Teams running `chump onboard` and `chump improve` across polyrepo organizations can share declarative lease, cost-ceiling, and verification policies across repositories with zero manual per-repo scripting.

**Implementing gaps:**
- **INFRA-2268** P1 — Scheduled multi-repository `chump improve` verification workflows with per-repo token and PR rate ceilings
- **INFRA-2270** P2 — Typed TypeScript / Python client SDKs generated from `CAPABILITIES_REGISTRY.json` and `/api/*` schemas

---

## Week 4 — Editor-Native ACP V2 & Distributed Worker Pools

**Outcome.** Zed and JetBrains users get rich diff previews and persistent cross-restart tool permissions over `chump --acp`, while multi-workstation teams can pool GPU and build capacity safely over NATS or SSH execution backends.

**Implementing gaps:**
- **PRODUCT-137** P2 — Structured operator digest and cross-session cost/latency attribution in `/v2/`
- **INFRA-3287** P2 — Continued modular extraction of standalone Apache-2.0 crates for downstream Rust embedders

---

## Release Cadence & Stability Contract

- **`v1.0.x` patch releases:** Backwards-compatible bug fixes, model-provider preset updates, and documentation improvements (`~/.chump/config.toml` and `.chump/state.db` schemas remain strictly compatible).
- **`v1.x` minor releases:** Additive CLI subcommands, ACP protocol extensions, and optional Cargo features (`experimental-cognition`, `mistralrs-infer`, `inprocess-embed`).

---

## Related Guides

- [System Architecture](architecture/ARCHITECTURE.md)
- [5-Minute Clean Setup](process/EXTERNAL_GOLDEN_PATH.md)
- [File Leases & Worktrees](process/AGENT_COORDINATION.md)
