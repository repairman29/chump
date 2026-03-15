# Chump PWA — Full Tier 2 Implementation Spec

**Generated:** 2026-03-14
**Purpose:** Bot-executable spec to bring the PWA from current state (basic streaming chat + tool timeline + approval + offline shell) to full fleet ops interface that replaces Discord.

**Implementation plan & roadmap mapping:** This spec is the source of truth for PWA Tier 2. Work is tracked in [ROADMAP_FULL.md](ROADMAP_FULL.md) under "Chump Web PWA (Tier 2)" with phased checkboxes (Phase 1.1 → 5). Execute in order: Phase 1.1 (sessions + history) first, then 1.2–1.5, then Phase 2–5. Mark items done in both this file and ROADMAP_FULL as you complete them.

**Current state:** `web_server.rs` (axum: `/api/health`, `/api/chat` SSE, `/api/approve`), `web/index.html` (single-file chat UI with sidecar: tool output, pinned artifacts, timeline), `manifest.json`, `sw.js`, `run-web.sh`. Bearer token auth. Session ID in localStorage. Dark theme, SF Pro typography, iOS safe areas.

**Architecture rule:** The PWA is a single-file `web/index.html` plus minimal static assets (`sw.js`, `manifest.json`, `icon.svg`). No build step, no npm, no bundler. Vanilla JS + CSS. Backend is axum in `web_server.rs`. All new API endpoints go in `web_server.rs`. All state that must persist across page loads goes to the backend (SQLite via existing DB modules) — the frontend is stateless except for session_id and token in localStorage.

---

## Phase 1 — Chat Completeness (make the existing chat production-ready)

These items fix gaps in the current chat before adding new features.

### 1.1 Conversation history & sessions

**Backend:**
- [x] `POST /api/sessions` — create a new session (returns `session_id`).
- [x] `GET /api/sessions` — list sessions with last message preview, updated_at, message count. Paginated (limit/offset).
- [x] `GET /api/sessions/:id/messages` — retrieve message history for a session. Paginated. Each message: `{role, content, timestamp, tool_calls?, attachments?}`.
- [x] `DELETE /api/sessions/:id` — delete a session and its messages.
- [x] `PUT /api/sessions/:id` — rename a session (user-provided title or auto-generated from first message).
- [x] Store messages in SQLite (`chump_web_messages` table: id, session_id, role, content, tool_calls_json, attachments_json, created_at). Use existing DB path (`sessions/chump_memory.db`).
- [x] On `POST /api/chat`, persist both user message and assistant response (full text + tool calls) to the messages table. The SSE stream behavior doesn't change — storage is a side effect.
- [x] Session auto-title: after first assistant response, use first ~60 chars of user message as session title (or delegate a one-line summary if delegate is available).

**Frontend:**
- [x] **Session sidebar** (left drawer, toggled by hamburger icon in header): list of sessions sorted by updated_at desc. Each entry: title (or first message preview), relative timestamp ("2h ago"), message count badge. Active session highlighted.
- [x] Click session → load its history via `GET /api/sessions/:id/messages`, render in chat container, resume chatting.
- [x] "New chat" button at top of sidebar → `POST /api/sessions` → clears chat, new session_id.
- [x] Swipe-to-delete (mobile) or hover-to-show-delete (desktop) on session entries → `DELETE /api/sessions/:id` with confirmation.
- [x] Session rename: long-press or double-click title → inline edit → `PUT /api/sessions/:id`.
- [x] On page load: fetch `GET /api/sessions` and render sidebar. If a session_id is in localStorage, load that session's history. Otherwise show empty "New chat" state.

### 1.2 File attachments

**Backend:**
- [x] `POST /api/upload` — multipart file upload. Accepts images (png, jpg, gif, webp), text files (txt, md, csv, json, yaml, toml), PDFs, code files (rs, py, js, ts, sh, etc.), and documents (docx — extract text server-side). Max 10MB per file. Stores in `sessions/uploads/{session_id}/{uuid}-{filename}`. Returns `{file_id, filename, mime_type, size_bytes, url}`.
- [x] Extend `POST /api/chat` to accept optional `attachments: [{file_id, filename, mime_type}]`. When attachments are present, prepend file contents (or a summary for large files, using existing read_file auto-summary logic) to the user message before passing to the agent. For images: if the model supports vision, include as image content; otherwise note "User attached image: {filename}" in the message.
- [x] `GET /api/files/:file_id` — serve uploaded file (for download links and image previews in chat).
- [x] Cleanup: delete upload files when session is deleted.

