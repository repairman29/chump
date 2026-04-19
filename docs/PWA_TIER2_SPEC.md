# PWA Tier 2 Specification

Product specification for the Chump web PWA beyond the MVP Dashboard. See [ADR-003](ADR-003-pwa-dashboard-fe-gate.md) for the front-end architecture gate that governs when to split the single-file PWA.

**Architecture rule (must stay consistent with ADR-003):** Stay on vanilla JS + CSS in `web/index.html` until the file exceeds ~6k lines AND a second maintainer commits to split ownership, OR a Tier-2 feature needs shared component reuse across 3 surfaces.

## Shipped (Tier 1 — MVP)

| Feature | Status | Notes |
|---------|--------|-------|
| Chat interface with SSE streaming | ✓ | `/api/chat` |
| Tool approval UI (Allow once / Deny / Allow always) | ✓ | `POST /api/approve` |
| Task panel (create/list/complete) | ✓ | `/api/tasks` |
| Dashboard (health, stack status, episodes) | ✓ | `/api/health`, `/api/stack-status` |
| PWA installability (manifest + service worker) | ✓ | `web/manifest.json`, `web/sw.js` |
| Push notifications (VAPID) | ✓ | `CHUMP_VAPID_*` |
| Settings panel | ✓ | Runtime config options via ACP |
| OOTB wizard (first-run onboarding) | ✓ | `web/ootb-wizard.js` |
| Dark mode | ✓ | CSS variables |
| Mobile responsive | ✓ | Touch targets, drawer, input compacted |

## Tier 2 — In progress / planned

| Feature | Priority | Notes |
|---------|----------|-------|
| Permissions panel | P2 | `session/list_permissions` + `session/clear_permission` |
| Mode switcher (work / research / light) | P2 | `session/set_mode` wired in ACP |
| Thinking stream display | P2 | `Thinking` events from `session/update` |
| Memory search UI | P3 | `GET /api/memory/search` |
| Pilot summary panel | P3 | `GET /api/pilot-summary` |
| Full audit log page | P3 | Filterable by tool/session |
| Autonomous approval ("autopilot") controls | P3 | `CHUMP_TOOLS_ASK` tuning UI |
| Offline queue (service worker intercept) | P4 | Queue chat messages when offline |

## Architecture constraints

1. **No build step** — `web/index.html` must work by opening the file directly or being served without bundling
2. **No frameworks** until ADR-003 gate is met; prefer extracting pure functions to `web/*.js`
3. **CI verification** — `node scripts/verify-web-index-inline-scripts.cjs` checks inline scripts; Playwright e2e in `scripts/run-ui-e2e.sh`
4. **Parity with Tauri** — features that appear in PWA must have a parity plan for `chump-desktop`; see [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md)

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

## See Also

- [ADR-003](ADR-003-pwa-dashboard-fe-gate.md) — FE architecture gate
- [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) — API endpoints
- [ACP.md](ACP.md) — session modes, permissions, thinking stream
- [OPERATIONS.md](OPERATIONS.md) — `CHUMP_WEB_PORT`, `CHUMP_WEB_TOKEN`
