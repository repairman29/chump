# Web API reference

The web server is started with `rust-agent --web` (default port 3000; override with `--port` or `CHUMP_WEB_PORT`). All API routes are under `/api/`. Implemented in `src/web_server.rs`.

## Health and status

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check; returns JSON (e.g. status, version). |
| GET | `/api/cascade-status` | Cascade provider status (slots, remaining RPD, etc.). |

## Dashboard

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/dashboard` | Ship heartbeat status and observability: JSON with `ship_running`, `ship_summary`, `ship_log_tail`, `chassis_log`, `current_step` (last line of chassis log), `last_episodes` (recent episode summaries). Used by the PWA Dashboard tab for "what we're doing" and recent activity. Optional `Authorization: Bearer <token>` when `CHUMP_WEB_TOKEN` is set. |

## Chat and approval

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/chat` | Send message; streaming or final response (body: session_id, message, etc.). |
| POST | `/api/approve` | Resolve a tool approval request (allow/deny); body includes request_id and resolution. |

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
| GET | `/api/briefing` | Get briefing content (brain). |
| POST | `/api/ingest` | Ingest JSON (e.g. for brain). |
| POST | `/api/ingest/upload` | Ingest via file upload; body limit 11 MiB. |

## Research

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/research` | List research items. |
| POST | `/api/research` | Create research item. |
| GET | `/api/research/{id}` | Get research item by ID. |

## Watch

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/watch` | List watch lists/items. |
| POST | `/api/watch` | Add watch item. |
| GET | `/api/watch/alerts` | Get watch alerts. |
| DELETE | `/api/watch/{list}/{item_id}` | Remove watch item. |

## Projects

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/projects` | List projects. |
| POST | `/api/projects` | Create project. |
| POST | `/api/projects/{id}/activate` | Activate project. |

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
| POST | `/api/shortcut/capture` | Capture (e.g. quick note). |
| GET | `/api/shortcut/status` | Shortcut status. |
| POST | `/api/shortcut/command` | Execute shortcut command. |

## Static

The server serves the PWA from the static directory (default `CHUMP_WEB_STATIC_DIR` or repo `web/`). All non-API routes fall through to static files (e.g. `index.html`, `manifest.json`, `sw.js`).