**Frontend:**
- [x] **Attach button** (paperclip icon) left of the text input. Click → native file picker (accept images, text, code, pdf, docx). Also accept drag-and-drop onto the chat input area and paste (Ctrl+V / Cmd+V) for images.
- [x] On file select: upload via `POST /api/upload`, show thumbnail/chip in the input area below the textarea (filename, size, X to remove). Multiple files allowed (up to 5 per message).
- [x] Image attachments: show inline thumbnail preview in the input area (max 80px height). In chat history, render image attachments as inline images (clickable to full-size in a lightbox or new tab).
- [x] Non-image attachments: show as a chip/pill with filename + icon (📄 for text, 📊 for csv, etc.) in chat. Clickable to download via `/api/files/:file_id`.
- [x] When sending a message with attachments, include `attachments` array in the `/api/chat` POST body.

### 1.3 Slash commands

**Frontend (client-side, no backend needed):**
- [x] Typing `/` at the start of the input shows a command palette popup above the input. Filter as user types.
- [x] Commands are metadata that modify the message or trigger actions — the actual text is still sent to `/api/chat` (with a hint prefix the backend can parse), or the command triggers a direct API call.

**Command list:**

| Command | Args | Behavior |
|---------|------|----------|
| `/task` | `<title>` | Calls `POST /api/tasks` to create a task. Confirm inline: "Created task #N: title". |
| `/tasks` | (none) | Calls `GET /api/tasks` and renders task list in sidecar Tasks tab. |
| `/status` | (none) | Sends "status report" to chat (agent handles it). |
| `/reboot` | (none) | Sends "reboot yourself" to chat with a confirmation dialog first ("This will restart the bot. Continue?"). |
| `/battle_qa` | (none) | Sends "run battle QA and fix yourself" to chat. |
| `/brain` | `<query>` | Sends "search brain for: {query}" to chat. |
| `/research` | `<topic>` | Calls `POST /api/research` to trigger research pipeline. |
| `/watch` | `<url or item>` | Calls `POST /api/watch` to add to watchlist. |
| `/ingest` | (none) | Opens file picker for quick capture (upload → `/api/ingest`). |
| `/briefing` | (none) | Calls `GET /api/briefing`, renders in sidecar or chat. |
| `/clear` | (none) | Clears current chat display (not history — just the view). |
| `/token` | `<token>` | Stores bearer token in localStorage. Confirm: "Token saved." |
| `/bot` | `chump` or `mabel` | Switches agent (sends `bot` param on next `/api/chat` call). UI indicator updates. |
| `/help` | (none) | Shows all available commands in chat. |

**Backend support:**
- [x] `POST /api/chat` accepts optional `bot: "chump" | "mabel"` field. Backend builds the appropriate agent (existing logic: `CHUMP_MABEL=1` path vs default). Separate session namespaces per bot.
- [ ] Parse messages starting with `/task `, `/research `, `/watch ` server-side as well (belt-and-suspenders — frontend handles most, but if someone types it raw, backend still does the right thing).

### 1.4 Message actions & quality-of-life

