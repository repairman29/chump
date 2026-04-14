# Universal power / daily driver — full program

**Purpose:** Backlog to make Chump **reliable, reachable, governable, context-rich, and polished** enough to serve as a **primary execution layer** (not only a power-user science project). This doc expands the five-pillar plan; **mark sections done here** as work lands, and mirror major milestones into [ROADMAP.md](ROADMAP.md) when appropriate.

**Principles**

- Same agent stack everywhere (web, desktop, Discord, CLI) — no second-class surfaces for approvals or policy.
- **Trust scales with visibility:** more autonomy only when audit, policy, and health are legible.
- Exclude secrets from UI/logs; one-off pilot details stay in session/task notes, not global memory.

**Suggested north-star metrics (pick 1–2 to optimize)**

- **Reliability:** e.g. ≥5 consecutive days of primary use without manual inference/env repair.
- **Interruptibility:** e.g. ≥80% of blocked or completed autonomous work surfaces a user-visible signal within 5 minutes.
- **Governed breadth:** e.g. ship one additional high-risk tool class only after approval + audit path is verified in CI for every client.

---

## Pillar 1 — Reliability boring

**Goal:** Cold start and steady state feel **predictable**; operators are not the on-call SRE for their own assistant.

**Exit criteria**

- One **documented green path** (profile name + env checklist + scripts) that a clean install can follow to a passing health + chat smoke.
- **Preflight** fails loud before long jobs (models, auth, disk, ports, `tool_policy` when relevant).
- **Degraded states** are visible in PWA/desktop with **actionable** copy and links to runbooks ([OPERATIONS.md](OPERATIONS.md), [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md)).

### Backlog

- [x] **P1.1 Green-path profile** — Name the default “daily driver” stack (e.g. Ollama + web + optional token); align [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md), [README.md](../README.md), and `.env.example` so conflicting profiles are explicitly called out. **Done:** “Daily driver profile” table + preflight pointer in EXTERNAL_GOLDEN_PATH; `.env.example` already leads with Ollama block.
- [x] **P1.2 Unified preflight command** — Single entrypoint (`scripts/chump-preflight.sh` and `chump --preflight`) that checks: `GET /api/health`, `GET /api/stack-status` (inference + `tool_policy`), optional `CHUMP_WEB_TOKEN` probe, `logs/` writable; exit non-zero with terse fixes; `--warn-only` for lenient local inference.
- [x] **P1.3 CI hook** — Step in `.github/workflows/ci.yml` **test** job runs `chump-preflight.sh` after Chump web health is up (before Playwright).
- [x] **P1.4 Degraded UX matrix** — For each of: model down, wrong model id, 401 on provider, circuit open, DB locked — ensure PWA shows one consistent pattern (banner + status line + doc link). **Done:** “PWA / web degraded UX matrix” in [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) (iterate as UI grows).
- [x] **P1.5 `turn_error` completeness** — Audit agent/web paths so user-visible errors always carry **next step** (already started for timeout/refused; extend for cascade slot exhaustion, context length, tool middleware rejections). **Done:** `append_agent_error_hints` in `src/user_error_hints.rs`; wired from `web_server` chat errors, `streaming_provider`, and key `agent_loop` `TurnError` paths.
- [x] **P1.6 Local OpenAI / cascade retries** — Document and verify retry + circuit behavior in [local_openai.rs](../src/local_openai.rs) and cascade; add metrics or log lines that preflight can parse for “degraded but up.” **Done:** “OpenAI-compatible HTTP client” section in [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md); health **`model_circuit`** + cascade **`circuit_state`** already expose degraded state.

**Depends on:** nothing (start here).

**Unlocks:** P2 notifications (need trustworthy health), P5 onboarding.

---

## Pillar 2 — Reach (integrations + async)

**Goal:** Chump **shows up where work happens** — not only when the user opens chat.

**Exit criteria**

- At least **one** reliable async notification path for “done / blocked / needs approval” (user-chosen: PWA push, macOS notification, digest email, or Discord DM).
- **Stable external contracts:** shortcuts, webhooks, and cron hooks feed the **same** session/task model as chat.
- **Named execution contexts** for multi-repo / multi-host (no accidental edits in the wrong tree).

### Backlog

