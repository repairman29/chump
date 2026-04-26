---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Browser Automation

Phase 3.2 of the Hermes competitive roadmap. Hermes integrates Browserbase, Browser
Use, and Chrome CDP. Chump's existing `read_url` only fetches static HTML — pages
that need JavaScript execution, login flows, dynamic content, or form interaction
require a real browser. This document describes the V1 scaffold and the planned path
to V2 / V3.

## What browser automation enables

- **Dynamic content**: pages that render through JavaScript (SPAs, infinite scroll,
  client-side routing) are invisible to `read_url`. A real browser executes the
  scripts and exposes the resulting DOM.
- **Form interaction**: clicking buttons, filling inputs, selecting from dropdowns,
  submitting forms.
- **Authenticated flows**: stepping through login / OAuth screens with persistent
  cookies and storage.
- **Screenshotting**: capturing visual state (PNG, base64) for issue triage,
  evidence in research tasks, or visual diffing.
- **DOM extraction with selectors**: querying live state after interaction, not just
  the initial response body.

## Current state — V1 scaffold

V1 ships **only** the trait, the action types, a stub backend, and a `browser` tool
that returns clear "scaffold" messages. No real browser dependency is pulled in —
keeping `cargo build` cheap and the dependency graph small until V2 is funded.

Files:

- `src/browser.rs` — `BrowserBackend` trait, `BrowserAction`, `BrowserPage`,
  `StubBrowserBackend`, `get_browser_backend()` factory.
- `src/browser_tool.rs` — `BrowserTool` implementing `axonerai::tool::Tool` with
  `action` enum: `open | navigate | click | fill | screenshot | extract | close`.
- Registered in `src/tool_inventory.rs` as `"browser"`. Deliberately **not** in
  `LIGHT_CHAT_TOOL_KEYS` (heavy tool).

Calling any action today returns a message like:

```
[scaffold] open: browser tool is a V1 scaffold — actual driver integration is pending.
Build with `--features browser-automation` once V2 lands. For static page reads use
`read_url` instead.
```

The tool exists, validates input, and is discoverable by planners — they can plan
around the gap rather than failing on a missing tool.

## Feature flag

```toml
[features]
browser-automation = []  # V1: empty. V2: chromiumoxide / thirtyfour.
```

In V1 the flag does nothing functional. V2 will move the real driver crate behind
this gate so the default build stays lean.

## Roadmap

### V2 — local headless browser

- Add `chromiumoxide` (CDP, async, no WebDriver server) behind
  `feature = "browser-automation"`.
- Implement `ChromiumoxideBackend: BrowserBackend`. Honour `CHUMP_BROWSER_BACKEND`
  in `get_browser_backend()`.
- Persist sessions in an in-process map keyed by `session_id`.
- Capture screenshots as base64 PNG into `BrowserPage.screenshot_b64`.
- Add timeouts, navigation guard, and a max-open-sessions limit.

Alternative: `thirtyfour` (WebDriver) if chromiumoxide proves unstable on the M4
target. Trade-off: WebDriver requires a running `chromedriver` / `geckodriver`
process; CDP is in-process.

### V3 — multi-backend

- `BrowserbaseBackend` — managed remote browsers (no local Chrome required).
  Useful when running on minimal hosts or when stealth / IP rotation is needed.
- `BrowserUseBackend` — wrapper around the Browser Use agent for higher-level
  semantic actions ("find the contact form and submit it").
- Backend selection via `CHUMP_BROWSER_BACKEND=chromiumoxide|browserbase|browser_use`.

## Security

Browser sessions can navigate to arbitrary URLs and interact with forms, including
ones that may exfiltrate data or trigger side effects. Defaults are conservative:

- **Approval-gated by default**: include `browser` in `CHUMP_TOOLS_ASK` so each
  action prompts a human. Example:
  ```
  CHUMP_TOOLS_ASK=run_cli,write_file,git_push,browser
  ```
- **Air-gap aware**: V2 should respect `CHUMP_AIR_GAP_MODE` and refuse to register
  the tool when air-gap is on (matching `read_url`).
- **Sandboxing**: V2 chromiumoxide backend should run with `--no-sandbox` only when
  explicitly opted in. Prefer the OS sandbox.
- **Session lifetime caps**: enforce a max wall-clock and max actions per session
  to bound runaway loops.
- **Domain allowlist**: V2 should support `CHUMP_BROWSER_ALLOWED_DOMAINS` to
  restrict navigation.
- **Never auto-submit forms** containing credentials, payment info, or PII without
  explicit human approval.

## Alternatives for V1 users

Until V2 lands:

- Use `read_url` for static / server-rendered pages — covers most documentation,
  GitHub READMEs, blog posts, Stack Overflow.
- For dynamic content, SSH or `run_cli` into a machine with Playwright / Puppeteer
  installed and drive it from there, then feed results back via `read_file`.
- Use the `screen_vision` tool to OCR screenshots taken manually.

## Tests

`cargo test -- browser` covers:

- `StubBrowserBackend::name()` returns `"stub"`.
- All `BrowserAction` variants serialize / deserialize cleanly.
- `BrowserTool` schema compiles as Draft 7 and rejects bad input.
- Each scaffold action returns the documented "not enabled" message.
- Required-parameter validation for `navigate`, `click`, `fill`.
