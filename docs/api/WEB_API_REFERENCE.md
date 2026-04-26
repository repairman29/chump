---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Web API reference

The web server is started with `chump --web` (default port 3000; override with `--port` or `CHUMP_WEB_PORT`). All API routes are under `/api/`. Implemented in `src/web_server.rs`.

## Health and status

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check; returns JSON (e.g. status, version). |
| GET | `/api/stack-status` | Desktop / ops: `OPENAI_API_BASE`, `OPENAI_MODEL`, cascade flag, **`air_gap_mode`**, **`inference`** (see below), **`tool_policy`** (effective **`CHUMP_TOOLS_ASK`**, auto-approve flags for PWA Settings), **`llm_last_completion`** / **`llm_completion_totals`** (which backend last answered; see below), and **`cognitive_control`** (recommended tool/delegate caps, belief-budget flag, task uncertainty, context-exploration fraction, effective tool timeout). |
| GET | `/api/cascade-status` | Cascade provider status (slots, remaining RPD, etc.). |
| GET | `/api/pilot-summary` | **Pilot / N4 aggregate:** task counts by status, episode total, tool-call ring stats, last speculative batch JSON, plus **`recent_async_jobs`** (last 12 rows from the async job log — same data as `GET /api/jobs`). Requires `Authorization: Bearer …` when `CHUMP_WEB_TOKEN` is set (same as mutating task routes). See [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) and `./scripts/export-pilot-summary.sh`. |
| GET | `/api/jobs` | **Async job log (P2.2):** recent rows from **`chump_async_jobs`** (`chump_memory.db`). Query **`limit`** (1–200, default 40). Each job: `id`, `job_type` (e.g. `autonomy_once`), `status`, optional `task_id` / `session_id`, `detail`, `last_error`, timestamps. Bearer required when `CHUMP_WEB_TOKEN` is set. |
| GET | `/api/analytics` | **Session / turn telemetry:** JSON summary from `web_sessions_db::analytics_summary()` (sessions, messages, tool calls, latency aggregates, feedback counts). Bearer when `CHUMP_WEB_TOKEN` is set. |
| POST | `/api/messages/{id}/feedback` | **Per-message feedback:** JSON body `{"feedback": 1}` (up) or `{"feedback": -1}` (down). Updates `chump_web_messages.feedback` for the UUID `id`. Bearer when token is set. |

### `GET /api/stack-status` — `inference` object

- **`primary_backend`:** `"openai_compatible"` (default) or `"mistralrs"` when **`CHUMP_INFERENCE_BACKEND=mistralrs`** (case-insensitive) **and** **`CHUMP_MISTRALRS_MODEL`** is non-empty. The mistral.rs predicate is **env-only**; it does not verify that the binary was built with `--features mistralrs-infer`.
- **`openai_compatible`:** Top-level `inference` is the OpenAI HTTP probe: `configured`, `models_reachable`, `probe`, `models_url`, `http_status`, `error` — same semantics as before, plus `primary_backend: "openai_compatible"`. For **local** bases (`127.0.0.1` / `localhost`), Chump runs a short `GET …/models` (timeout **`CHUMP_STACK_PROBE_TIMEOUT_SECS`**, default 8).
- **`mistralrs`:** Top-level `inference` reports **`configured: true`**, **`models_reachable: true`**, **`probe: "mistralrs_in_process"`**, and **`mistralrs_model`**. Optional HTTP status is under **`openai_http_sidecar`** (same shape as the OpenAI probe, without `primary_backend`). A failing sidecar must **not** be interpreted as “chat has no model” when primary is in-process mistral.rs.

### `GET /api/stack-status` — `cognitive_control` object

Live snapshot of precision / neuromod hooks (WP-6.x): **`recommended_max_tool_calls`**, **`recommended_max_delegate_parallel`**, **`belief_tool_budget`** (from **`CHUMP_BELIEF_TOOL_BUDGET`**), **`task_uncertainty`** (epistemic, `belief_state`), **`context_exploration_fraction`**, **`effective_tool_timeout_secs`** (default base 30s, scaled by serotonin heuristic). The same fields are mirrored under **`consciousness_dashboard.precision`** on **`GET /health`** when **`CHUMP_HEALTH_PORT`** is set (separate from this minimal **`GET /api/health`**).