- [x] **Copy button** on each assistant message (copies markdown text to clipboard, toast "Copied").
- [x] **Retry button** on each assistant message (re-sends the preceding user message, replaces the assistant response with a new stream).
- [ ] **Edit button** on each user message (inline edit → re-send → new assistant response replaces old one from that point forward).
- [x] **Stop generating** button — appears during streaming. Aborts the fetch (client-side abort).
- [x] **Scroll-to-bottom FAB** — appears when user scrolls up during a conversation. Click → smooth scroll to bottom.
- [ ] **Typing indicator** — pulsing dots while waiting for first SSE event after sending.
- [x] **Timestamp** on each message (hover to see full datetime; show relative time by default: "2m ago").
- [ ] **Code blocks** — syntax highlighting (use a lightweight highlighter like Prism loaded from CDN, or keep the current escapeHtml approach for zero-dep). Copy button on each code block.
- [x] **Link detection** — auto-linkify URLs in messages. Open in new tab.
- [ ] **Markdown improvements** — support bold (`**text**`), italic (`*text*`), headers (`## H2`), bullet lists (`- item`), numbered lists (`1. item`), blockquotes (`> text`), horizontal rules (`---`), and tables in addition to the existing code blocks and inline code.
- [ ] **Image rendering** — if assistant response contains an image URL or base64, render it inline.

### 1.5 Agent/bot switcher

- [x] **Header indicator**: show current bot name (Chump or Mabel). Click → toggle to switch.
- [x] Switching bots: sets `bot` field on all subsequent `/api/chat` calls. Stored in localStorage. Visual: green for Mabel.
- [x] Backend: `POST /api/chat` `bot` field selects which agent to build. Mabel agent uses `CHUMP_MABEL=1` code path internally.
- [ ] Session sidebar filters by current bot (or shows all with a bot icon badge).

---

## Phase 2 — Fleet Ops Features (the APIs that make it a real ops interface)

### 2.1 Task management

**Backend:**
- [x] `GET /api/tasks` — list tasks. Query params: `status` (open, in_progress, blocked, done, abandoned), `assignee` (chump, mabel, jeff, any). Returns task objects from `task_db`.
- [x] `POST /api/tasks` — create task. Body: `{title, repo?, issue_number?, priority?, assignee?, notes?}`. Uses `task_db::task_create`.
- [x] `PUT /api/tasks/:id` — update task (status, priority, notes, assignee). Uses `task_db::task_update_status` + `task_db::task_update_priority` + `task_db::task_update_assignee` + `task_db::task_update_notes`.
- [x] `DELETE /api/tasks/:id` — abandon task (soft: status → abandoned).

**Frontend:**
- [x] **Tasks tab** in sidecar (add to existing Tool / Pinned / Timeline tabs). Shows task list grouped by status (open → in_progress → blocked). Each task: title, assignee badge, priority indicator, notes preview.
- [x] Inline task actions: change status (dropdown), Abandon button.
- [x] "New task" button at top of Tasks tab → prompt title → `POST /api/tasks`. `/tasks` command opens Tasks tab and loads list.
- [x] Tasks for Jeff highlighted with a distinct badge/color.
- [ ] Click task → expand to full detail with notes, history, edit fields.

### 2.2 Quick capture / ingest

**Backend:**
- [ ] `POST /api/ingest` — multipart upload (image, text, URL, audio). Processing pipeline:
  - Image: store in `chump-brain/capture/{date}-{slug}.{ext}`. If OCR available (via delegate or external), extract text and store as companion `.md`.
  - Text/dictation: store as `chump-brain/capture/{date}-{slug}.md`.
  - URL: fetch via `read_url` logic, summarize, store in `chump-brain/capture/{date}-{slug}.md` with source URL.
  - Audio (if supported): transcribe via whisper or delegate, store transcript.
- [ ] Return `{capture_id, filename, summary, brain_path}`.

**Frontend:**
- [ ] **Capture button** (camera/plus icon) in header or as a FAB. Opens a modal with options: "Upload file", "Paste text", "Enter URL". On mobile: also "Take photo" (triggers camera via file input with `capture="environment"`).
- [ ] After capture: toast "Captured: {summary}. Stored in brain." with a link to view in sidecar.

### 2.3 Briefing

**Backend:**
- [x] `GET /api/briefing` — generate today's briefing. Pulls from: open tasks (grouped by assignee), recent episodes (last 15). Return as JSON: `{date, sections: [{title, content, items?}]}`.
- [ ] Cache the briefing for 1 hour (or until new data arrives).
- [ ] Add: ask_jeff answers, Mabel report, schedule due today, watchlist alerts.

