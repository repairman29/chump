# Web API reference

The web server is started with `rust-agent --web` (default port 3000; override with `--port` or `CHUMP_WEB_PORT`). All API routes are under `/api/`. Implemented in `src/web_server.rs`.

## Health and status

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check; returns JSON (e.g. status, version). |
| GET | `/api/cascade-status` | Cascade provider status (slots, remaining RPD, etc.). |
| GET | `/api/pilot-summary` | **Pilot / N4 aggregate:** task counts by status, episode total, tool-call ring stats, last speculative batch JSON. Requires `Authorization: Bearer …` when `CHUMP_WEB_TOKEN` is set (same as mutating task routes). See [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) and `./scripts/export-pilot-summary.sh`. |

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