### `GET /api/stack-status` — LLM backend metrics

- **`llm_last_completion`:** `null` until a completion succeeds in this process, then an object: **`kind`** (`mistralrs` \| `cascade` \| `openai_http` \| `openai_api`), **`label`** (model id, cascade slot name, or HTTP host:port), **`stream_text_deltas`** (bool; mistral streaming path only), **`at_unix_ms`**.
- **`llm_completion_totals`:** Object mapping **`"kind::label"`** → integer count since process start. Cascade inner HTTP attempts do not increment `openai_http` (only the winning slot’s `cascade` entry). See [METRICS.md](METRICS.md) §1c.

The same **`llm_last_completion`** and **`llm_completion_totals`** fields are included on **`GET /health`** (health port) for operators who poll that endpoint.

## Dashboard

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/dashboard` | Ship heartbeat status and observability: JSON with `ship_running`, `ship_summary`, `ship_log_tail`, `chassis_log`, `current_step` (last line of chassis log), `last_episodes` (recent episode summaries). Used by the PWA Dashboard tab for "what we're doing" and recent activity. Optional `Authorization: Bearer <token>` when `CHUMP_WEB_TOKEN` is set. |

**Empty or sparse dashboard (external / minimal setup):** If you have not configured **`chump-brain/`**, ship heartbeat scripts, or episode logging, fields such as `ship_running`, `chassis_log`, `current_step`, or `last_episodes` may be empty or placeholders. That is expected for a **web-only golden path** ([docs/process/EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md)). Populate the brain ([CHUMP_BRAIN.md](CHUMP_BRAIN.md)), run ship/autonomy heartbeats ([OPERATIONS.md](OPERATIONS.md)), and use the agent so episodes accumulate—then the Dashboard reflects real activity.

## Chat and approval

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/chat` | Send message; streaming SSE. Body: **`message`**, optional **`session_id`**, **`attachments`**, **`bot`**. Optional **`policy_override`**: `{ "relax_tools": "run_cli,write_file", "ttl_secs": 3600 }` — when **`CHUMP_POLICY_OVERRIDE_API=1`**, registers a time-boxed relax of **CHUMP_TOOLS_ASK** for that session and applies it to **this** agent run (see [TOOL_APPROVAL.md](TOOL_APPROVAL.md) §Policy overrides). |
| POST | `/api/approve` | Resolve a tool approval request (allow/deny); JSON body `{ "request_id": "<uuid>", "allowed": true \| false }`. Idempotent if the id is unknown (already resolved). Same bearer auth as other routes when `CHUMP_WEB_TOKEN` is set. |
| POST | `/api/policy-override` | Register the same relax **without** sending a chat message: `{ "session_id", "relax_tools", "ttl_secs" }`. Gated on **`CHUMP_POLICY_OVERRIDE_API=1`**. **`ttl_secs`** clamped **60–604800** (7 days). Returns `{ "ok": true }` or `{ "ok": false, "error": "…" }` when the API is disabled. |

## Autopilot and working repo (PWA Providers tab)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/autopilot/status` | Autopilot / ship state: `desired_enabled`, `actual_state`, `ship_running`, `pid`, `last_error`, etc. |
| POST | `/api/autopilot/start` | Same as mutating routes: Bearer when `CHUMP_WEB_TOKEN` set. PWA **Providers** tab calls this after confirm. |
| POST | `/api/autopilot/stop` | Stops desired autopilot and managed ship; PWA **Providers** after confirm. |
| GET | `/api/repo/context` | Effective git repo root for tools: `multi_repo_enabled`, `effective_root`, `has_working_override`, `chump_repo_env`, **`profiles`** (from **`CHUMP_REPO_PROFILES`**, array of `{name, path}`), **`active_profile`** (when override was set via profile). |
| POST | `/api/repo/working` | Set or clear process working repo when **`CHUMP_MULTI_REPO_ENABLED=1`** (and **`CHUMP_REPO`** or **`CHUMP_HOME`**): JSON `{ "path": "/abs/repo" }`, **`{ "profile": "name" }`** (must match **`CHUMP_REPO_PROFILES`**), or `{ "clear": true }`. Do not send both `path` and `profile`. Requires `.git` at repo root. |

