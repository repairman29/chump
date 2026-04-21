# PWA — consolidated reference

Merged from: `ADR-003-pwa-dashboard-fe-gate.md`, `PWA_TIER2_SPEC.md`, `PWA_WEDGE_PATH.md`, `DESKTOP_PWA_PARITY_CHECKLIST.md`.
Source files archived after this lands (DOC-002 Phase 4).

---

## Architecture decision (ADR-003, Accepted 2026-04-09)

**Stay on vanilla JS + CSS in a single HTML shell** (`web/index.html`) for the browser PWA and Tauri WebView host. No mandatory npm bundler, no React/Vue/Svelte baseline until **both** are true:

1. `web/index.html` exceeds ~6k lines AND a second maintainer commits to split ownership, **or**
2. A Tier-2 feature needs shared component reuse across **three** surfaces (browser PWA, Tauri, ChumpMenu) with the same bundle.

When splitting is justified, prefer incremental extraction of pure functions into `web/*.js` (already used for SSE parser, UI self-tests, OOTB wizard) over adopting a framework.

**Why:** Zero build step for operators; small diffs stay reviewable; Playwright + inline-script verification stay fast.

---

## Shipped features (Tier 1 — MVP)

| Feature | Status |
|---------|--------|
| Chat with SSE streaming | ✓ `/api/chat` |
| Tool approval UI (Allow once / Deny / Allow always) | ✓ `POST /api/approve` |
| Task panel (create/list/complete) | ✓ `/api/tasks` |
| Dashboard (health, stack status, episodes) | ✓ `/api/health`, `/api/stack-status` |
| PWA installability (manifest + service worker) | ✓ `web/manifest.json`, `web/sw.js` |
| Push notifications (VAPID) | ✓ `CHUMP_VAPID_*` |
| Settings panel | ✓ Runtime config options via ACP |
| OOTB wizard (first-run onboarding) | ✓ `web/ootb-wizard.js` |
| Dark mode | ✓ CSS variables |
| Mobile responsive | ✓ Touch targets, drawer, input compacted |
| Wedge hint banner (tasks panel) | ✓ Shown to sessions with 0 tasks completed |

---

## Tier 2 — planned

| Feature | Priority | API |
|---------|----------|-----|
| Permissions panel | P2 | `session/list_permissions` + `session/clear_permission` |
| Mode switcher (work / research / light) | P2 | `session/set_mode` |
| Thinking stream display | P2 | `Thinking` events from `session/update` |
| Memory search UI | P3 | `GET /api/memory/search` |
| Pilot summary panel | P3 | `GET /api/pilot-summary` |
| Full audit log page | P3 | Filterable by tool/session |
| Autonomous approval ("autopilot") controls | P3 | `CHUMP_TOOLS_ASK` tuning UI |
| Offline queue (service worker intercept) | P4 | Queue chat messages when offline |
| Onboarding tooltip on first load | P2 | — |
| "Try this" example task buttons | P2 | — |

---

## Desktop / PWA parity matrix

| Feature | Browser PWA | Tauri Desktop | Notes |
|---------|------------|----------------|-------|
| Chat with SSE streaming | ✓ | ✓ | Both use `/api/chat` |
| Tool approval | ✓ | ✓ | Both use `POST /api/approve` |
| Task panel | ✓ | ✓ | |
| Dashboard | ✓ | ✓ | |
| PWA installability | ✓ | N/A | Tauri is native |
| Push notifications | ✓ | ✓ via IPC | Tauri uses `health_snapshot` IPC |
| Settings panel | ✓ | ✓ | |
| OOTB wizard | ✓ | ✓ | |
| Dark mode | ✓ | ✓ | |
| Single-instance enforcement | N/A | ✓ | New launch focuses existing window |
| Native Dock icon | N/A | ✓ | `macos-cowork-dock-app.sh` |
| Offline mode | Planned | Planned | P4 |
| Permissions panel | Planned | Planned | Tier 2 |
| Mode switcher | Planned | Planned | Tier 2 |

**Known parity gaps:** Offline queue, Memory search UI, Pilot summary panel — all Tier 2/P4.

---

## PWA wedge path (first-run / onboarding)

The wedge = moment a user completes their first autonomous task (NL → plan → execute → result) without Discord or terminal. Measurable proxy: **N3 tier** (3 sessions, 1 task completed).

**Minimum path (PWA-only):**
```bash
cargo build --release
CHUMP_HOME=/path/to/brain ./target/release/chump web --port 5173
# Open http://localhost:5173, create a task in the Tasks panel
```

No `.env` required beyond `CHUMP_HOME`. Default backend: Ollama `qwen2.5:14b`.

**In-app discoverability (shipped):**
- [x] Tasks panel visible without scrolling on 1280px+ viewport
- [x] "Create task" button in hero position
- [x] Streaming tool-call progress shown
- [ ] Onboarding tooltip on first load (Tier 2)
- [ ] "Try this" example task buttons

---

## Testing

```bash
# UI self-tests (in-browser)
node scripts/run-web-ui-selftests.cjs

# E2E (Playwright)
bash scripts/run-ui-e2e.sh

# Tauri E2E (Linux CI / local)
bash scripts/run-tauri-e2e.sh

# Inline script verification
node scripts/verify-web-index-inline-scripts.cjs
```

---

## Related docs

| Doc | Topic |
|-----|-------|
| [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) | Full API surface |
| [ACP.md](ACP.md) | Session modes, permissions, thinking stream |
| [OPERATIONS.md](OPERATIONS.md) | `CHUMP_WEB_PORT`, `CHUMP_WEB_TOKEN` |
| [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) | Full first-install walkthrough |
| [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) | N1–N4 tier definitions and SQL queries |
| [PACKAGING_AND_NOTARIZATION.md](PACKAGING_AND_NOTARIZATION.md) | Tauri build + signing |
