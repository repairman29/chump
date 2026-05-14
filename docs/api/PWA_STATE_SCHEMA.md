---
doc_tag: canonical
owner_gap: INFRA-1280
last_audited: 2026-05-14
---

# PWA state schema

The Chump PWA (`web/v2/`) persists operator preferences in browser `localStorage`
under a single `chump.*` namespace. This file is the source of truth for what
gets stored, why, and the validation rules.

Every consumer reads/writes via `window.chumpPrefs` (defined at the top of
`web/v2/app.js`), which:

- wraps `localStorage.getItem` / `setItem` in `try/catch` so corruption falls
  back to defaults instead of breaking the UI
- emits `kind=pwa_pref_changed {key, value_class}` on every write (telemetry,
  best-effort via `navigator.sendBeacon`)
- exposes a `resetAll()` method that wipes every `chump.*` key (wired to the
  Settings → "Reset all preferences" button)

## Keys

| Key | Type | Default | Set by | Read by | Notes |
|-----|------|---------|--------|---------|-------|
| `chump.theme` | string | `"system"` | Settings → Appearance | Top-of-app boot block, Settings | One of: `system` / `light` / `dark` / `high-contrast`. `system` follows `prefers-color-scheme`. |
| `chump.queue.filters` | object | `{}` | `<chump-view-agent>` | `<chump-view-agent>` | `{q, status, priority, effort, has_ac}`. URL query params override on first mount. |
| `chump.events.filter` | string | `""` | _planned (INFRA-1198)_ | `<chump-view-ambient>` | Sub-string filter for `kind`. |
| `chump.events.paused` | bool | `false` | _planned (INFRA-1198)_ | `<chump-view-ambient>` | Pause SSE DOM updates (stream stays connected). |
| `chump.events.autotail` | bool | `true` | _planned (INFRA-1198)_ | `<chump-view-ambient>` | Auto-pin to bottom when new events arrive. |
| `chump.sidecar.open` | bool | `true` desktop / `false` mobile | _planned (Sub-gap 5)_ | sidecar component | Right-side `Timeline / Tasks / …` panel. |
| `chump.sidecar.active_tab` | string | `"timeline"` | _planned (Sub-gap 5)_ | sidecar component | Last-selected sidecar tab. |
| `chump.sessions.collapsed` | bool | `false` | _planned (Sub-gap 5)_ | chat sessions panel | Left-side sessions list collapse. |
| `chump.timeline.autocollapse` | bool | `true` | _planned (Sub-gap 6)_ | `<chump-workflow-timeline>` | Collapse on `workflow_done`. |
| `chump.cost.thresholds` | object | `{warn:0.50, red:2.00}` | _planned (Sub-gap 7)_ | `<chump-cost-meter>` | Per-session $ thresholds. Validation: positive, warn < red. |
| `chump.stream.events.paused` | bool | `false` | _planned (Sub-gap 8)_ | Events view | See INFRA-1198. |
| `chump.stream.dashboard.paused` | bool | `false` | _planned (Sub-gap 8)_ | DashboardStream | Pause dashboard SSE updates. |
| `chump.stream.autopause_hidden` | bool | `true` | _planned (Sub-gap 8)_ | DashboardStream | Pause when tab hidden. |
| `chump.last_view` | string | `"chat"` | _deferred to PRODUCT-097_ | router | Last selected nav view. URL takes precedence. |

## Privacy contract

The schema **never** stores:

- API tokens (Anthropic, GitHub, OAuth, etc.)
- User-typed chat content
- Repository contents
- Operator email / GitHub login

It **may** store:

- The operator's own session IDs (used to detect "this is the lease holder")
- Gap IDs (already public)
- View state and filter values

PII review: any new `chump.*` key must be evaluated against this list before
adding to the schema.

## Migration safety

Every consumer reads via `chumpPrefs.get(key, fallback)`. If the JSON is
unparseable (corrupted by another tab, manual edit, or older shape), the
helper returns the `fallback` value and the UI continues to render. Writes
are atomic via `setItem` — partial corruption on power-loss is bounded to a
single key, not the whole namespace.

When the schema for a key changes shape (e.g. `chump.queue.filters` adds
a new field), the consumer should:

- Read with `get(key, defaults)` where `defaults` contains the new shape
- Spread the stored value over the defaults: `{ ...defaults, ...stored }`
- Validate each field before use

This pattern keeps old stored values working when a field is added, and
gracefully drops fields that no longer exist.

## Telemetry

Every `chumpPrefs.set()` call emits an ambient event:

```json
{
  "kind": "pwa_pref_changed",
  "key": "chump.theme",
  "value_class": "string",
  "ts": "2026-05-14T17:30:00Z"
}
```

`value_class` is one of `null`, `bool`, `number`, `string`, `array`, `object`.
The actual value is **not** sent — only its type — so operator-specific
thresholds (e.g. cost budgets) stay private.

`resetAll()` emits a single event with `key="*"` and `value_class="reset_all"`.

## Adding a new key

1. Pick a name under `chump.<feature>.<field>` (period-separated).
2. Add a row to the table above with type / default / consumer / notes.
3. Implement the consumer to read via `chumpPrefs.get(key, default)`.
4. Persist via `chumpPrefs.set(key, value)` on every change.
5. If the field affects rendering, apply it before first paint (mirror the
   theme-boot pattern at the top of `app.js`) — otherwise the operator sees
   a flash of default state.
6. Add a test case to `scripts/ci/test-pwa-state-persistence.sh` (planned).

## Reset

The Settings view exposes a "Reset all preferences" button that calls
`chumpPrefs.resetAll()`. The button confirms before nuking. After reset
the page reloads so every consumer reads fresh defaults.
