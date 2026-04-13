# Desktop vs PWA parity checklist (universal power **P5.3**)

**Purpose:** One place to see which **universal-power** PWA surfaces are **shared**, **partial**, or **missing** on **Tauri (`chump-desktop`)** and **ChumpMenu (Swift)**. Use this when prioritizing Cowork work ([TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md)) or filing gaps.

**Legend**

| Mark | Meaning |
|------|---------|
| **✅** | Same contract as browser PWA (same `web/` bundle and/or same HTTP API). |
| **⚠** | Works but thinner UX, different entrypoint, or doc-only contract (IPC) vs full PWA. |
| **🔲** | Not shipped on that surface; tracked in [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) Phase 2–3 or ChumpMenu backlog. |

**Prep for testing:** `./run-web.sh` (or `chump --web`); for Tauri, `cargo run --bin chump -- --desktop` or **Chump.app** per [TAURI_MACOS_DOCK.md](TAURI_MACOS_DOCK.md). Scripted UX rows: [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md).

---

## Core chat and engine

| Area | Browser PWA | Tauri (`chump-desktop` + `web/`) | ChumpMenu (Swift) |
|------|---------------|-------------------------------------|---------------------|
| **POST `/api/chat` + SSE** | ✅ | ✅ (WebView + `__CHUMP_FETCH` → sidecar) | ✅ (`ChatTabView` native SSE) |
| **Session persistence** (`session_id`, `/api/sessions`) | ✅ | ✅ | ⚠ (session id from SSE; no full sessions UI in menu bar) |
| **Stop mid-stream** | ✅ | ✅ | 🔲 (confirm in Swift UI) |
| **Engine offline gate** (health / retry) | ✅ | ✅ (Tauri spawn + gate in `web/`) | ⚠ (Status tab + `getChumpOnline`; chat path may differ) |
| **`CHUMP_WEB_TOKEN` in Settings** | ✅ | ✅ | ⚠ (configure via `.env` / repo; no full Settings parity in Swift) |

---

## Approvals and governance

| Area | Browser PWA | Tauri | ChumpMenu |
|------|---------------|-------|-----------|
| **`tool_approval_request` → Allow/Deny** | ✅ | ✅ (inline card + `POST /api/approve`) | ✅ (`Allow once` / `Deny` in `ChatTabView`) |
| **Editable command before approve** | 🔲 | 🔲 | 🔲 ([TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) Task 3.3) |
| **Settings → Governance snapshot** (audit + COS) | ✅ | ✅ | 🔲 |
| **Session policy override** (`CHUMP_POLICY_OVERRIDE_API`, `/api/policy-override`) | ✅ | ✅ (same `web/`) | 🔲 (API-only unless added to Swift) |

---

## Sidecar and dashboard (PWA chrome)

| Area | Browser PWA | Tauri | ChumpMenu |
|------|---------------|-------|-----------|
| **Tasks tab** (list, spine hint, `/task`) | ✅ | ✅ | 🔲 (use PWA in browser or Tauri for task UI) |
| **Providers** (stack/cascade, autopilot, working repo) | ✅ | ✅ | 🔲 |
| **Briefing** | ✅ | ✅ | 🔲 |
| **Dashboard** (pilot summary, jobs link) | ✅ | ✅ | 🔲 |
| **Execution sidebar (dedicated task checklist pane)** | 🔲 | 🔲 | 🔲 ([TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) Task 2.2) |

---

## Notifications and attachments

| Area | Browser PWA | Tauri | ChumpMenu |
|------|---------------|-------|-----------|
| **Web Push subscribe** (`/api/push/*`) | ✅ | ⚠ (same code; OS notification permission differs) | N/A |
| **Attachments + upload** | ✅ | ✅ | 🔲 (menu chat may be text-first; verify before pilot) |

---

## Desktop-only / IPC (Tauri)

| Area | Browser PWA | Tauri | ChumpMenu |
|------|---------------|-------|-----------|
| **`get_desktop_api_base` / `health_snapshot` IPC** | N/A | ✅ | N/A |
| **`resolve_tool_approval` / `submit_chat` IPC** | N/A | ✅ (harness / bridge) | N/A (uses HTTP directly) |
| **Auto-spawn `chump --web` + cwd `.env` discovery** | N/A | ✅ ([TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) Task 1.5) | N/A |
| **OOTB first-run** (`ootb` module) | ⚠ (Settings **Quick setup** + composer bar; not a full wizard) | ⚠ ([PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md)) | 🔲 |

---

## How to use this doc

1. **Ship a PWA feature** — add a row here (or extend an existing row) and set Tauri to **✅** if `web/` picks it up automatically; **⚠** if WKWebView or permissions need validation.  
2. **Plan Cowork Phase 2–3** — every **🔲** in the Tauri column that matters for “execution-first” UX should map to a task in [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md).  
3. **ChumpMenu** — treat as **lightweight operator + chat** until product explicitly merges with Cowork; keep parity honest (**🔲**) rather than assumed.

---

## Changelog

| Date | Note |
|------|------|
| 2026-04-09 | PWA onboarding checklist row: browser column **⚠** (Settings + bar; keys in ONBOARDING_FRICTION_LOG). |
| 2026-04-13 | Initial **P5.3** checklist (universal power); links to Tauri plan + UI matrix 20. |
