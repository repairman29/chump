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

## Repo reality check (Phase 1 decision)

The root crate **`rust-agent`** remains **binary-only** for now (no `[lib]` split). **Chosen approach: Option B — HTTP sidecar.**

- The **Tauri WebView** loads the same built [`web/`](../web/) assets as the PWA.
- The user (or a launcher script) runs **`chump --web`** (or `./run-web.sh`) so **`POST /api/chat`**, SSE, **`POST /api/approve`**, and other routes stay on **`rust-agent`** unchanged.
- **Tauri IPC** (`chump-desktop`) exposes **`get_desktop_api_base`** (default `http://127.0.0.1:3000`) and **`health_snapshot`** (GET `/api/health` via `reqwest`). The PWA uses a small **API root prefix** when the page is served from the Tauri asset host so `fetch('/api/…')` becomes `fetch('http://127.0.0.1:3000/api/…')`.
- **Override:** set **`CHUMP_DESKTOP_API_BASE`** (e.g. `http://127.0.0.1:3001`) so the shell points at a non-default web port.

**Future Option A:** add `[lib]` on `rust-agent` and invoke directly into `ChumpAgent` for **native `emit`** without a sidecar (Phase 2+).

### Phase 2+ (not implemented yet): native `emit` from `AgentEvent`

When/if the agent runs **inside** the desktop process, map [`AgentEvent`](../src/stream_events.rs) variants to stable Tauri events, e.g. `chump:tool_approval_request`, `chump:tool_call_result`, `chump:task_updated`, `chump:thinking` — same JSON shapes as SSE today to avoid dual schemas.

---

# CHUMP: Tauri frontend integration plan (technical phases)

**Target architecture:** A lightweight native shell wrapping the existing [`web/`](../web/) PWA, using Tauri IPC for **low-latency** UI updates (optionally replacing browser SSE for desktop builds).

## Phase 1: Tauri scaffold and wiring

*Objective: Initialize the Tauri app within the repo and map it to current web assets without breaking the CLI toolchain.*

- [x] **Task 1.1: Initialize Tauri**
  - Workspace member [`desktop/src-tauri`](../desktop/src-tauri); `tauri.conf.json` uses `frontendDist` → [`web/`](../web/).

- [x] **Task 1.2: Workspace integration**
  - Root [`Cargo.toml`](../Cargo.toml) lists `desktop/src-tauri`; **`cargo run --bin chump -- --desktop`** re-execs `chump-desktop` per [`src/desktop_launcher.rs`](../src/desktop_launcher.rs).

- [x] **Task 1.3: IPC bridge (sidecar B)**
  - Commands in [`desktop/src-tauri/src/lib.rs`](../desktop/src-tauri/src/lib.rs): **`get_desktop_api_base`**, **`health_snapshot`**, **`resolve_tool_approval`**, **`submit_chat`** (raw SSE string), **`ping_orchestrator`**.
  - [`web/index.html`](../web/index.html): **`__CHUMP_FETCH`** + API root for Tauri asset host; module `invoke('get_desktop_api_base')` refresh.
  - [`web/desktop-bridge.js`](../web/desktop-bridge.js): optional **`createChumpDesktopApi()`** for DevTools / harnesses.

- [x] **Task 1.4: MLX-sidecar dev fleet (local)**
  - Script [`scripts/tauri-desktop-mlx-fleet.sh`](../scripts/tauri-desktop-mlx-fleet.sh): preflight **`http://127.0.0.1:8000/v1/models`** (vLLM-MLX per [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)), **`cargo fmt`**, **`cargo clippy -p chump-desktop`**, **`cargo test -p chump-desktop`**, **`cargo check --bin chump`**. Optional **`CHUMP_TAURI_FLEET_WEB=1`** starts **`./run-web.sh`** on a high port and asserts **`/api/health`**. Documented in [OPERATIONS.md](OPERATIONS.md) (Desktop row).

- [x] **Task 1.5: Tauri auto-spawn finds repo `.env` (MLX / 8001)**  
  - Spawning **`chump --web`** sets **`current_dir`** to **`CHUMP_REPO`** / **`CHUMP_HOME`** when that directory contains **`.env`**, else walks parents of **`chump-desktop`** until both **`.env`** and **`Cargo.toml`** exist (dev **`target/debug`** layout). Ensures [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) **MLX 8001** (or **8000**) in **`.env`** applies when the desktop shell starts the sidecar without extra env.

- [x] **Task 1.6: Dock / Finder `.app` (macOS)**  
  - Script [`scripts/macos-cowork-dock-app.sh`](../scripts/macos-cowork-dock-app.sh): **`cargo tauri build`**, copy **`chump`** into **`Chump.app/Contents/MacOS/`**, inject **`LSEnvironment`** (**`CHUMP_HOME`**, **`CHUMP_BINARY`**, **`PATH`**), ad-hoc **`codesign`**. Guide: [TAURI_MACOS_DOCK.md](TAURI_MACOS_DOCK.md). **`beforeBuildCommand`** in **`tauri.conf.json`** builds release **`chump`** before bundling.

## Phase 2: Streaming the “Cowork” state

*Objective: Move from raw chat logs to structured execution UI and masked thinking.*

- [x] **Task 2.1: Emit native events (contract documented; Rust `emit` wiring deferred to Option A)**
  - **Done:** SSE ↔ future Tauri channel naming and JSON payloads documented in [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) (“SSE event names”, “Tauri native emit (Phase 2 — contract only)”).
  - **Open:** Extend [`src/stream_events.rs`](../src/stream_events.rs) / agent wiring so an in-desktop `AppHandle` can call `emit` with the same payloads when Option A lands.

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