### SSE event names (`POST /api/chat`)

The response is **text/event-stream**. Each event has an SSE `event:` name and a JSON `data:` payload. Names are defined by [`AgentEvent::event_type`](../src/stream_events.rs) (same string as the SSE `event` field). Payloads are the JSON serialization of the corresponding `AgentEvent` variant (`type` discriminator + fields, `snake_case`).

| SSE `event` | Meaning (short) |
|-------------|-----------------|
| `turn_start` | New turn; `request_id`, `timestamp`. |
| `thinking` | Reasoning heartbeat; `elapsed_ms`. |
| `text_delta` | Incremental assistant text (if used). |
| `text_complete` | Full assistant text snapshot. |
| `tool_call_start` | Tool invoked; `tool_name`, `tool_input`, `call_id`. |
| `tool_call_result` | Tool finished; `result`, `duration_ms`, `success`, `call_id`. |
| `model_call_start` | Provider round; `round`. |
| `turn_complete` | Turn done; `full_text`, counts, optional `thinking_monologue`. |
| `turn_error` | Fatal turn error message. |
| `tool_approval_request` | Human approval needed; `request_id`, `risk_level`, `reason`, `expires_at_secs`, tool fields. |
| `web_session_ready` | Server assigned `session_id` for this chat. |

**In-process mistral + incremental text:** When **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1`** (with **`mistralrs-infer`** / **`mistralrs-metal`** and mistral primary env), the server may emit many **`text_delta`** events and **omit** **`text_complete`**; clients should still apply **`turn_complete.full_text`** as the canonical final string. See [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b and [rfcs/RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md).

**Structured assistant JSON (tool-free turns):** Optional **`CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA`** (path to JSON Schema file) constrains in-process mistral output only when the LLM request has **no tools**; see [ADR-002](ADR-002-mistralrs-structured-output-spike.md).

### Tauri desktop (`chump-desktop`, HTTP sidecar)

When the UI runs inside **Tauri** ([`docs/strategy/TAURI_FRONTEND_PLAN.md`](TAURI_FRONTEND_PLAN.md) Option B), the WebView still calls the same HTTP routes via an API root prefix (`__CHUMP_FETCH` in [`web/index.html`](../web/index.html)). Additionally, **`#[tauri::command]`** proxies exist for tooling and tests:

| Command | Role |
|---------|------|
| `get_desktop_api_base` | Returns `CHUMP_DESKTOP_API_BASE` or default `http://127.0.0.1:3000`. |
| `health_snapshot` | `GET {base}/api/health` → JSON body string. |
| `resolve_tool_approval` | `POST {base}/api/approve` with JSON `{ request_id, allowed }`; optional `token` → `Authorization: Bearer`. |
| `submit_chat` | `POST {base}/api/chat` with raw `bodyJson`; returns **entire** SSE response as one string (harness only; UI should stream via `fetch`). |

Optional JS: [`web/desktop-bridge.js`](../web/desktop-bridge.js) (`createChumpDesktopApi()`).

### Tauri native `emit` (Phase 2 — contract only)

When the agent eventually runs **in-process** with Tauri (Option A) or a bridge forwards events, native channels SHOULD reuse the **same** names and JSON shapes as the SSE `event` + `data` rows above (e.g. listen channel `chump/tool_call_start` with payload = current SSE `data` JSON). No duplicate schema. Wiring is tracked in [`docs/strategy/TAURI_FRONTEND_PLAN.md`](TAURI_FRONTEND_PLAN.md) Phase 2.

