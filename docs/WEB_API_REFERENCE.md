# Web API reference

The web server is started with `rust-agent --web` (default port 3000; override with `--port` or `CHUMP_WEB_PORT`). All API routes are under `/api/`. Implemented in `src/web_server.rs`.

## Health and status

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check; returns JSON (e.g. status, version). |
| GET | `/api/stack-status` | Desktop / ops: `OPENAI_API_BASE`, `OPENAI_MODEL`, cascade flag, **`air_gap_mode`**, **`inference`** (see below), **`llm_last_completion`** / **`llm_completion_totals`** (which backend last answered; see below), and **`cognitive_control`** (recommended tool/delegate caps, belief-budget flag, task uncertainty, context-exploration fraction, effective tool timeout). |
| GET | `/api/cascade-status` | Cascade provider status (slots, remaining RPD, etc.). |
| GET | `/api/pilot-summary` | **Pilot / N4 aggregate:** task counts by status, episode total, tool-call ring stats, last speculative batch JSON. Requires `Authorization: Bearer …` when `CHUMP_WEB_TOKEN` is set (same as mutating task routes). See [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) and `./scripts/export-pilot-summary.sh`. |

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

**Empty or sparse dashboard (external / minimal setup):** If you have not configured **`chump-brain/`**, ship heartbeat scripts, or episode logging, fields such as `ship_running`, `chassis_log`, `current_step`, or `last_episodes` may be empty or placeholders. That is expected for a **web-only golden path** ([docs/EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md)). Populate the brain ([CHUMP_BRAIN.md](CHUMP_BRAIN.md)), run ship/autonomy heartbeats ([OPERATIONS.md](OPERATIONS.md)), and use the agent so episodes accumulate—then the Dashboard reflects real activity.

## Chat and approval

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/chat` | Send message; streaming or final response (body: session_id, message, etc.). |
| POST | `/api/approve` | Resolve a tool approval request (allow/deny); body includes request_id and resolution. |

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

When the UI runs inside **Tauri** ([`docs/TAURI_FRONTEND_PLAN.md`](TAURI_FRONTEND_PLAN.md) Option B), the WebView still calls the same HTTP routes via an API root prefix (`__CHUMP_FETCH` in [`web/index.html`](../web/index.html)). Additionally, **`#[tauri::command]`** proxies exist for tooling and tests:

| Command | Role |
|---------|------|
| `get_desktop_api_base` | Returns `CHUMP_DESKTOP_API_BASE` or default `http://127.0.0.1:3000`. |
| `health_snapshot` | `GET {base}/api/health` → JSON body string. |
| `resolve_tool_approval` | `POST {base}/api/approve` with JSON `{ request_id, allowed }`; optional `token` → `Authorization: Bearer`. |
| `submit_chat` | `POST {base}/api/chat` with raw `bodyJson`; returns **entire** SSE response as one string (harness only; UI should stream via `fetch`). |

Optional JS: [`web/desktop-bridge.js`](../web/desktop-bridge.js) (`createChumpDesktopApi()`).

### Tauri native `emit` (Phase 2 — contract only)

When the agent eventually runs **in-process** with Tauri (Option A) or a bridge forwards events, native channels SHOULD reuse the **same** names and JSON shapes as the SSE `event` + `data` rows above (e.g. listen channel `chump/tool_call_start` with payload = current SSE `data` JSON). No duplicate schema. Wiring is tracked in [`docs/TAURI_FRONTEND_PLAN.md`](TAURI_FRONTEND_PLAN.md) Phase 2.

## Sessions

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/sessions` | List sessions. |
| POST | `/api/sessions` | Create session. |
| GET | `/api/sessions/{id}/messages` | Get messages for a session. |
| PUT | `/api/sessions/{id}` | Rename or update session. |
| DELETE | `/api/sessions/{id}` | Delete session. |

## Upload and files

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/upload` | Upload file (multipart); body limit 11 MiB. |
| GET | `/api/files/{file_id}` | Serve uploaded file by ID. |

## Tasks

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/tasks` | List tasks. |
| POST | `/api/tasks` | Create task. |
| PUT | `/api/tasks/{id}` | Update task. |
| DELETE | `/api/tasks/{id}` | Delete task. |

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

**ChumpMenu** reads `CHUMP_WEB_HOST` (default `127.0.0.1`), `CHUMP_WEB_PORT` (default `3000`), and `CHUMP_WEB_TOKEN` from the repo `.env` so it hits the same URL as `rust-agent --web`.

Remote control (e.g. from another host on Tailscale): see [OPERATIONS.md](OPERATIONS.md) and `scripts/autopilot-remote.sh`.

## Push (Web Push)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/push/vapid-public-key` | Get VAPID public key for subscription. |
| POST | `/api/push/subscribe` | Subscribe to push. |
| POST | `/api/push/unsubscribe` | Unsubscribe. |

## Shortcut (iOS Shortcuts / external)

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/shortcut/task` | Create task from shortcut. |
| POST | `/api/shortcut/capture` | Body: `{ "text": "..." }`, optional `source` (default label `ios_shortcut` in capture file). Same **512 KiB** cap as `/api/ingest`. |
| GET | `/api/shortcut/status` | Shortcut status. |
| POST | `/api/shortcut/command` | Execute shortcut command. |

## Static

The server serves the PWA from the static directory (default `CHUMP_WEB_STATIC_DIR` or repo `web/`). All non-API routes fall through to static files (e.g. `index.html`, `manifest.json`, `sw.js`).
