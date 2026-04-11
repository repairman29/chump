# CHUMP: Tauri frontend integration plan (“Cowork” UI)

**For Cursor and other agents:** Read this when implementing the **Cowork-tier frontend**. The goal is a **plan-first, execution-primary** experience: chat is secondary; **live execution state** (tasks, approvals, thinking) is primary.

**Handoff:** Start with **Phase 1** below unless the product owner explicitly chooses **native Swift** ([`ChumpMenu/`](../ChumpMenu/)) or **Ratatui** instead—this document assumes **Option A: Tauri + existing PWA** for lowest Chromium-style RAM on Apple Silicon (WKWebView).

---

## Product intent: autonomous workspace (not “chatbot”)

### Core UX shift: plan-first vs chat-first

Today [`src/agent_loop.rs`](../src/agent_loop.rs) drives text and tool results. The Cowork UI should **separate conversation from action**:

1. **Execution sidebar (task planner)**  
   A persistent surface tracks the **TaskPlanner** / `chump_tasks` plan ([`docs/CLAUDE_COWORK_UPGRADE_PLAN.md`](CLAUDE_COWORK_UPGRADE_PLAN.md) Phase 3). As the orchestrator writes SQLite rows, the UI should show a **live checklist** (SSE today, Tauri events tomorrow)—users watch steps complete, not raw JSON.

2. **“Thinking” mask**  
   When the backend emits `<thinking>` / `<plan>` XML ([`docs/ROADMAP_CLAUDE_UPGRADE.md`](ROADMAP_CLAUDE_UPGRADE.md) Phase 4), the client should **not** stream raw tags by default. Show a compact **“Chump is reasoning…”** state; optional **Reveal** toggle for debugging ([`src/thinking_strip.rs`](../src/thinking_strip.rs) still applies for Discord/public surfaces).

### Approval dashboard (“sandbox” view)

`ToolApprovalRequest` ([`src/stream_events.rs`](../src/stream_events.rs), [`src/approval_resolver.rs`](../src/approval_resolver.rs)) deserves a **first-class** UI—not only Discord buttons:

- **Command preview:** For high-risk `run_cli` / future `patch_file`, show a monospace block with the **exact** command or unified diff; large **Allow** / **Deny** / **Edit**.
- **Contextual edits:** Let the user fix typos in the proposed command before approve; backend must accept **edited** payloads into the approval channel (extend resolver contract if needed).

### Stack options (recap)

| Option | Notes |
|--------|--------|
| **A — Tauri + `web/`** | Wrap existing PWA; WKWebView; IPC (`invoke` / `emit`) for low-latency updates vs HTTP polling. **This plan.** |
| **B — ChumpMenu (Swift)** | Lowest footprint; add `TasksTabView` / widen `ChatTabView`; native SSE/WebSocket. See [`ChumpMenu/README.md`](../ChumpMenu/README.md). |
| **C — Ratatui** | Terminal UI: chat / task tree / approval panes; no web stack. |

---

## Repo reality check (before Phase 1)

The root crate **`rust-agent`** is currently a **binary-only** package (`[[bin]] chump` → [`src/main.rs`](../src/main.rs)). Tauri’s Rust side usually **`invoke`s into a library** that owns `ChumpAgent`, provider, and registry.

**Recommended path:**

1. Add a **`[lib]`** target (e.g. `src/lib.rs`) that re-exports or wraps the modules needed for desktop IPC **without** breaking the existing `chump` CLI / Discord entrypoints (`main.rs` stays a thin `fn main` that calls `chump::run_cli()` or similar), **or**
2. Add a **`desktop/` or `src-tauri/`** workspace member that runs a small **local HTTP+SSE** or **JSON-RPC** loop the WebView calls—avoids lib split but keeps HTTP (simpler first step, weaker “zero HTTP” story).

Document the chosen approach in this file when Phase 1 lands.

---

# CHUMP: Tauri frontend integration plan (technical phases)

**Target architecture:** A lightweight native shell wrapping the existing [`web/`](../web/) PWA, using Tauri IPC for **low-latency** UI updates (optionally replacing browser SSE for desktop builds).