## Sessions

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/sessions` | List sessions. |
| POST | `/api/sessions` | Create session. |
| GET | `/api/sessions/{id}/messages` | Get messages for a session. |
| PUT | `/api/sessions/{id}` | Rename or update session. |
| DELETE | `/api/sessions/{id}` | Delete session. |

**Limits (`web_sessions_db.rs`, universal power P4.2):** list endpoint clamps **`limit` ≤ 100**; messages endpoint clamps **`limit` ≤ 500** per page (use offset for deep history). First user message seeds session title (**~60 chars**). FTS-backed context snippets use **up to 16** whitespace-separated query tokens (each escaped for FTS5) and return **1–24** excerpts.

## Governance and audit

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/tool-approval-audit` | Recent **`tool_approval_audit`** events parsed from **`logs/chump.log` tail** (last ~768 KiB of the file). Query: **`limit`** (1–500, default 40); **`format=csv`** for CSV (`text/csv`). Supports structured JSON lines and legacy pipe format ([TOOL_APPROVAL.md](TOOL_APPROVAL.md)). Requires bearer when `CHUMP_WEB_TOKEN` is set. **Note:** log path follows the **web process cwd** + `logs/chump.log` (same as `chump_log` append path). |
| GET | `/api/cos/decisions` | Newest **`cos/decisions/*.md`** under the resolved brain root (`CHUMP_BRAIN_PATH` / `chump-brain`), sorted by mtime. Query: **`limit`** (1–50, default 8). Each row: `filename`, `relative_path`, `modified_unix_ms`, `preview` (~480 chars). Read-only. |

## Upload and files

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/upload` | Upload file (multipart); body limit 11 MiB. |
| GET | `/api/files/{file_id}` | Serve uploaded file by ID. |

## Tasks

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/tasks` | List tasks. |
| POST | `/api/tasks` | Create task (optional **`depends_on`** array of task IDs for a dependency DAG; cycles rejected in DB). |
| PUT | `/api/tasks/{id}` | Update task. |
| DELETE | `/api/tasks/{id}` | Delete task. |

**Task DAG (tool surface):** the **`task`** tool supports **`list_unblocked`**, **`add_dependency`**, **`remove_dependency`** alongside create/list/update/complete — see `src/task_tool.rs` / `src/task_db.rs`.

## Briefing and ingest

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/briefing` | JSON: `date`, `sections[]` with **Tasks** (open by assignee), **Recent episodes**, **Watchlists** (counts), **Watch alerts** (flagged lines). Used by PWA and **`scripts/morning-briefing-dm.sh`**. |
| POST | `/api/ingest` | JSON body: `text` and/or `url` (at least one non-empty). Optional `source` (e.g. `pwa`, `ios_shortcut`) is stored as an HTML comment in the capture file. Max raw text/url payload **512 KiB** per field; larger requests → **413**. Request body limit ~576 KiB. Writes under `CHUMP_BRAIN_PATH/capture/`. |
| POST | `/api/ingest/upload` | Multipart file field `file` (or `text`). Stored in `capture/`; each file **≤ 512 KiB** (multipart layer still allows up to 11 MiB before handler rejects). |

## Research

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/research` | List research items (`research/*.md` under brain). |
| POST | `/api/research` | Body: `{ "topic": "...", "content": "..." }`. Creates `research/<slug>.md` with status **queued**. Multi-pass agent synthesis is driven by heartbeat **`RESEARCH_BRIEF_PROMPT`** (writes `research/latest.md`) and research rounds in `scripts/heartbeat-self-improve.sh` / Mabel. |
| GET | `/api/research/{id}` | Get research item by ID. |