- [x] **P2.1 Notification MVP** — Web Push **send** from Chump: **`CHUMP_VAPID_PRIVATE_KEY_FILE`** + **`CHUMP_WEB_PUSH_AUTONOMY=1`** → `web_push_send::broadcast_json_notification` after **`--autonomy-once`** (**done** / **blocked** / **error**); **`web/sw.js`** `push` + `notificationclick`; contracts in [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) **Push** section + [OPERATIONS.md](OPERATIONS.md). (Pilot operators still use **`chump --notify`** + [AUTOMATION_SNIPPETS.md](AUTOMATION_SNIPPETS.md) for Discord/cron.)
- [x] **P2.2 Async job model** — Minimal schema: job id, type, status, linked `task_id` / `session_id`, last error; optional `GET /api/jobs` or piggyback on pilot-summary / dashboard. **Done:** `chump_async_jobs` + `job_log.rs`; **`GET /api/jobs`**; **`recent_async_jobs`** on **`GET /api/pilot-summary`**; autonomy outcomes append rows; PWA Dashboard shows a short tail.
- [x] **P2.3 Webhook ingress hardening** — Review `POST` routes used by shortcuts/automation; consistent `CHUMP_WEB_TOKEN` story, idempotency keys where needed, payload size limits documented. **Done:** [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) **Automation ingress** section.
- [x] **P2.4 Cron / launchd templates** — Ship copy-paste plist/shell snippets for “autonomy once + notify on failure” and “weekly digest”; link from PWA Tasks/Dashboard. **Done:** [AUTOMATION_SNIPPETS.md](AUTOMATION_SNIPPETS.md) + pointer from [OPERATIONS.md](OPERATIONS.md).
- [x] **P2.5 Execution context registry** — Extend [repo_path.rs](../src/repo_path.rs) / PWA “working repo” UX with **named profiles** via **`CHUMP_REPO_PROFILES=name=/abs/path`**; **`GET /api/repo/context`** exposes `profiles` / `active_profile`; **`POST /api/repo/working`** accepts `{ "profile": "…" }`; [context_assembly.rs](../src/context_assembly.rs) injects **tool repo root** line when multi-repo, profiles, or override applies.
- [ ] **P2.6 Remote runner (phase 1)** — Design + optional MVP: SSH or Tailscale-bound `run_cli` profile (allowlist, read-only by default). **RFC:** [rfcs/RFC-remote-runner-phase1.md](rfcs/RFC-remote-runner-phase1.md). MVP implementation remains gated on **trust review** and **production-ready governance UX** (P3); the RFC is safe to read and comment without shipping code.

**Depends on:** P1 (health/preflight).

**Unlocks:** true “daily” usage without staring at the UI.

---

## Pillar 3 — Governance as leverage

**Goal:** Increase **safe** tool breadth — approvals, policy, and audit are **first-class product**, not logs-only.

**Exit criteria**

- **Every surface** that can run tools supports the same approval contract as PWA ([TOOL_APPROVAL.md](TOOL_APPROVAL.md)).
- Operators can see **effective policy** without reading `.env` (stack-status + Settings done; extend per-session overrides if needed).
- **Audit triage:** filterable view or export of `tool_approval_audit` + tool health for a date range.

### Backlog

- [x] **P3.1 Surface parity audit** — Checklist: PWA, ChumpMenu/Tauri, Discord, `chump --rpc` / CLI agent — each: `tool_approval_request` → resolve path documented and tested. **Done:** table in [TOOL_APPROVAL.md](TOOL_APPROVAL.md) §Surface parity checklist.
- [x] **P3.2 Playwright / integration: approval unblocks** — Browser or Rust test: mock or stub provider emits approval → `POST /api/approve` → stream continues ([run-ui-e2e.sh](../scripts/run-ui-e2e.sh), optional `CHUMP_E2E_VERIFY_TOOL_POLICY`). **Done (baseline):** `approval_resolver` **tokio oneshot** unit tests (`resolve_sends_allow` / `deny`); Playwright **`POST /api/approve`** idempotent test + **`GET /api/jobs`**. Full **SSE stream continues after approve** still best behind a stub provider + `CHUMP_E2E_VERIFY_TOOL_POLICY` (future tighten).
- [x] **P3.3 Policy overrides (optional)** — Time-boxed **`CHUMP_TOOLS_ASK`** relaxations per **web session**: **`CHUMP_POLICY_OVERRIDE_API=1`**, **`POST /api/policy-override`** or **`policy_override`** on **`POST /api/chat`**; **`tool_policy.policy_override_api`** in stack-status; audit result **`policy_override_session`**; [`policy_override.rs`](../src/policy_override.rs) + [`task_executor.rs`](../src/task_executor.rs).
- [x] **P3.4 Audit UI or export** — PWA page or `GET` endpoint: recent approvals, denials, auto-approvals, linked task/session ids; CSV/JSON export for pilots. **Done:** `GET /api/tool-approval-audit` (+ `format=csv`); PWA **Settings → Governance snapshot**; full contract in [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md). (Dedicated filterable audit **page** still optional.)
- [x] **P3.5 Autopilot PWA controls** — After read-only status ([WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) `/api/autopilot/*`), add **Start/Stop** with confirmation and token gate; mirror [OPERATIONS.md](OPERATIONS.md) warnings. **Done:** Providers tab buttons → `POST /api/autopilot/start|stop` with `authHeaders()` + confirm copy.