**Frontend:**
- [x] **Briefing view** — sidecar tab + `/briefing` command. Renders sections as cards (Tasks by assignee, Recent episodes).
- [ ] Pull-to-refresh on mobile.
- [ ] "Ask about this" button on each section → opens chat with context pre-filled.

### 2.4 Research pipeline

**Backend:**
- [ ] `POST /api/research` — body: `{topic, depth?: "quick" | "deep"}`. Creates a research task, triggers a research heartbeat round (or queues it). Returns `{research_id, status: "queued"}`.
- [ ] `GET /api/research` — list research briefs from `chump-brain/research/`. Each: `{id, topic, status, created_at, brief_path?}`.
- [ ] `GET /api/research/:id` — retrieve a specific research brief (markdown content from brain).

**Frontend:**
- [ ] **Research tab** in sidecar or as a page. List of past research briefs. "New research" button → topic input → `POST /api/research`.
- [ ] Brief viewer: rendered markdown with sources linked.
- [ ] Status indicator: queued → in_progress → complete.

### 2.5 Watchlists

**Backend:**
- [ ] `GET /api/watch` — list all watchlists and items. Reads from `chump-brain/watch/` (deals.md, finance.md, github.md, uptime.md). Returns structured data: `{lists: [{name, items: [{description, threshold?, last_checked?, current_value?, alert?}]}]}`.
- [ ] `POST /api/watch` — add item to a watchlist. Body: `{list: "deals"|"finance"|"github"|"uptime", item: {description, url?, threshold?, ...}}`. Appends to the appropriate brain file.
- [ ] `DELETE /api/watch/:list/:item_id` — remove item from watchlist.
- [ ] `GET /api/watch/alerts` — return only items that have triggered their threshold (for badge count in UI).

**Frontend:**
- [ ] **Watch tab** in sidecar. Grouped by list type: Deals, Finance, GitHub, Uptime. Each item shows description, current value (if checked), threshold, last checked time, alert status.
- [ ] "Add watch" button → form (pick list, enter description/URL/threshold).
- [ ] Alert items highlighted (red badge). Alert count shown on Watch tab label.
- [ ] Swipe-to-delete on items.

### 2.6 Projects (external repos)

**Backend:**
- [ ] `GET /api/projects` — list external projects from `chump-brain/projects/`. Each: `{name, repo_path, description, status, last_worked_at}`.
- [ ] `POST /api/projects` — add a project. Body: `{name, repo_path, description}`. Writes to brain.
- [ ] `POST /api/projects/:id/activate` — set `CHUMP_REPO` to this project for the next heartbeat round or chat session.

**Frontend:**
- [ ] **Projects list** accessible from sidebar or sidecar. Each project: name, repo path, status, last activity.
- [ ] "Activate" button → switches context. Chat messages now go to that project's context.
- [ ] "Add project" form.

---

## Phase 3 — Push Notifications & Offline

### 3.1 Web Push notifications

**Backend:**
- [ ] `POST /api/push/subscribe` — store push subscription (endpoint, keys) in SQLite (`chump_push_subscriptions` table). Per-device.
- [ ] `POST /api/push/unsubscribe` — remove subscription.
- [ ] `notify` tool / function gains a web push pathway: when notification priority warrants push (urgent, alert), send via web-push crate to all subscriptions. Silent/FYI items don't push.
- [ ] Generate VAPID keys at first run, store in `sessions/vapid_keys.json`. Expose public key via `GET /api/push/vapid-public-key`.

**Frontend:**
- [ ] On first load (or in settings): prompt to enable notifications. Call `Notification.requestPermission()`, then `pushManager.subscribe()` with VAPID public key → `POST /api/push/subscribe`.
- [ ] Service worker handles `push` event: show notification with title, body, icon, click action (opens PWA to relevant view).
- [ ] Notification categories: task update, alert (watchlist threshold), briefing ready, approval request, agent error. Each has distinct icon/sound.
- [ ] Settings toggle to enable/disable push, and per-category toggles.

### 3.2 Offline improvements

