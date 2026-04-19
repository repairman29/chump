# Tauri Frontend Plan

Integration plan for wrapping the Chump web PWA in a Tauri desktop shell. The HTTP API and SSE event stream remain unchanged — Tauri is a thin shell, not a rewrite.

Cross-link: [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) §Tauri, [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md).

## Option A — In-process bridge (long term)

Chump core runs as a Tauri sidecar. The WebView calls `invoke()` directly instead of HTTP. Zero-copy for large payloads; no port conflicts; native menus.

**Status:** Not started. Requires Tauri v2 + custom protocol handler. Blocked by architecture gate (ADR-003).

## Option B — WebView → localhost (current / near-term)

Tauri shell opens a WebView pointed at `http://127.0.0.1:5173`. Chump binary runs as a spawned child process or separately. No code changes to the web layer — the same `fetch()`/SSE calls work identically.

**Status:** Scaffolded. `src-tauri/` directory exists with shell config. Not in CI yet.

### Phase 1 — Basic wrap (done)

- [x] `src-tauri/tauri.conf.json` configured for `http://127.0.0.1:5173`
- [x] `src-tauri/src/main.rs` launches Chump binary as child process
- [x] Window title, icon, and tray icon set
- [x] macOS code-sign config stubbed (COMP-010 will fill secrets)

### Phase 2 — Native channel alignment

When the agent runs in-process (Option A) or a bridge forwards events, native `#[tauri::command]` proxies MUST reuse the same names and JSON shapes as SSE `event` + `data` rows. No duplicate schema.

Tracked channels:
- `chump/tool_call_start` — matches SSE `event: tool_call_start`
- `chump/tool_call_result` — matches SSE `event: tool_call_result`
- `chump/assistant_delta` — matches SSE `event: assistant_delta`
- `chump/session_end` — matches SSE `event: session_end`

### Phase 3 — Offline queue

Tasks created while the Chump binary is offline are queued in Tauri's local storage and replayed on reconnect. Requires [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md) item `offline-queue`.

## Build commands

```bash
# Install Tauri CLI
cargo install tauri-cli

# Dev mode (hot-reload WebView + auto-restart binary)
cargo tauri dev

# Production build
cargo tauri build
```

## Known gaps vs browser PWA

See [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md) for the full parity matrix.

Key outstanding items:
- Memory search not in desktop shell UI yet
- Pilot summary panel not shown in standalone mode
- No auto-update mechanism wired to COMP-010 Homebrew tap

## See Also

- [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md) — parity matrix
- [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) — API the WebView calls
- [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md) — FE architecture gate
- [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) — planned PWA enhancements