**Depends on:** P1 baseline reliability.

**Unlocks:** P2.6 remote runner, higher tool budgets in production.

---

## Pillar 4 — Compounding context

**Goal:** Long-horizon **chief-of-staff** behavior — memory, COS, sessions, and tasks compose without contradiction.

**Exit criteria**

- Documented **precedence rules:** brain vs web session vs COS snapshot vs task contract (single page in [CHUMP_BRAIN.md](CHUMP_BRAIN.md) or new `docs/CONTEXT_PRECEDENCE.md`).
- **Long threads:** defined behavior for trim/summarize; tests or scripted soak; “continue” semantics stable enough for optional LLM e2e.
- **Task spine:** high-value work prefers durable tasks; chat references task state.

### Backlog

- [x] **P4.1 Context precedence doc** — One diagram + bullet order: what gets injected when `CHUMP_WEB_INJECT_COS`, heartbeat, and web chat all apply. **Done:** [CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md).
- [x] **P4.2 Session soak + limits** — Run or automate long thread against [web_sessions_db.rs](../src/web_sessions_db.rs); tune FTS/trim; document limits in [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) or ops doc. **Done:** limits documented under **Sessions** in [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md); automated soak still optional.
- [x] **P4.3 Continue / multi-turn e2e** — Optional [daily-driver-llm.spec.ts](../e2e/tests/daily-driver-llm.spec.ts) test behind env flag if flaky on small models. **Done:** spec **skipped unless `CHUMP_E2E_LLM=1`**; documented in [run-ui-e2e.sh](../scripts/run-ui-e2e.sh) header.
- [x] **P4.4 Task-first UX nudges** — PWA: “attach to task”, show active task in header/sidecar; slash commands already partial — align copy with [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md). **Done:** Tasks tab **task spine** hint (open tasks + `/task` / `#id` copy); align with chief-of-staff doc as you iterate.
- [x] **P4.5 Decision log surfacing** — When `CHUMP_WEB_INJECT_COS` or decision artifacts exist, link from PWA to latest `cos/decisions/` or summary chunk (read-only). **Done:** `GET /api/cos/decisions` + PWA Settings governance snapshot; files live under `cos/decisions/` per [COS_DECISION_LOG.md](COS_DECISION_LOG.md).

**Depends on:** P1; benefits from P2 async (task updates while away).

**Unlocks:** differentiated value vs generic chat.

---

## Pillar 5 — Product polish (universal *feel*)

**Goal:** One coherent product — onboarding, mobile, desktop, and docs tell the **same story**.

**Exit criteria**

- Guided **first-run** in under 15 minutes for green path (timeboxed external test recorded in [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md)).
- PWA **offline/queue** and attachments remain usable on slow networks for capture-first flows.
- Desktop (Tauri) **feature parity** with web for chat, approvals, stack status, working repo.

### Backlog

- [ ] **P5.1 Onboarding wizard (web + desktop)** — Single flow: inference → auth token → optional `CHUMP_TOOLS_ASK` explainer → first `/task`; track drop-off. **PWA slice (in progress):** dismissible banner + **step track** + Settings **Quick setup** — see [PWA_ONBOARDING_WIZARD.md](PWA_ONBOARDING_WIZARD.md) (`localStorage` `chump_pwa_onboarding_*`, `chump_onboarding_step`); **desktop:** `web/ootb-wizard.js` + [PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md). **Still open:** naive timed rows in [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) from third-party pilots.
- [x] **P5.2 Mobile PWA pass** — Approval cards, composer lock, session list, attachment limits; touch targets; document in [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md). **Done:** 44px touch targets (header, composer, approval buttons); sessions drawer → 80vw/320px on mobile; sidecar → full-width overlay; input area tighter gaps; textarea max-height capped; attachment chips touch-padded; command palette height constrained; scroll FAB repositioned; approval preview shortened; setup banner buttons stack vertically; settings modal edge padding.
- [x] **P5.3 Desktop parity checklist** — [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md): rows for PWA vs **Tauri** vs **ChumpMenu** (chat, approvals, sidecar, push, policy override, IPC); links [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) Phase 2–3 gaps.
- [x] **P5.4 Empty and error states** — Copy review: no raw JSON; always link to docs or “run preflight.” **Done:** SSE **`turn_error`** bubble uses structured copy + **`chump-preflight`** / **`OPERATIONS.md`** pointers (iterate on other surfaces as needed).
- [ ] **P5.5 Packaged distribution** — Align with open item in [ROADMAP.md](ROADMAP.md) (signing + notarized DMG) when ready for non-dev adopters. **Checklist:** [PACKAGING_AND_NOTARIZATION.md](PACKAGING_AND_NOTARIZATION.md).

