# PRODUCT-012 — PWA Rebuild Decision

> Framework choice and architectural rationale for `web/v2/`.
> Deliverable for PRODUCT-012. Informs PRODUCT-013 (first vertical slice).
> Author: automated gap agent, 2026-04-21.

---

## Decision: Vanilla JS + Web Components (no build step)

**Pick: native browser APIs — Custom Elements v1, ES modules, CSS custom properties.**

No React, no Vue, no Svelte, no htmx, no bundler, no transpiler.

---

## Rationale tied to PRODUCT-011 principles

### P7 — Air-gap first (non-negotiable)

Every framework that requires a CDN or a build step violates P7. The old `web/index.html` is already a 5,337-line vanilla JS monolith, proving the approach works at scale. Web Components add structure without adding a build dependency.

React/Svelte/Vue all need either a CDN hit or an `npm install` + bundler. If the user is offline (Ollama-only, no internet), those frameworks simply don't load — the app is broken. Vanilla + Web Components loads from whatever the server caches in the service worker.

### P1 — Steal the best, skip the baggage

What we steal from PRODUCT-011's competitive analysis:
- **Cline's per-tool-call card display** → `task-card` component in v2
- **Open WebUI's model picker** → `chump-model-indicator` (placeholder; full picker in PRODUCT-013)
- **Mission-control layout** (not chat-first) → sidebar nav + main content pane

What we skip:
- Chat-first layout (v1's index.html is 90% chat UI — v2 puts Tasks first)
- Conversation tree branching (not relevant to Chump's always-on model)
- Proprietary component libraries (keep the browser as the only runtime dependency)

### P6 — Autonomy loop must be visible

v2's header shows `<chump-heartbeat>` — a live indicator of agent state (online/offline, session count, last-checked timestamp). This is the first step toward the "mission control panel" described in P6. The belief-state HUD and task feed panels are wired in the app shell but feed from real API endpoints.

### P3 — Cost transparency

Model indicator (`<chump-model-indicator>`) polls `/api/health` and surfaces which model is active. Cost-per-call display is slotted for PRODUCT-013 vertical slice.

---

## Why not htmx?

htmx was the other recommended option. It would work, but:
- htmx requires loading a ~14 KB script (from CDN or self-hosted)
- Its model is server-driven HTML fragments — good for SSR, but Chump's API already returns JSON, not HTML fragments
- htmx adds no value over native `fetch()` + Web Components for a JSON API client
- Self-hosting htmx is an extra file to maintain and cache

Web Components give us component isolation (encapsulation, lifecycle hooks) with zero additional payload.

---

## Why not React/Svelte/Vue?

| Concern | React/Svelte/Vue | Vanilla + WC |
|---|---|---|
| Air-gap install | Needs CDN or npm + bundler | None — ships as .js files |
| Bundle size | 40–200 KB compressed | ~3 KB (app.js) |
| Build dependency | webpack/vite/rollup | None |
| Browser support | Polyfill layer needed for WC | Native since Safari 10.3 |
| Offline reliability | Framework must load before app works | Service worker caches app.js directly |
| iOS PWA installability | Works, but adds complexity | Works natively |

---

## v2 shell structure

```
web/v2/
├── index.html     — app shell (CSS + HTML layout, no inline JS)
├── app.js         — Web Component definitions + router + boot
├── manifest.json  — PWA manifest scoped to /v2/
└── sw.js          — Service worker: cache shell, skip API cache
```

**Component inventory:**

| Component | Purpose | Status |
|---|---|---|
| `<chump-nav>` | Sidebar / bottom-tab navigation | shell |
| `<chump-model-indicator>` | Active model display + health poll | shell |
| `<chump-heartbeat>` | Live agent status + session count | shell |
| `<chump-view-tasks>` | Task feed (polls /api/tasks) | shell |
| `<chump-view-memory>` | Lesson/memory list (polls /api/briefing) | shell |
| `<chump-view-settings>` | Version + config info | shell |

All components are registered with `customElements.define()` in `app.js`. No shadow DOM is used in the shell — global styles are sufficient at this scale. Per-component shadow DOM can be added in PRODUCT-013 where style isolation matters.

---

## Migration path

| Phase | Scope | Gap |
|---|---|---|
| v2 shell (this PR) | Nav + layout + stub views | PRODUCT-012 |
| First vertical slice | Chat pane connected to `/api/chat` SSE | PRODUCT-013 |
| Feature parity | All v1 features ported to components | PRODUCT-014+ |
| v1 retirement | Remove `web/index.html` | When PRODUCT-013 stack-ranked |

`web/` (v1 flat files) remains untouched until v2 reaches feature parity. The server's `ServeDir` serves both: `/` → v1 index, `/v2/` → v2 shell.

---

## PWA installability notes

- **iOS Safari**: PWA install via "Add to Home Screen". Requires `<meta name="apple-mobile-web-app-capable">`, standalone display mode, and all icon sizes. v2 manifest references shared `/icon-192.png` and `/icon-512.png` from v1.
- **Android Chrome**: "Add to Home Screen" banner fires when manifest + SW are registered. `scope: /v2/` means the installed app stays within v2 routes.
- **Air-gap test**: Service worker pre-caches all shell assets on install. Throttle to offline → reload `/v2/` → shell renders from SW cache. API calls (tasks, memory) degrade gracefully with placeholder messages.

---

*Prepared by: Chump autonomous agent (PRODUCT-012, 2026-04-21). Tied to PRODUCT-011 competitive analysis.*