- [ ] Service worker caches API responses for `/api/sessions`, `/api/tasks`, `/api/briefing` with a stale-while-revalidate strategy. Offline: serve cached data with a "You're offline — showing cached data" banner.
- [ ] Offline message queue: if user sends a message while offline, queue it in `sw.js` (IndexedDB) and send when back online. Show "Queued — will send when online" indicator.
- [ ] Background sync: when connectivity is restored, flush queued messages via `sync` event.

---

## Phase 4 — Polish & Mobile Excellence

### 4.1 Responsive layout

- [ ] Mobile (< 768px): sidebar is a full-screen drawer (slide from left), sidecar slides from right or is a bottom sheet. Input area is fixed at bottom with safe area padding (already exists). Hamburger menu replaces header session title.
- [ ] Tablet (768–1024px): sidebar can be pinned or collapsible. Sidecar takes 40% width (existing resize handle).
- [ ] Desktop (> 1024px): sidebar pinned at 280px, chat center, sidecar optional on right.
- [ ] Test: iPhone SE (small), iPhone 16 Pro (notch/island), iPad, desktop Chrome/Firefox/Safari.

### 4.2 Settings panel

- [ ] Accessible from header gear icon or sidebar footer.
- [ ] Settings:
  - **Token**: enter/update CHUMP_WEB_TOKEN (stored in localStorage).
  - **Theme**: dark (default) / light / auto (system preference). CSS variables swap.
  - **Notifications**: enable/disable push, per-category toggles.
  - **Bot default**: Chump or Mabel on startup.
  - **Font size**: small / medium (default) / large. Adjusts `--font-size-base` CSS variable.
  - **Tool timeline**: auto-open sidecar on tool calls (on/off).
  - **Compact mode**: reduce message padding/spacing for information density.
- [ ] Persist settings in localStorage. Apply on page load.

### 4.3 Keyboard shortcuts

- [ ] `Cmd/Ctrl + K` — focus search (session search in sidebar).
- [ ] `Cmd/Ctrl + N` — new chat.
- [ ] `Cmd/Ctrl + /` — open slash command palette.
- [ ] `Cmd/Ctrl + Shift + S` — toggle sidecar.
- [ ] `Cmd/Ctrl + .` — stop generating.
- [ ] `Escape` — close any open modal/drawer/palette.
- [ ] `↑` (in empty input) — edit last sent message.

### 4.4 Accessibility

- [ ] All interactive elements have `aria-label` or `aria-describedby`.
- [ ] Focus management: after sending a message, focus returns to input. Modal open → trap focus. Modal close → restore focus.
- [ ] Screen reader: messages have `role="log"`, `aria-live="polite"`. Tool calls announced.
- [ ] High contrast: ensure all text meets WCAG AA (4.5:1 for normal text, 3:1 for large).
- [ ] Keyboard navigation: Tab through all interactive elements in logical order.

### 4.5 Haptics and mobile UX

- [ ] iOS: subtle haptic on send (`navigator.vibrate` where supported, or CSS touch feedback).
- [ ] Pull-to-refresh on chat (re-fetches session messages; mainly useful after reconnect).
- [ ] Swipe gestures: swipe right on chat area → open session sidebar. Swipe left → open sidecar.
- [ ] iOS standalone PWA: status bar matches theme color. Splash screen with Chump icon.
- [ ] Android: custom splash screen via manifest `background_color` and icon.

### 4.6 Performance

- [ ] Virtualized message list: if a session has 500+ messages, only render visible messages + buffer. Use Intersection Observer to load older messages on scroll-up.
- [ ] Debounce input resize calculation.
- [ ] SSE reconnect: if the connection drops mid-stream, auto-reconnect and resume (or show "Connection lost — reconnecting…" with retry).
- [ ] Image lazy loading: images in chat use `loading="lazy"`.

---

## Phase 5 — iOS Shortcuts Integration

### 5.1 Shortcut-friendly API endpoints