**Depends on:** P1–P3 for meaningful polish (avoid pretty UI on flaky core).

**FE architecture gate (dashboard expansion):** [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md) — accepted with [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md).

---

## Execution order (recommended)

1. **P1** — Reliability boring  
2. **P2** — Reach / async (MVP notification)  
3. **P3** — Governance (parity + audit + autopilot controls)  
4. **P4** — Compounding context  
5. **P5** — Polish and packaging  

**Parallel safe:** P4.1 (precedence doc) early; P5.4 (copy) alongside P1.

---

## Related docs

| Doc | Why |
|-----|-----|
| [ROADMAP.md](ROADMAP.md) | Canonical checkboxes; mirror pillar completion here when done |
| [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) | Phases A–I overlap (especially A reliability, D PWA) |
| [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md) | Discord-optional wedge; keep aligned |
| [TOOL_APPROVAL.md](TOOL_APPROVAL.md) | Trust ladder and approval contract |
| [AUTONOMY_ROADMAP.md](AUTONOMY_ROADMAP.md) | Task/autonomy spine |
| [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) | Enterprise/defense WPs that touch governance |

---

## Changelog

| Date | Note |
|------|------|
| 2026-04-09 | **P5.1 (partial)** PWA onboarding bar + Settings quick setup + OOTB success token/`/task` hint; friction log keys documented. |
| 2026-04-09 | **P5.1+ / proof kit** [PWA_ONBOARDING_WIZARD.md](PWA_ONBOARDING_WIZARD.md), banner step track; **ADR-003** FE gate; [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md), [SOAK_72H_LOG.md](SOAK_72H_LOG.md), [CONSCIOUSNESS_UTILITY_PASS.md](CONSCIOUSNESS_UTILITY_PASS.md); pilot email [templates/pilot-invite-email.md](../templates/pilot-invite-email.md). |
| 2026-04-09 | **P5.2 (partial)** UI manual matrix mobile section; compact-width tap targets for approvals + chrome. |
| 2026-04-09 | **P2.6 RFC** [RFC-remote-runner-phase1.md](rfcs/RFC-remote-runner-phase1.md); **P5.5** [PACKAGING_AND_NOTARIZATION.md](PACKAGING_AND_NOTARIZATION.md); `scripts/chump-operational-sanity.sh`; Playwright mobile viewport block; friction log machine proxies. |
| 2026-04-13 | Initial program doc (pillars 1–5, backlog IDs P1.x–P5.x). |
| 2026-04-13 | P1.1–P1.4 shipped: `scripts/chump-preflight.sh`, `chump --preflight`, CI step, degraded UX matrix, EXTERNAL_GOLDEN_PATH daily-driver profile. |
| 2026-04-13 | P2.3, P3.1, P3.4, P4.2, P4.5: automation ingress doc, approval parity table, `GET /api/tool-approval-audit` (+ CSV), `GET /api/cos/decisions`, session limits in WEB_API_REFERENCE, PWA Settings governance snapshot, Dashboard link to AUTOMATION_SNIPPETS. |
| 2026-04-13 | P2.2 job log + `GET /api/jobs` + pilot-summary `recent_async_jobs`; autonomy inserts rows; P3.2 baseline tests; P4.3 `CHUMP_E2E_LLM`; P4.4 task spine hint; P5.4 turn_error copy; Dashboard recent jobs line. |
| 2026-04-13 | **P2.1** Web Push send: `web_push_send`, `CHUMP_VAPID_PRIVATE_KEY_FILE`, `CHUMP_WEB_PUSH_AUTONOMY`, `web/sw.js` push handler; OPERATIONS + WEB_API docs. |
| 2026-04-13 | **P3.3** Session policy overrides: `policy_override.rs`, `/api/policy-override`, chat `policy_override`, `policy_override_session` audit; TOOL_APPROVAL + WEB_API. |
| 2026-04-13 | **P5.3** [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md) — PWA vs Tauri vs ChumpMenu matrix + Tauri plan cross-links. |
| 2026-04-14 | **P5.2** Mobile PWA pass: sessions drawer 80vw/320px, sidecar full-width overlay, input area tighter, textarea capped, attachment chips touch-padded, command palette constrained, scroll FAB repositioned, approval preview shorter, setup banner buttons stack, settings modal edge padding. |
| 2026-04-14 | **Performance** `compact_tools_for_light()` in `agent_loop.rs`: 4096→776 prompt tokens, 26s→5.7s on Ollama qwen2.5:7b. Documented in [PERFORMANCE.md](PERFORMANCE.md) §8. |
