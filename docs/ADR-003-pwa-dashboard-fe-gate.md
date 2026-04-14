# ADR-003: PWA / dashboard front-end architecture gate

**Status:** Accepted  
**Date:** 2026-04-09  
**Context:** [ROADMAP.md](ROADMAP.md) **Architecture vs proof** — “FE architecture gate” before large new dashboard surface.  
**Scope:** `web/index.html` (single-file PWA), `web/sw.js`, `web/manifest.json`, small helpers (`web/sse-event-parser.js`, `web/ui-selftests.js`, `web/ootb-wizard.js`).

## Decision

1. **Stay on vanilla JS + CSS in a single HTML shell** for the browser PWA and the Tauri WebView host. No mandatory npm bundler, no React/Vue/Svelte baseline until **both** are true:
   - **Size:** `web/index.html` exceeds ~6k lines *and* a second maintainer commits to split ownership, **or**
   - **Product:** a Tier-2 dashboard feature needs shared component reuse across **three** surfaces (browser PWA, Tauri, ChumpMenu) with the same bundle.

2. **When splitting is justified**, prefer **incremental extraction** of pure functions into `web/*.js` modules (already used for SSE parser, UI self-tests, OOTB wizard) over adopting a framework. Keep `web_server.rs` as the only API origin for new routes.

3. **Defer component frameworks** (React, etc.) until latency-sensitive chat paths have stable SSE + approval contracts in CI ([run-ui-e2e.sh](../scripts/run-ui-e2e.sh), `node scripts/verify-web-index-inline-scripts.cjs`).

## Consequences

- **Positive:** Zero build step for operators; small diffs stay reviewable; Playwright and inline-script verification stay fast.
- **Negative:** Large UI refactors are manual; designers cannot drop a component library without an explicit follow-up ADR superseding this one.

## Links

- Canonical product spec: [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) (architecture rule at top — must stay consistent with this ADR).
- Parity matrix: [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md).
- Universal power pillar: [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) **P5**.
