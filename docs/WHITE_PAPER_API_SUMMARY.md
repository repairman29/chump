# Web API summary (for PDF)

**Purpose:** Route-level index of the HTTP API mounted by `chump --web`. For request/response schemas, auth, and SSE events, see the full **`WEB_API_REFERENCE.md`** in the repository.

**Router:** `build_api_router()` in `src/web_server.rs` (merged with static `web/` fallback in `start_web_server`).

| Method(s) | Path | Role (short) |
|-----------|------|----------------|
| GET | `/favicon.ico` | Favicon |
| GET | `/api/health` | Liveness / diagnostics |
| GET | `/api/stack-status` | Stack status |
| GET | `/api/cascade-status` | Provider cascade status |
| POST | `/api/chat` | Chat completion |
| POST | `/api/approve` | Tool approval |
| GET, POST | `/api/sessions` | List / create sessions |
| GET | `/api/sessions/{id}/messages` | Session messages |
| PUT, DELETE | `/api/sessions/{id}` | Rename / delete session |
| POST | `/api/upload` | File upload (body limit ~11 MiB) |
| GET | `/api/files/{file_id}` | Serve uploaded file |
| GET, POST | `/api/tasks` | List / create tasks |
| PUT, DELETE | `/api/tasks/{id}` | Update / delete task |
| GET | `/api/pilot-summary` | Pilot summary |
| GET | `/api/briefing` | Briefing |
| GET | `/api/dashboard` | Dashboard payload |
| GET | `/api/autopilot/status` | Autopilot status |
| POST | `/api/autopilot/start` | Start autopilot |
| POST | `/api/autopilot/stop` | Stop autopilot |
| POST | `/api/ingest` | JSON ingest (size-capped) |
| POST | `/api/ingest/upload` | Ingest via upload |
| GET, POST | `/api/research` | List / create research items |
| GET | `/api/research/{id}` | Get research item |
| GET, POST | `/api/watch` | Watch lists |
| GET | `/api/watch/alerts` | Watch alerts |
| DELETE | `/api/watch/{list}/{item_id}` | Remove watch item |
| GET, POST | `/api/projects` | List / create projects |
| POST | `/api/projects/{id}/activate` | Activate project |
| GET | `/api/push/vapid-public-key` | Web push VAPID public key |
| POST | `/api/push/subscribe` | Push subscribe |
| POST | `/api/push/unsubscribe` | Push unsubscribe |
| POST | `/api/shortcut/task` | Shortcut task |
| POST | `/api/shortcut/capture` | Shortcut capture (size-capped) |
| GET | `/api/shortcut/status` | Shortcut status |
| POST | `/api/shortcut/command` | Shortcut command |

**Note:** Agent/tool streaming may use **SSE** on routes documented in `WEB_API_REFERENCE.md`; this table is intentionally minimal for print.
