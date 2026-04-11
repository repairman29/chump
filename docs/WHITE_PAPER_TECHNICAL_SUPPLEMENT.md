# Technical supplement (appendix to Volume II)

This appendix is **only for the PDF white-paper build**.

## Implementation stack (at a glance)

| Layer | Technology |
|-------|------------|
| Agent + HTTP server | Rust (`tokio`, Axum), OpenAI-compatible client |
| Persistence | SQLite (tasks, episodes, memory, sessions, schedule, etc.) |
| Web UI | Static PWA under `web/`, SSE for chat streams |
| Desktop shell | Tauri 2 (`chump-desktop`), HTTP sidecar to `chump --web` |
| Automation | GitHub Actions: `cargo` tests, Playwright PWA E2E, Linux Tauri WebDriver E2E |
| Inference | Host-owned: Ollama, vLLM-MLX, or remote OpenAI-compatible endpoints |

## How to judge “does it work?”

Volume II includes `OPERATIONS` and the **capability checklist** chapter in this PDF. In short:

1. **CI-style gates** — `fmt`, `clippy`, `cargo test`, golden-path scripts (no live model quality proof).
2. **Golden path** — Ollama + `chump --web` + `/api/health` + one chat turn.
3. **Battle QA** — Scaled query suite; failures triaged from logs (see `BATTLE_QA` doc in repo for full procedure).
4. **Manual scenarios** — Operator checks on PWA or Discord with real tokens and repo path.

## Collaboration and governance

- **Chump ↔ Cursor** protocol and handoffs: `CHUMP_CURSOR_PROTOCOL` in this volume.
- **Tool policy and approvals**: `TOOL_APPROVAL` in this volume.
- **Limits of speculative / rollback behavior**: `TRUST_SPECULATIVE_ROLLBACK` in this volume.

## API surface

The **WEB_API_REFERENCE** chapter in this volume is the authoritative route list for integrators. Bearer auth is optional via `CHUMP_WEB_TOKEN` when the operator enables it.
