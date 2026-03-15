# iOS Shortcuts integration

Use these REST endpoints from the iOS Shortcuts app (or Siri) to create tasks, capture notes, check status, and run commands against your Chump server.

**Base URL:** Your Chump web server (e.g. `https://chump.local:PORT` or your tunnel URL).  
**Auth:** Every request must include:

```
Authorization: Bearer YOUR_CHUMP_WEB_TOKEN
Content-Type: application/json
```

Set `YOUR_CHUMP_WEB_TOKEN` in Shortcuts to the same value as `CHUMP_WEB_TOKEN` in the server `.env`.

---

## Endpoints

### Create a task

**Method:** `POST`  
**URL:** `{BASE_URL}/api/shortcut/task`  
**Body (JSON):**

```json
{ "title": "Task title here" }
```

**Response:** `{ "id": 123, "title": "Task title here" }`

**In Shortcuts:** Add “Get contents of URL” → URL = your base + `/api/shortcut/task`, Method = POST, Request Body = JSON, add key `title` with your text. Headers: `Authorization` = `Bearer YOUR_TOKEN`, `Content-Type` = `application/json`. Then “Show Result” or “Speak Text” with the “title” from the dictionary.

---

### Quick capture (text to brain)

**Method:** `POST`  
**URL:** `{BASE_URL}/api/shortcut/capture`  
**Body (JSON):**

```json
{ "text": "Note or snippet to save" }
```

**Response:** `{ "summary": "Shortcut: …" }`

**In Shortcuts:** Same pattern as task: POST to `/api/shortcut/capture` with JSON body `{ "text": "<your input>" }`. Use “Ask for Input” for the text, then “Speak Text” the “summary” for Siri confirmation.

---

### Status (one-line for Siri)

**Method:** `GET`  
**URL:** `{BASE_URL}/api/shortcut/status`  
**Headers:** `Authorization: Bearer YOUR_TOKEN`

**Response:** `{ "status": "Chump online. 3 open, 1 in progress." }`

**In Shortcuts:** “Get contents of URL” → GET, add Authorization header. Then “Speak Text” the value of key “status” so Siri reads it aloud.

---

### Run a command

**Method:** `POST`  
**URL:** `{BASE_URL}/api/shortcut/command`  
**Body (JSON):**

```json
{ "command": "status" }
```

Allowed `command` values: `status`, `deploy`, `test`, `reboot`.

**Response:** `{ "result": "3 open tasks." }` (or an acknowledgement for deploy/test/reboot).

**In Shortcuts:** POST to `/api/shortcut/command` with body `{ "command": "status" }` (or use a list to pick). “Speak Text” the “result” for Siri.

---

### Morning briefing

**Method:** `GET`  
**URL:** `{BASE_URL}/api/briefing`  
**Headers:** `Authorization: Bearer YOUR_TOKEN`

**Response:** `{ "date": "…", "sections": [ { "title": "…", "content": "…", "items": […] } ] }`

**In Shortcuts:** Get Contents of URL (GET) with Authorization header. Parse the JSON and speak the first section’s `title` and `content`, or iterate over `sections` for a full briefing.

---

## Summary table

| Shortcut           | Method | Path                     | Body                    |
|--------------------|--------|---------------------------|-------------------------|
| Create task        | POST   | `/api/shortcut/task`      | `{ "title": "…" }`      |
| Capture for Chump  | POST   | `/api/shortcut/capture`   | `{ "text": "…" }`       |
| Fleet status       | GET    | `/api/shortcut/status`    | —                       |
| Deploy / Test / Reboot | POST | `/api/shortcut/command`   | `{ "command": "…" }`    |
| Morning briefing   | GET    | `/api/briefing`           | —                       |

Always set `Authorization: Bearer YOUR_CHUMP_WEB_TOKEN` and, for POST, `Content-Type: application/json`.
