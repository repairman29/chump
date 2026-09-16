# PWA visual snapshot harness (INFRA-6926)

Render harness for `chump-*` web components ahead of the INFRA-1587 CSS
evacuation (moving ~2,300 LOC of inline `<style>` out of `web/v2/index.html`
into per-component shadow DOMs). It answers one question per migrated
component: **does it still render without crashing after its CSS moves?**

## Why this isn't pixel-diff yet

This is the *harness*, not the enforcement gate. Each spec loads a component
in isolation, mocks its backend fetch via Playwright `route()`, and asserts
the shadow DOM produced non-empty, visible content — no `toHaveScreenshot()`
baseline images are committed or required. That means:

- **No baseline maintenance.** The suite passes on a clean checkout with zero
  setup — nothing to commit under `__screenshots__/`, nothing to re-baseline
  when unrelated pixels shift.
- **Forward-compatible with pixel-diff.** Once a migration chunk lands
  (INFRA-1587), swap the render-sanity assertion in the affected spec for
  `expect(locator).toHaveScreenshot()` and commit a baseline for that
  component only — the harness and mock fixtures stay the same.

## Layout

```
e2e/pwa-visual/
  playwright.config.ts   static-file webServer (python3 -m http.server), no chump --web daemon needed
  fixtures/*.html         minimal host page per component, imports the real web/v2/*.js module
  specs/*.spec.ts          one spec per chump-* component slated for CSS migration
```

## Running locally

```bash
cd e2e/pwa-visual
npx playwright install --with-deps chromium   # first run only
npx playwright test
```

## Components covered

| Component | Source | Fetch mocked |
|---|---|---|
| `chump-cost-meter` | `web/v2/cost-meter.js` | `GET /api/telemetry/cost` |
| `chump-pr-card` | `web/v2/pr-card.js` | `GET /api/pr/:number` |
| `chump-workflow-timeline` | `web/v2/workflow-timeline.js` | none (renders synchronously; SSE stream is not required for initial paint) |

Add a new `fixtures/<name>.html` + `specs/<name>.spec.ts` pair for each
additional `chump-*` component as it's picked up by an INFRA-1587 migration
chunk.