All existing and new endpoints work as iOS Shortcut targets (they're standard REST). Add convenience endpoints for Shortcuts that want simpler request/response shapes:

- [ ] `POST /api/shortcut/task` — body: `{title}`. Creates task, returns `{id, title}`. (Simpler than full `/api/tasks` shape.)
- [ ] `POST /api/shortcut/capture` — body: `{text}` or multipart with image. Stores in brain, returns `{summary}`.
- [ ] `GET /api/shortcut/status` — returns one-line fleet status string suitable for Siri to read aloud.
- [ ] `POST /api/shortcut/command` — body: `{command: "deploy" | "test" | "reboot" | "status"}`. Runs the mapped action, returns result text.

### 5.2 Shortcut templates (documentation)

- [ ] Document in `docs/IOS_SHORTCUTS.md`: step-by-step instructions for creating each shortcut in the iOS Shortcuts app. Include: HTTP method, URL, headers (Authorization: Bearer), body format, and how to parse the response for Siri speech output.
- [ ] Shortcuts to document: "Create task", "Capture for Chump", "Fleet status", "Deploy", "Run tests", "Morning briefing".

---

## API Endpoint Summary

All endpoints require `Authorization: Bearer <CHUMP_WEB_TOKEN>` when token is set.

| Method | Path | Phase | Purpose |
|--------|------|-------|---------|
| GET | `/api/health` | Exists | Health check |
| POST | `/api/chat` | Exists (extend) | SSE streaming chat. Add `bot`, `attachments` fields. |
| POST | `/api/approve` | Exists | Tool approval |
| POST | `/api/upload` | 1.2 | File upload |
| GET | `/api/files/:file_id` | 1.2 | Serve uploaded file |
| POST | `/api/sessions` | 1.1 | Create session |
| GET | `/api/sessions` | 1.1 | List sessions |
| GET | `/api/sessions/:id/messages` | 1.1 | Get session messages |
| DELETE | `/api/sessions/:id` | 1.1 | Delete session |
| PUT | `/api/sessions/:id` | 1.1 | Rename session |
| POST | `/api/chat/cancel` | 1.4 | Stop generation |
| GET | `/api/tasks` | 2.1 | List tasks |
| POST | `/api/tasks` | 2.1 | Create task |
| PUT | `/api/tasks/:id` | 2.1 | Update task |
| DELETE | `/api/tasks/:id` | 2.1 | Delete task |
| POST | `/api/ingest` | 2.2 | Quick capture |
| GET | `/api/briefing` | 2.3 | Morning briefing |
| POST | `/api/research` | 2.4 | Trigger research |
| GET | `/api/research` | 2.4 | List research briefs |
| GET | `/api/research/:id` | 2.4 | Get research brief |
| GET | `/api/watch` | 2.5 | List watchlists |
| POST | `/api/watch` | 2.5 | Add watch item |
| DELETE | `/api/watch/:list/:item_id` | 2.5 | Remove watch item |
| GET | `/api/watch/alerts` | 2.5 | Active alerts |
| GET | `/api/projects` | 2.6 | List projects |
| POST | `/api/projects` | 2.6 | Add project |
| POST | `/api/projects/:id/activate` | 2.6 | Activate project |
| POST | `/api/push/subscribe` | 3.1 | Register push subscription |
| POST | `/api/push/unsubscribe` | 3.1 | Remove push subscription |
| GET | `/api/push/vapid-public-key` | 3.1 | VAPID public key |
| POST | `/api/shortcut/task` | 5.1 | Shortcut: create task |
| POST | `/api/shortcut/capture` | 5.1 | Shortcut: quick capture |
| GET | `/api/shortcut/status` | 5.1 | Shortcut: fleet status |
| POST | `/api/shortcut/command` | 5.1 | Shortcut: run command |

---

## Database Schema Additions

```sql
-- Session messages (Phase 1.1)
CREATE TABLE IF NOT EXISTS chump_web_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL,
    tool_calls_json TEXT,        -- JSON array of tool call records
    attachments_json TEXT,       -- JSON array of {file_id, filename, mime_type}
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_web_messages_session ON chump_web_messages(session_id, created_at);

-- Sessions metadata (Phase 1.1)
CREATE TABLE IF NOT EXISTS chump_web_sessions (
    id TEXT PRIMARY KEY,          -- UUID
    bot TEXT NOT NULL DEFAULT 'chump',  -- 'chump' or 'mabel'
    title TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_web_sessions_updated ON chump_web_sessions(bot, updated_at DESC);

-- File uploads (Phase 1.2)
CREATE TABLE IF NOT EXISTS chump_web_uploads (
    file_id TEXT PRIMARY KEY,     -- UUID
    session_id TEXT NOT NULL,
    filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    storage_path TEXT NOT NULL,   -- relative to sessions/uploads/
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Push subscriptions (Phase 3.1)
CREATE TABLE IF NOT EXISTS chump_push_subscriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    endpoint TEXT NOT NULL UNIQUE,
    keys_json TEXT NOT NULL,      -- {p256dh, auth}
    user_agent TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

---

## File Structure Changes

```
web/
├── index.html          # Existing — extend with all new UI (single file)
├── manifest.json       # Existing — add screenshots, shortcuts
├── sw.js               # Existing — extend caching strategy, push handler, offline queue
├── icon.svg            # Existing
├── icon-192.png        # NEW — rasterized icon for Android/iOS (from SVG)
├── icon-512.png        # NEW — high-res icon
├── apple-touch-icon.png # NEW — iOS home screen icon (180x180)
└── splash/             # NEW (optional) — iOS splash screens per device size

src/
├── web_server.rs       # Existing — add all new routes, extractors
├── web_sessions_db.rs  # NEW — session + message CRUD
├── web_uploads.rs      # NEW — file upload handling
├── web_push.rs         # NEW — VAPID key management, push sending
└── web_shortcuts.rs    # NEW — simplified shortcut endpoints
```

---

## Manifest Enhancements

```json
{
  "name": "Chump",
  "short_name": "Chump",
  "description": "Your local AI fleet — chat, tasks, research, watchlists",
  "start_url": "/",
  "display": "standalone",
  "orientation": "any",
  "theme_color": "#000000",
  "background_color": "#000000",
  "icons": [
    { "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" },
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "/apple-touch-icon.png", "sizes": "180x180", "type": "image/png" }
  ],
  "shortcuts": [
    { "name": "New Chat", "url": "/?action=new", "icons": [{"src": "/icon-192.png", "sizes": "192x192"}] },
    { "name": "Tasks", "url": "/?view=tasks", "icons": [{"src": "/icon-192.png", "sizes": "192x192"}] },
    { "name": "Briefing", "url": "/?view=briefing", "icons": [{"src": "/icon-192.png", "sizes": "192x192"}] }
  ],
  "categories": ["productivity", "utilities"]
}
```

---

## Implementation Order (for bots)

**Do phases in order. Within each phase, do items in listed order.**

1. **Phase 1.1** — Sessions + history (backend then frontend). This is the foundation everything else builds on.
2. **Phase 1.2** — File attachments. Backend upload → frontend attach UI.
3. **Phase 1.3** — Slash commands. Client-side palette + the backend parsing.
4. **Phase 1.4** — Message actions (copy, retry, edit, stop, scroll FAB, timestamps, markdown, links, code highlighting).
5. **Phase 1.5** — Bot switcher.
6. **Phase 2.1** — Task management API + sidecar tab.
7. **Phase 2.2** — Quick capture / ingest.
8. **Phase 2.3** — Briefing.
9. **Phase 2.4** — Research pipeline.
10. **Phase 2.5** — Watchlists.
11. **Phase 2.6** — Projects.
12. **Phase 3.1** — Web push notifications.
13. **Phase 3.2** — Offline improvements.
14. **Phase 4** — Polish (responsive, settings, shortcuts, a11y, haptics, performance). Can be interleaved with Phase 2–3 as needed.
15. **Phase 5** — iOS Shortcuts docs + convenience endpoints.

**Estimated effort:** Phase 1: ~5d. Phase 2: ~5d. Phase 3: ~2d. Phase 4: ~2d. Phase 5: ~1d. **Total: ~15d** from current state to full Tier 2.

---

## When you complete an item

1. Check the box: `- [ ]` → `- [x]`.
2. Test: run `./run-web.sh`, open `http://localhost:3000`, verify the feature works on desktop + mobile viewport.
3. Update `docs/PWA_UAT.md` with any new UAT checks.
4. Episode log the completion.
