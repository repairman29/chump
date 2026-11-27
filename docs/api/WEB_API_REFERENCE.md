---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# HTTP & SSE Web API Reference

`chump --web` starts an `axum` HTTP and Server-Sent Events (SSE) server (`src/web_server.rs`, default `127.0.0.1:3000`, configurable via `--port` or `[web] port` in `~/.chump/config.toml`). All programmatic routes live under `/api/`.

---

## 1. Authentication & Payload Limits

- **Bearer Authentication (`CHUMP_WEB_TOKEN`):** When `CHUMP_WEB_TOKEN` is set, send `Authorization: Bearer <token>` on all mutating and workspace-reading endpoints (`/api/chat`, `/api/approve`, `/api/tasks`, `/api/sessions`, `/api/gap/claim/*`, `/api/gap/work/*`, `/api/autopilot/*`, `/api/ingest`, `/api/upload`). Lightweight liveness (`GET /api/health`) remains unauthenticated for local health probes.
- **Upload & Capture Caps:** `POST /api/upload` enforces an `11 MiB` multipart ceiling; `POST /api/ingest` caps individual text/URL fields at `512 KiB` (returning HTTP `413` if exceeded).

---

## 2. Health, Stack & Cascade Telemetry

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/health` | Fast liveness check returning `status`, `binary_version`, `build_sha`, and `version_match`. |
| `GET` | `/api/stack-status` | Full runtime readiness: `inference` (`primary_backend`, `models_reachable`, `error`), `air_gap_mode`, `tool_policy`, `llm_last_completion`, `llm_completion_totals`, and `github_rate_limit`. |
| `GET` | `/api/cascade-status` | Per-slot status across `[[providers]]`: priority, `circuit_state`, remaining RPD/RPM, and latency stats. |
| `GET` | `/api/fleet/health` | Aggregate 4-pillar grades (`effective`, `credible`, `resilient`, `zero_waste`), 24h ship KPIs, SLO status, and GraphQL budget (60s cache). |
| `GET` | `/api/roadmap` | Server-side `docs/ROADMAP.md` milestone parser enriched with live `.chump/state.db` gap completion ratios (60s cache). |
| `GET` | `/api/analytics` | Session, message, tool-call, and latency summary from `web_sessions_db`. |

---

## 3. Task Queue (Gap Registry) Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/gap-queue` | Queryable task list supporting `?status=open,claimed`, `?domain=INFRA`, and `?priority=P1` filters. Returns `gaps[]`, `count`, `total`, and `claimable_count`. |
| `POST` | `/api/gap/claim/{id}` | Atomically acquires a lease and creates an isolated git worktree for `{id}`. |
| `POST` | `/api/gap/work/{id}` | Spawns an asynchronous background worker run for `{id}`, returning `{ status: "accepted", request_id }`. |
| `GET` | `/api/gap/{id}/status` | Current workflow phase (`preflight`, `claim`, `execute-gap`, `ship`), `progress_pct`, and error state. |
| `GET` | `/api/gap/{id}/stream` | Live SSE stream of `gap_workflow_phase` transitions for `{id}`. |

---

## 4. Streaming Chat & Tool Approval

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/chat` | Starts a streaming `text/event-stream` agent turn. JSON body: `{ "message": "...", "session_id": "..." }`. Returns HTTP `402` if a configured session cost ceiling is exceeded. |
| `POST` | `/api/approve` | Resolves a pending `tool_approval_request` (`{ "request_id": "<uuid>", "allowed": true }`). Idempotent on retry. |
| `POST` | `/api/policy-override` | Time-boxed session tool-approval relaxation (`60–604800s`) when the policy-relaxation API (`CHUMP_POLICY_OVERRIDE_API`) is enabled. |
| `GET` | `/api/tool-approval-audit` | Recent `tool_approval_audit` entries (`?limit=40` or `?format=csv`). |

### SSE Event Types (`POST /api/chat`)

| `event:` Name | Payload Summary |
|---------------|-----------------|
| `web_session_ready` | Assigned or resumed `session_id` |
| `turn_start` | Turn started (`request_id`, `timestamp`) |
| `thinking` | Reasoning progress heartbeat or monologue delta |
| `model_call_start` | Provider round index |
| `text_delta` | Incremental assistant response chunk |
| `text_complete` | Complete assistant text for the round |
| `tool_call_start` | Tool invocation (`tool_name`, `tool_input`, `call_id`) |
| `tool_call_result` | Tool execution outcome (`result`, `duration_ms`, `success`) |
| `tool_approval_request` | Pause awaiting `POST /api/approve` (`request_id`, `risk_level`, `reason`) |
| `turn_complete` | Final turn summary (`full_text`, token/tool counts) |
| `turn_error` | Terminal error with actionable remediation hint |

---

## 5. Sessions, Tasks, Memory & Autopilot

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET / POST` | `/api/sessions` | List (`limit <= 100`) or create chat sessions |
| `GET / PUT / DELETE` | `/api/sessions/{id}` (`.../messages`) | Fetch paginated messages (`limit <= 500`), rename, or delete a session |
| `GET / POST / PUT / DELETE` | `/api/tasks` (`/api/tasks/{id}`) | Manage lightweight DAG tasks (`depends_on` cycle-checked in SQLite) |
| `GET / POST` | `/api/autopilot/status`, `/start`, `/stop` | Query, start, or stop background ship supervision |
| `GET / POST` | `/api/repo/context`, `/api/repo/working` | Inspect or switch active working repository (`CHUMP_MULTI_REPO_ENABLED=1`) |
| `POST / GET` | `/api/upload`, `/api/files/{file_id}` | Upload and retrieve session attachments |
| `GET / POST` | `/api/push/vapid-public-key`, `/subscribe`, `/unsubscribe` | Web Push subscription management |

---

## 6. Static UI Routes

- `/v2/` — Sovereign Operator Cockpit
- `/site/` — Product Suite, Fleet Simulator (`/site/tools/fleet-simulator/`), and Config Doctor (`/site/tools/config-doctor/`)
- `/docs/` — Redirects to `/site/docs/` (60-second quickstart and command sheet)

---

## Related Guides

- [Web Cockpit (`/v2/`)](../PWA_USER_GUIDE.md)
- [Daemon & Service Operations](../operations/OPERATIONS.md)
- [Hardware & RAM Profiles](../operations/INFERENCE_PROFILES.md)