## Watch

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/watch` | List watch lists with item counts (`watch/*.md` under brain). |
| POST | `/api/watch` | Add watch item. |
| GET | `/api/watch/alerts` | JSON array of `{ "list", "line" }` for **flagged** bullets: lines starting with `-` and containing `urgent`, `asap`, `deadline`, `[!]`, `!!!`, or `alert:` (case-insensitive where noted). Same logic as **Watch alerts** in `/api/briefing`. |
| DELETE | `/api/watch/{list}/{item_id}` | Remove watch item. |

## Projects

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/projects` | List projects. |
| POST | `/api/projects` | Create project. |
| POST | `/api/projects/{id}/activate` | Activate project. |

## Autopilot (ship product heartbeat)

Requires `Authorization: Bearer <token>` when `CHUMP_WEB_TOKEN` is set (same as other gated routes).

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/autopilot/status` | JSON: `desired_enabled`, `actual_state`, `last_error`, `ship_summary`, `consecutive_start_failures`, `auto_retry_paused_until_secs`, etc. |
| POST | `/api/autopilot/start` | Sets desired on, clears auto-retry backoff, runs preflight, starts managed ship via `ensure-ship-heartbeat.sh`. Body empty. Response `{ "ok": true, "state": { ... } }` or `{ "ok": false, "error": "..." }`. |
| POST | `/api/autopilot/stop` | Stops desired autopilot; best-effort TERM on lock PID, then `pkill` fallback. |

When the web process is running with `--web`, it **reconciles on boot** and every **3 minutes**: if `desired_enabled` is true and the ship process is down, and auto-retry is not paused, it attempts start again (with backoff after repeated failures).

**ChumpMenu** reads `CHUMP_WEB_HOST` (default `127.0.0.1`), `CHUMP_WEB_PORT` (default `3000`), and `CHUMP_WEB_TOKEN` from the repo `.env` so it hits the same URL as `chump --web`.

Remote control (e.g. from another host on Tailscale): see [OPERATIONS.md](OPERATIONS.md) and `scripts/autopilot-remote.sh`.

## Push (Web Push)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/push/vapid-public-key` | Get VAPID **public** key for `pushManager.subscribe` (from **`CHUMP_VAPID_PUBLIC_KEY`** or placeholder). |
| POST | `/api/push/subscribe` | Subscribe: JSON `{ "endpoint", "keys": { "p256dh", "auth" } }` → stored in **`chump_push_subscriptions`**. |
| POST | `/api/push/unsubscribe` | Unsubscribe: JSON `{ "endpoint" }`. |

**Server send (P2.1):** When **`CHUMP_VAPID_PRIVATE_KEY_FILE`** points to a PEM EC private key (same pair as the public key the PWA used to subscribe) and **`CHUMP_WEB_PUSH_AUTONOMY=1`**, each **`--autonomy-once`** outcome **`done`**, **`blocked`**, or **error** triggers a **fire-and-forget** broadcast to all subscribers with JSON body `{ "title", "body" }`. The service worker (`web/sw.js`) shows **`showNotification`**. Optional **`CHUMP_VAPID_SUBJECT`** (e.g. `mailto:you@example.com`) overrides the JWT `sub` claim. Stale endpoints (**404** / **410** class from the push service) are removed from the DB. See [OPERATIONS.md](OPERATIONS.md) for key generation.

## Automation ingress (shortcuts, cron, webhooks)

**P2.3 — consistent contracts for external `POST`/`GET` callers:**

- **Bearer auth:** When `CHUMP_WEB_TOKEN` is set, send `Authorization: Bearer <token>` on every route that mutates state or returns private workspace data (tasks, sessions, ingest, upload, approve, autopilot control, audit endpoints above, briefing, dashboard, pilot-summary, repo working override, etc.). Health/stack-status remain open unless you add a reverse proxy.
- **Payload caps:** **`POST /api/upload`** and **`POST /api/ingest/upload`**: multipart layer **11 MiB**; handler rejects captures **> 512 KiB** per file. **`POST /api/ingest`** and **`POST /api/shortcut/capture`**: **~576 KiB** request body with **512 KiB** max per `text` / `url` field (→ **413** when exceeded). **`POST /api/chat`**: large prompts are allowed for SSE turns; prefer sessioning over megabyte single messages.
- **Idempotency:** **`POST /api/approve`** is safe to retry (unknown `request_id` → success). Task/session creates do **not** accept an idempotency key; use stable `session_id` in chat bodies when you need continuity across retries.

## Shortcut (iOS Shortcuts / external)

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/shortcut/task` | Create task from shortcut. |
| POST | `/api/shortcut/capture` | Body: `{ "text": "..." }`, optional `source` (default label `ios_shortcut` in capture file). Same **512 KiB** cap as `/api/ingest`. |
| GET | `/api/shortcut/status` | Shortcut status. |
| POST | `/api/shortcut/command` | Execute shortcut command. |

## Static

The server serves the PWA from the static directory (default `CHUMP_WEB_STATIC_DIR` or repo `web/`). All non-API routes fall through to static files (e.g. `index.html`, `manifest.json`, `sw.js`).