## Phase 1: Tauri scaffold and wiring

*Objective: Initialize the Tauri app within the repo and map it to current web assets without breaking the CLI toolchain.*

- [ ] **Task 1.1: Initialize Tauri**
  - Run the Tauri CLI to initialize the project (`cargo tauri init` or `pnpm create tauri-app` per current Tauri 2 docs) in `desktop/` or `src-tauri/` at the repo root.
  - Configure `tauri.conf.json` so `frontendDist` / `devUrl` points at the existing [`web/`](../web/) assets (`index.html`, `sw.js`, etc.).
  - Keep the PWA **vanilla** if possible; add a small `web/desktop-bridge.js` only if `invoke`/`listen` shims are needed.

- [ ] **Task 1.2: Workspace integration**
  - If using a Cargo workspace: add the Tauri package to `[workspace].members` alongside `chump-tool-macro` and the main crate (may require turning the root into a proper workspace—see repo check above).
  - Document a **`--desktop`** (or `chump-desktop` binary) entry path that launches the Tauri window **without** replacing `cargo run --bin chump -- --discord` behavior.

- [ ] **Task 1.3: IPC bridge**
  - Expose a minimal **`#[tauri::command]`** surface (e.g. `submit_prompt`, `list_tasks`, `approve_tool`) backed by the same types the web server uses today.
  - Update [`web/index.html`](../web/index.html) (or a dedicated bundle) to use `@tauri-apps/api` **`invoke`** where `window.__TAURI__` is present, and fall back to existing **`fetch('/api/chat')`** when running as a plain PWA in the browser.

## Phase 2: Streaming the “Cowork” state

*Objective: Move from raw chat logs to structured execution UI and masked thinking.*

- [ ] **Task 2.1: Emit native events**
  - Extend [`src/stream_events.rs`](../src/stream_events.rs) / agent wiring so that, when running inside Tauri, the event path can call `app_handle.emit_all("task_updated", payload)` (names illustrative).
  - Define stable JSON payloads: `task_added`, `task_completed`, `thinking_chunk`, `tool_approval_requested`, etc., aligned with [`AgentEvent`](../src/stream_events.rs) variants.

- [ ] **Task 2.2: Execution sidebar (UI)**
  - Update `web/index.html` to a **two-pane** layout: conversation (left/center) + **task checklist** (right).
  - Subscribe with `listen('task_added', …)` (or equivalent) and render rows from SQLite-backed events / `GET /api/tasks` until IPC fully replaces polling.

- [ ] **Task 2.3: Masking the monologue (UI)**
  - On `thinking_chunk`, append to a hidden `#thought-buffer`; show a **pulsing “reasoning”** affordance in the main stream; **Debug** chevron reveals raw XML.

## Phase 3: Native approval dashboard

*Objective: Full-screen high-risk approval with preview and editable command.*

- [ ] **Task 3.1: Intercept `ToolApprovalRequest`**
  - When the agent emits approval-needed, the desktop shell shows a **modal** that blocks interaction until resolved.

- [ ] **Task 3.2: Terminal preview component**
  - Monospace block for CLI or unified diff body (future `patch_file`).

- [ ] **Task 3.3: Editable approvals**
  - `textarea` for edited command; new `#[tauri::command]` e.g. `resolve_approval { request_id, approved, modified_command? }` wired to [`approval_resolver`](../src/approval_resolver.rs) (may require extending the resolver to accept edited tool input for `run_cli`).

---

## API / event granularity (cross-cutting)

Today **`TurnComplete`** and **`ToolCallStart`** are coarse for a Cowork UI. Track follow-ups in [`docs/WEB_API_REFERENCE.md`](WEB_API_REFERENCE.md) and [`src/web_server.rs`](../src/web_server.rs):

- Prefer **fine-grained events** (task row changed, approval pending, thinking phase started/ended) for both **SSE** (browser PWA) and **Tauri emit** (desktop).

---

## Handoff reminder

Implement **one phase (or one task) per PR**; keep `cargo test` / `cargo clippy -- -D warnings` green; update this file’s checkboxes when tasks merge.
