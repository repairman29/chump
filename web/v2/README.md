# web/v2 — Chump operator PWA

Vanilla Web Components frontend (no framework — see PRODUCT-012). Served as
the Tauri `frontendDist` and standalone at `/v2/`.

- **Design tokens, component inventory, composition rules, breakpoints, a11y
  minimums:** [`docs/design/PWA_STYLE_GUIDE.md`](../../docs/design/PWA_STYLE_GUIDE.md)
  (INFRA-1593) — read this before adding or changing anything here.
- **CSS token discipline** (enforced at commit time):
  [`docs/process/CSS_TOKEN_DISCIPLINE.md`](../../docs/process/CSS_TOKEN_DISCIPLINE.md)
  (INFRA-1590)
- **Persistence / state schema:** [`docs/api/PWA_STATE_SCHEMA.md`](../../docs/api/PWA_STATE_SCHEMA.md) (INFRA-1280)
- **Canvas concept overview:** [`docs/design/OPERATOR_CONSOLE_V2.md`](../../docs/design/OPERATOR_CONSOLE_V2.md)

Every `chump-*` custom element lives in its own `*.js` file here and is
registered via `customElements.define()`; `app.js` is the shell that wires
navigation (`<chump-nav>`) and cadence routing.
